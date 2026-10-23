# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "uri"

module PartiduoConnect
  # Fournisseur OpenID Connect (ADR-012 D3) : flux « code d'autorisation »
  # avec PKCE (S256) obligatoire, clients confidentiels, jetons d'identité
  # ES256 de courte durée. Le jeton dit qui est la personne et à quel
  # niveau elle s'est authentifiée ; jamais où elle entre.
  module Oidc
    # Erreur renvoyée au client par son adresse de retour (RFC 6749 4.1.2.1)
    # ou, si l'adresse n'est pas sûre, affichée.
    class AuthorizeError < Exception
      getter code : String
      getter redirectable : Bool

      def initialize(@code : String, message : String = "", @redirectable : Bool = true)
        super(message.presence || code)
      end
    end

    # Erreur du point de jeton (RFC 6749 5.2).
    class TokenError < Exception
      getter code : String
      getter status : Int32

      def initialize(@code : String, message : String = "", @status : Int32 = 400)
        super(message.presence || code)
      end
    end

    # Demande d'autorisation validée.
    record Request, client : Client, redirect_uri : String, state : String, nonce : String, scope : String,
      code_challenge : String, acr : Int32, prompt : Array(String), max_age : Int32?, login_hint : String

    def self.discovery : String
      base = Config.issuer
      {
        "issuer"                                => base,
        "authorization_endpoint"                => "#{base}/authorize",
        "token_endpoint"                        => "#{base}/token",
        "userinfo_endpoint"                     => "#{base}/userinfo",
        "jwks_uri"                              => "#{base}/jwks.json",
        "end_session_endpoint"                  => "#{base}/logout",
        "response_types_supported"              => ["code"],
        "response_modes_supported"              => ["query"],
        "grant_types_supported"                 => ["authorization_code"],
        "subject_types_supported"               => ["public"],
        "id_token_signing_alg_values_supported" => ["ES256"],
        "token_endpoint_auth_methods_supported" => ["client_secret_basic", "client_secret_post"],
        "code_challenge_methods_supported"      => ["S256"],
        "scopes_supported"                      => ["openid", "email", "profile"],
        "claims_supported"                      => ["sub", "iss", "aud", "exp", "iat", "auth_time", "nonce", "acr", "amr", "sid",
                               "email", "email_verified", "name", "locale"],
        "acr_values_supported"                 => Config::ACR_VALUES,
        "prompt_values_supported"              => ["none", "login"],
        "backchannel_logout_supported"         => true,
        "backchannel_logout_session_supported" => true,
      }.to_json
    end

    # Valide une demande d'autorisation. Tant que le client et l'adresse de
    # retour ne sont pas établis, l'erreur n'est pas renvoyée au client
    # (`redirectable: false`).
    def self.parse(params : Hash(String, String)) : Request
      client, redirect_uri = parse_client(params)
      raise AuthorizeError.new("unsupported_response_type") unless params["response_type"]? == "code"
      raise AuthorizeError.new("request_not_supported") if params.has_key?("request")
      scope = params["scope"]? || ""
      raise AuthorizeError.new("invalid_scope", "openid attendu") unless scope.split(' ').includes?("openid")
      max_age = params["max_age"]?.try(&.to_i?)
      raise AuthorizeError.new("invalid_request", "max_age invalide") if max_age && max_age < 0
      Request.new(client: client, redirect_uri: redirect_uri, state: params["state"]? || "",
        nonce: (params["nonce"]? || "")[0, 255]? || "", scope: scope, code_challenge: parse_pkce(params),
        acr: requested_acr(params["acr_values"]?), prompt: (params["prompt"]? || "").split(' ').reject(&.empty?),
        max_age: max_age, login_hint: (params["login_hint"]? || "").strip.downcase)
    end

    # Client actif et adresse de retour déclarée : sans eux, aucune erreur ne
    # part vers l'adresse donnée.
    private def self.parse_client(params : Hash(String, String)) : {Client, String}
      client = Client.filter(client_id: params["client_id"]? || "", active: true).first
      raise AuthorizeError.new("invalid_client", redirectable: false) if client.nil?
      redirect_uri = params["redirect_uri"]? || ""
      raise AuthorizeError.new("invalid_redirect_uri", redirectable: false) unless client.redirect_uri_allowed?(redirect_uri)
      {client, redirect_uri}
    end

    private def self.parse_pkce(params : Hash(String, String)) : String
      challenge = params["code_challenge"]? || ""
      unless params["code_challenge_method"]? == "S256" && challenge.matches?(/\A[A-Za-z0-9_-]{43,128}\z/)
        raise AuthorizeError.new("invalid_request", "PKCE S256 obligatoire")
      end
      challenge
    end

    # Plus haut niveau demandé parmi `acr_values` connus, sinon le niveau
    # par défaut.
    def self.requested_acr(values : String?) : Int32
      levels = (values || "").split(' ').compact_map { |value| Config::ACR_VALUES.includes?(value) ? value.to_i : nil }
      levels.empty? ? Config::DEFAULT_ACR : levels.max
    end

    # Adresse de retour d'une erreur.
    def self.error_redirect(request_params : Hash(String, String), error : AuthorizeError) : String
      append(request_params["redirect_uri"]? || "", {"error" => error.code, "error_description" => error.message || "",
                                                     "state" => request_params["state"]? || ""})
    end

    # La session suffit-elle, ou faut-il (re)passer par la connexion ?
    def self.needs_login?(request : Request, session : Session?, now : Time) : Bool
      return true if session.nil?
      return true if request.prompt.includes?("login")
      if max_age = request.max_age
        return true if session.auth_time! + max_age.seconds < now
      end
      false
    end

    # Code d'autorisation : enregistré en empreinte, une minute ; le client
    # est inscrit à la session pour la déconnexion unique.
    def self.issue_code(request : Request, session : Session, now : Time = Time.utc) : String
      raw = Secrets.token
      AuthorizationCode.create!(code_digest: Secrets.digest(raw), client: request.client, account: session.account!,
        session: session, redirect_uri: request.redirect_uri, code_challenge: request.code_challenge,
        nonce: request.nonce, scope: request.scope, expires_at: now + Config::CODE_LIFETIME)
      unless ClientSession.filter(session_id: session.pk, client_id: request.client.pk).exists?
        ClientSession.create!(session: session, client: request.client)
      end
      Audit.log(session.account, "oidc.authorize", {"acr" => session.level.to_s}, client: request.client)
      append(request.redirect_uri, {"code" => raw, "state" => request.state, "iss" => Config.issuer})
    end

    # Client authentifié par `client_secret_basic` ou `client_secret_post`.
    def self.authenticate_client(authorization : String?, params : Hash(String, String)) : Client
      client_id, secret = credentials(authorization, params)
      client = Client.filter(client_id: client_id, active: true).first
      digest = client.try(&.secret_digest.to_s) || Secrets.digest("decoy")
      ok = Secrets.equal?(Secrets.digest(secret), digest)
      raise TokenError.new("invalid_client", status: 401) if client.nil? || !ok
      client
    end

    # Échange d'un code (RFC 6749 4.1.3, RFC 7636) : usage unique, une
    # minute, même client, même adresse de retour, vérificateur PKCE.
    def self.exchange(client : Client, params : Hash(String, String), now : Time = Time.utc) : String
      raise TokenError.new("unsupported_grant_type") unless params["grant_type"]? == "authorization_code"
      raw = params["code"]? || ""
      digest = Secrets.digest(raw)
      claimed = AuthorizationCode.filter(code_digest: digest, used_at__isnull: true, expires_at__gt: now).update(used_at: now)
      code = claimed == 1 ? AuthorizationCode.filter(code_digest: digest).first : nil
      raise TokenError.new("invalid_grant", "code inconnu, expiré ou déjà utilisé") if code.nil?
      raise TokenError.new("invalid_grant", "code d'un autre client") unless code.client_id == client.pk
      raise TokenError.new("invalid_grant", "adresse de retour différente") unless code.redirect_uri == params["redirect_uri"]?
      verifier = params["code_verifier"]? || ""
      unless verifier.matches?(/\A[A-Za-z0-9._~-]{43,128}\z/) &&
             Secrets.equal?(pkce(verifier), code.code_challenge.to_s)
        raise TokenError.new("invalid_grant", "vérificateur PKCE faux")
      end
      session = code.session!
      account = code.account!
      if !session.revoked_at.nil? || !account.can_sign_in?
        raise TokenError.new("invalid_grant", "session fermée")
      end
      access = Secrets.token
      AccessToken.create!(token_digest: Secrets.digest(access), client: client, account: account, scope: code.scope,
        expires_at: now + Config::ACCESS_TOKEN_LIFETIME)
      {
        "access_token" => access,
        "token_type"   => "Bearer",
        "expires_in"   => Config::ACCESS_TOKEN_LIFETIME.total_seconds.to_i,
        "scope"        => code.scope,
        "id_token"     => id_token(client, account, session, code.nonce.to_s, now),
      }.to_json
    end

    def self.id_token(client : Client, account : Account, session : Session, nonce : String, now : Time) : String
      claims = {
        "iss"            => JSON::Any.new(Config.issuer),
        "sub"            => JSON::Any.new(account.sub.to_s),
        "aud"            => JSON::Any.new(client.client_id.to_s),
        "iat"            => JSON::Any.new(now.to_unix),
        "exp"            => JSON::Any.new((now + Config::ID_TOKEN_LIFETIME).to_unix),
        "auth_time"      => JSON::Any.new(session.auth_time!.to_unix),
        "acr"            => JSON::Any.new(session.level.to_s),
        "amr"            => JSON::Any.new(Auth.amr(session.method.to_s).map { |value| JSON::Any.new(value) }),
        "sid"            => JSON::Any.new(session.sid.to_s),
        "email"          => JSON::Any.new(account.email.to_s),
        "email_verified" => JSON::Any.new(true),
        "name"           => JSON::Any.new(account.name),
      }
      # Langue du compte (claim standard) : absente pour un compte qui suit
      # son navigateur.
      account.locale.presence.try { |locale| claims["locale"] = JSON::Any.new(locale) }
      claims["nonce"] = JSON::Any.new(nonce) unless nonce.empty?
      SigningKeys.sign(claims)
    end

    def self.userinfo(bearer : String?, now : Time = Time.utc) : String?
      token = bearer.try { |value| value.starts_with?("Bearer ") ? value[7..].strip : nil }
      return if token.nil? || token.empty?
      access = AccessToken.filter(token_digest: Secrets.digest(token), expires_at__gt: now).first
      account = access.try(&.account)
      return if access.nil? || account.nil? || !account.can_sign_in?
      info = {
        "sub"            => JSON::Any.new(account.sub.to_s),
        "email"          => JSON::Any.new(account.email.to_s),
        "email_verified" => JSON::Any.new(true),
        "name"           => JSON::Any.new(account.name),
      }
      account.locale.presence.try { |locale| info["locale"] = JSON::Any.new(locale) }
      info.to_json
    end

    # Jeton de déconnexion (OpenID Connect Back-Channel Logout 1.0).
    def self.logout_token(client : Client, account : Account, sid : String, now : Time = Time.utc) : String
      SigningKeys.sign({
        "iss"    => Config.issuer,
        "aud"    => client.client_id.to_s,
        "iat"    => now.to_unix,
        "exp"    => (now + Config::LOGOUT_TOKEN_LIFETIME).to_unix,
        "jti"    => Secrets.token(16),
        "sub"    => account.sub.to_s,
        "sid"    => sid,
        "events" => {"http://schemas.openid.net/event/backchannel-logout" => {} of String => String},
      }, typ: "logout+jwt")
    end

    def self.pkce(verifier : String) : String
      Secrets.base64url(OpenSSL::Digest.new("SHA256").update(verifier).final)
    end

    def self.append(uri : String, values : Hash(String, String)) : String
      parsed = URI.parse(uri)
      query = parsed.query_params
      values.each { |key, value| query[key] = value unless value.empty? }
      return uri if query.empty?
      parsed.query_params = query
      parsed.to_s
    end

    private def self.credentials(authorization : String?, params : Hash(String, String)) : {String, String}
      if authorization && authorization.starts_with?("Basic ")
        decoded = String.new(Base64.decode(authorization[6..].strip))
        id, _, secret = decoded.partition(':')
        return {URI.decode_www_form(id), URI.decode_www_form(secret)}
      end
      {params["client_id"]? || "", params["client_secret"]? || ""}
    rescue Base64::Error | ArgumentError
      {"", ""}
    end
  end
end

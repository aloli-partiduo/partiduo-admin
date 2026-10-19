# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/client"
require "jose"
require "json"
require "uri"

module PartiduoConnect
  # Relais de l'authentification d'un cabinet (ADR-012 D9) : pour une
  # adresse d'un domaine déclaré, connect envoie la personne au fournisseur
  # d'identité du cabinet (OpenID Connect, code + PKCE) et à lui seul.
  #
  # * Le compte connect reste : la personne garde son `sub` ; le fournisseur
  #   du cabinet remplace mot de passe, TOTP et codes de récupération (la
  #   récupération relève du cabinet).
  # * Niveau : 2 si le cabinet atteste une authentification à plusieurs
  #   facteurs (`amr`), sinon 1 ; plafonné au niveau déclaré pour ce
  #   fournisseur. Au-delà (niveau 3), passkey enrôlée chez connect.
  # * Un compte n'est créé que pour une adresse déjà invitée (invitation de
  #   création de compte en attente) ; l'autorisation reste aux dossiers.
  # * Portée : le fournisseur d'un cabinet n'atteste que les adresses de ses
  #   domaines.
  module Sso
    PURPOSE   = "sso.login"
    SKEW      = 60.seconds
    MFA_AMR   = %w[mfa otp hwk swk fpt face sms]
    LOGOUT_EV = "http://schemas.openid.net/event/backchannel-logout"

    class Error < Exception
      getter key : String

      def initialize(@key : String, message : String? = nil)
        super(message || key)
      end
    end

    abstract class Transport
      abstract def post_form(url : String, form : Hash(String, String)) : {Int32, String}
      abstract def get(url : String) : {Int32, String}
    end

    class NetTransport < Transport
      TIMEOUT = 10.seconds

      def post_form(url : String, form : Hash(String, String)) : {Int32, String}
        call(url) { |http, uri| http.post(uri.request_target, form: form, headers: HTTP::Headers{"Accept" => "application/json"}) }
      end

      def get(url : String) : {Int32, String}
        call(url) { |http, uri| http.get(uri.request_target, headers: HTTP::Headers{"Accept" => "application/json"}) }
      end

      private def call(url : String, & : HTTP::Client, URI -> HTTP::Client::Response) : {Int32, String}
        uri = URI.parse(url)
        http = HTTP::Client.new(uri)
        http.connect_timeout = TIMEOUT
        http.read_timeout = TIMEOUT
        begin
          response = yield http, uri
          {response.status_code, response.body}
        ensure
          http.close
        end
      rescue ex : IO::Error | Socket::Error | OpenSSL::SSL::Error
        raise Error.new("connect.errors.sso.unreachable", ex.message)
      end
    end

    class_property transport : Transport = NetTransport.new

    record Identity, subject : String, email : String, name : String, level : Int32

    # Fournisseur actif qui couvre cette adresse, ou `nil`.
    def self.for_email(email : String) : Upstream?
      Upstream.filter(active: true).to_a.find(&.covers?(email))
    end

    # Départ vers le cabinet ; le navigateur ne garde que la poignée.
    def self.begin(upstream : Upstream, email : String, now : Time = Time.utc) : {String, String}
      state, verifier, nonce = Secrets.token, Secrets.token, Secrets.token
      issued = Auth::Challenges.issue(PURPOSE, value: [upstream.code, state, verifier, nonce].join('~'), now: now)
      params = {
        "response_type"         => "code",
        "client_id"             => upstream.client_id.to_s,
        "redirect_uri"          => upstream.callback_uri,
        "scope"                 => "openid email profile",
        "state"                 => state,
        "nonce"                 => nonce,
        "code_challenge"        => Oidc.pkce(verifier),
        "code_challenge_method" => "S256",
        "login_hint"            => email,
      }
      endpoint = upstream.authorization_endpoint.to_s
      {"#{endpoint}#{endpoint.includes?('?') ? '&' : '?'}#{URI::Params.encode(params)}", issued.handle}
    end

    # Retour du cabinet : `state`, échange du code, jeton vérifié (émetteur,
    # audience, échéance, `nonce`), adresse vérifiée d'un domaine couvert.
    def self.complete(upstream : Upstream, handle : String?, payload : Hash(String, String), now : Time = Time.utc) : Identity
      challenge = Auth::Challenges.consume(PURPOSE, handle, now)
      raise Error.new("connect.errors.login.expired") if challenge.nil?
      code, state, verifier, nonce = challenge.value.to_s.split('~', 4)
      raise Error.new("connect.errors.login.expired") unless code == upstream.code
      raise Error.new("connect.errors.sso.denied", payload["error"]) if payload["error"]?.presence
      raise Error.new("connect.errors.sso.invalid", "state") unless Secrets.equal?(payload["state"]? || "", state)
      claims = verified(upstream, exchange(upstream, payload["code"]? || "", verifier))
      check(upstream, claims, now)
      raise Error.new("connect.errors.sso.invalid", "nonce") unless Secrets.equal?(claims["nonce"]?.try(&.as_s?) || "", nonce)
      identity(upstream, claims)
    end

    # Connexion : compte lié au fournisseur, ou compte de la même adresse
    # (lié à cette occasion), ou compte créé pour une adresse invitée.
    def self.login(upstream : Upstream, identity : Identity, ip : String = "", user_agent : String = "",
                   now : Time = Time.utc) : {Auth::Sessions::Opened, String}
      return_to = ""
      account = Account.filter(upstream: upstream.code, upstream_subject: identity.subject).first
      account ||= Account.filter(email: identity.email).first.try { |found| link(found, upstream, identity) }
      if account.nil?
        account, return_to = create(upstream, identity, now)
      end
      raise Error.new("connect.errors.login.invalid") unless account.can_sign_in?
      opened = Auth::Sessions.open(account, identity.level, "sso", ip, user_agent, now, return_to: return_to)
      Audit.log(account, "auth.login", {"method" => "sso", "upstream" => upstream.code.to_s, "level" => identity.level.to_s}, ip: ip)
      {opened, return_to}
    end

    # Déconnexion annoncée par le cabinet : sessions de la personne fermées,
    # clients avisés (ADR-012 D8, D9). `nil` si le jeton est refusé.
    def self.backchannel_logout(upstream : Upstream, token : String, now : Time = Time.utc) : Int32?
      claims = verified(upstream, token)
      raise Error.new("connect.errors.sso.invalid", "iss") unless claims["iss"]?.try(&.as_s?) == upstream.issuer
      raise Error.new("connect.errors.sso.invalid", "aud") unless audience?(upstream, claims)
      events = claims["events"]?.try(&.as_h?)
      raise Error.new("connect.errors.sso.invalid", "events") unless events.try(&.has_key?(LOGOUT_EV)) == true
      raise Error.new("connect.errors.sso.invalid", "nonce") if claims.has_key?("nonce")
      subject = claims["sub"]?.try(&.as_s?)
      account = subject.try { |sub| Account.filter(upstream: upstream.code, upstream_subject: sub).first }
      return 0 if account.nil?
      count = Session.filter(account_id: account.pk, revoked_at__isnull: true).count.to_i32
      Auth::Sessions.revoke_all(account, now)
      Audit.log(account, "auth.sso_logout", {"upstream" => upstream.code.to_s})
      count
    rescue Error
      nil
    end

    private def self.link(account : Account, upstream : Upstream, identity : Identity) : Account
      if account.upstream? && account.upstream != upstream.code
        raise Error.new("connect.errors.sso.other_upstream")
      end
      account.upstream = upstream.code
      account.upstream_subject = identity.subject
      account.save!
      Audit.log(account, "account.sso_link", {"upstream" => upstream.code.to_s})
      account
    end

    private def self.create(upstream : Upstream, identity : Identity, now : Time) : {Account, String}
      ticket = SignupTicket.filter(email: identity.email, used_at__isnull: true, cancelled_at__isnull: true,
        expires_at__gt: now).order("-created_at").first
      raise Error.new("connect.errors.sso.not_invited") if ticket.nil?
      ticket.used_at = now
      ticket.save!
      account = Account.create!(sub: Secrets.token(24), email: identity.email,
        display_name: identity.name.presence || ticket.display_name.to_s, locale: ticket.locale.to_s,
        upstream: upstream.code, upstream_subject: identity.subject)
      Audit.log(account, "signup.sso", {"upstream" => upstream.code.to_s})
      {account, ticket.return_to.to_s}
    end

    private def self.identity(upstream : Upstream, claims : Hash(String, JSON::Any)) : Identity
      subject = claims["sub"]?.try(&.as_s?).presence || raise Error.new("connect.errors.sso.invalid", "sub")
      email = claims["email"]?.try(&.as_s?).to_s.strip.downcase
      raise Error.new("connect.errors.sso.invalid", "email non vérifiée") if claims["email_verified"]?.try(&.as_bool?) == false
      # Le cabinet n'atteste que les adresses de ses domaines.
      raise Error.new("connect.errors.sso.domain") unless upstream.covers?(email)
      amr = claims["amr"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      attested = amr.any? { |method| MFA_AMR.includes?(method) } ? Auth::TWO_FACTOR : Auth::PASSWORD
      level = Math.min(attested, (upstream.ceiling || Auth::TWO_FACTOR).to_i32.clamp(Auth::PASSWORD, Auth::PASSKEY))
      Identity.new(subject, email, claims["name"]?.try(&.as_s?).to_s, level)
    end

    private def self.exchange(upstream : Upstream, code : String, verifier : String) : String
      status, body = transport.post_form(upstream.token_endpoint.to_s, {
        "grant_type" => "authorization_code", "code" => code, "redirect_uri" => upstream.callback_uri,
        "client_id" => upstream.client_id.to_s, "client_secret" => upstream.client_secret.to_s, "code_verifier" => verifier,
      })
      raise Error.new("connect.errors.sso.invalid", "jeton : HTTP #{status}") unless status == 200
      parse(body)["id_token"]?.try(&.as_s?) || raise Error.new("connect.errors.sso.invalid", "id_token absent")
    end

    # Signature RS256 ou ES256 par une clé publiée du cabinet.
    private def self.verified(upstream : Upstream, token : String) : Hash(String, JSON::Any)
      header = parse(String.new(Secrets.decode64?(token.split('.').first? || "") || Bytes.empty))
      algorithm = header["alg"]?.try(&.as_s?) || ""
      raise Error.new("connect.errors.sso.invalid", "alg #{algorithm}") unless %w[RS256 ES256].includes?(algorithm)
      kty = algorithm == "ES256" ? "EC" : "RSA"
      kid = header["kid"]?.try(&.as_s?)
      status, body = transport.get(upstream.jwks_uri.to_s)
      raise Error.new("connect.errors.sso.invalid", "jwks : HTTP #{status}") unless status == 200
      keys = (parse(body)["keys"]?.try(&.as_a?) || [] of JSON::Any).select do |key|
        key["kty"]?.try(&.as_s?) == kty && (kid.nil? || key["kid"]?.try(&.as_s?) == kid)
      end
      keys.each do |key|
        payload = if kty == "EC"
                    Jose::JWS.verify(token, Jose::JWK::ECKey.from_jwk_hash(key.as_h))
                  else
                    Jose::JWS.verify(token, Jose::JWK::RSAKey.from_jwk_hash(key.as_h))
                  end
        return parse(String.new(payload))
      rescue Jose::JWS::Error | Jose::JWK::Error | ArgumentError | KeyError
        next
      end
      raise Error.new("connect.errors.sso.invalid", "signature")
    end

    private def self.check(upstream : Upstream, claims : Hash(String, JSON::Any), now : Time) : Nil
      raise Error.new("connect.errors.sso.invalid", "iss") unless claims["iss"]?.try(&.as_s?) == upstream.issuer
      raise Error.new("connect.errors.sso.invalid", "aud") unless audience?(upstream, claims)
      expires = claims["exp"]?.try(&.as_i64?) || raise Error.new("connect.errors.sso.invalid", "exp")
      raise Error.new("connect.errors.sso.invalid", "exp") if now - SKEW >= Time.unix(expires)
    end

    private def self.audience?(upstream : Upstream, claims : Hash(String, JSON::Any)) : Bool
      case audience = claims["aud"]?.try(&.raw)
      when String then audience == upstream.client_id
      when Array  then audience.compact_map(&.as_s?).includes?(upstream.client_id.to_s)
      else             false
      end
    end

    # Adresses du fournisseur par sa découverte (déclaration d'un cabinet).
    def self.discover(issuer : String) : Hash(String, String)
      status, body = transport.get("#{issuer.rchop('/')}/.well-known/openid-configuration")
      raise Error.new("connect.errors.sso.invalid", "découverte : HTTP #{status}") unless status == 200
      json = parse(body)
      raise Error.new("connect.errors.sso.invalid", "émetteur différent") unless json["issuer"]?.try(&.as_s?) == issuer
      %w[authorization_endpoint token_endpoint jwks_uri].to_h do |key|
        {key, json[key]?.try(&.as_s?) || raise Error.new("connect.errors.sso.invalid", "#{key} absent")}
      end
    end

    private def self.parse(body : String) : Hash(String, JSON::Any)
      JSON.parse(body).as_h? || raise Error.new("connect.errors.sso.invalid", "JSON")
    rescue JSON::ParseException
      raise Error.new("connect.errors.sso.invalid", "JSON")
    end
  end
end

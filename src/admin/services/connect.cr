# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/client"
require "jose"
require "json"
require "log"
require "uri"

module PartiduoAdmin
  # connect (ADR-012 D4) : l'administration est un client OpenID Connect
  # comme les dossiers. Réglée par l'environnement :
  #
  # * `PARTIDUO_ADMIN_CONNECT_URL` : émetteur (`https://connect.<domaine>`) ;
  # * `PARTIDUO_ADMIN_CONNECT_CLIENT_ID`, `PARTIDUO_ADMIN_CONNECT_CLIENT_SECRET`
  #   (ou `_SECRET_FILE`) : client déclaré par l'exploitation chez connect.
  #
  # Réglée, elle remplace les mots de passe, TOTP, passkeys et codes de
  # récupération de l'administration : un utilisateur est lié à une identité
  # connect (`sub`) par son invitation ; ses rôles restent ici (ADR-008 D2).
  # Le niveau de la session est celui qu'atteste connect (`acr`).
  module Connect
    Log = ::Log.for("partiduo_admin.connect")

    PURPOSE = "connect.login"
    SKEW    = 60.seconds

    class Error < Exception
      getter key : String

      def initialize(@key : String, message : String? = nil)
        super(message || key)
      end
    end

    # Accès HTTP (remplaçable dans les specs) : {statut, corps}.
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
        raise Error.new("admin.errors.connect.unreachable", ex.message)
      end
    end

    class_property transport : Transport = NetTransport.new

    # Identité attestée par connect.
    # `locale` : langue du compte connect ramenée à l'une des langues de la
    # console (`de-DE` → `de`), vide sinon.
    record Identity, subject : String, email : String, level : Int32, sid : String?, locale : String = ""

    # Langue de base d'une étiquette BCP 47 (`de-DE`, `pt_BR` → `de`, `pt`)
    # si la console la sert ; vide sinon.
    def self.base_locale(value : String?) : String
      base = value.to_s.strip.downcase.split(/[-_]/, 2).first? || ""
      Config::LOCALES.includes?(base) ? base : ""
    end

    def self.url : String?
      ENV["PARTIDUO_ADMIN_CONNECT_URL"]?.presence.try(&.rchop('/'))
    end

    def self.client_id : String?
      ENV["PARTIDUO_ADMIN_CONNECT_CLIENT_ID"]?.presence
    end

    def self.client_secret : String?
      if path = ENV["PARTIDUO_ADMIN_CONNECT_CLIENT_SECRET_FILE"]?.presence
        return File.read(path).strip.presence if File::Info.readable?(path)
      end
      ENV["PARTIDUO_ADMIN_CONNECT_CLIENT_SECRET"]?.presence
    end

    def self.configured? : Bool
      !url.nil? && !client_id.nil? && !client_secret.nil?
    end

    def self.redirect_uri : String
      "#{Config.base_url}/login/connect/callback"
    end

    # Départ vers connect : `state`, vérificateur PKCE et `nonce` restent ici
    # (défi à usage unique), le navigateur ne garde que la poignée.
    def self.begin(acr : Int32 = Auth::TWO_FACTOR, fresh : Bool = false, login_hint : String = "",
                   now : Time = Time.utc) : {String, String}
      state, verifier, nonce = Secrets.token, Secrets.token, Secrets.token
      issued = Auth::Challenges.issue(PURPOSE, value: [state, verifier, nonce].join('~'), now: now)
      params = {
        "response_type"         => "code",
        "client_id"             => client_id || "",
        "redirect_uri"          => redirect_uri,
        "scope"                 => "openid email profile",
        "state"                 => state,
        "nonce"                 => nonce,
        "code_challenge"        => Secrets.base64url(OpenSSL::Digest.new("SHA256").update(verifier).final),
        "code_challenge_method" => "S256",
        "acr_values"            => acr.to_s,
      }
      params["prompt"] = "login" if fresh
      params["login_hint"] = login_hint unless login_hint.empty?
      {"#{url}/authorize?#{URI::Params.encode(params)}", issued.handle}
    end

    # Retour de connect : `state`, échange du code (PKCE), jeton d'identité
    # vérifié (ES256, émetteur, audience, échéance, `nonce`).
    def self.complete(handle : String?, payload : Hash(String, String), now : Time = Time.utc) : Identity
      challenge = Auth::Challenges.consume(PURPOSE, handle, now)
      raise Error.new("admin.errors.login.expired") if challenge.nil?
      state, verifier, nonce = challenge.value.to_s.split('~', 3)
      raise Error.new("admin.errors.connect.denied", payload["error"]) if payload["error"]?.presence
      raise Error.new("admin.errors.connect.invalid", "state") unless Secrets.equal?(payload["state"]? || "", state)
      claims = verified(exchange(payload["code"]? || "", verifier))
      check(claims, now)
      raise Error.new("admin.errors.connect.invalid", "nonce") unless Secrets.equal?(claims["nonce"]?.try(&.as_s?) || "", nonce)
      subject = claims["sub"]?.try(&.as_s?).presence || raise Error.new("admin.errors.connect.invalid", "sub absent")
      level = claims["acr"]?.try(&.as_s?).try(&.to_i?) || Auth::PASSWORD
      Identity.new(subject, claims["email"]?.try(&.as_s?).to_s.downcase, level.clamp(Auth::PASSWORD, Auth::PASSKEY),
        claims["sid"]?.try(&.as_s?), base_locale(claims["locale"]?.try(&.as_s?)))
    end

    # Jeton de déconnexion par canal arrière (ADR-012 D8) : rend `{sub, sid}`.
    def self.verify_logout_token(token : String, now : Time = Time.utc) : {String?, String?}
      claims = verified(token)
      raise Error.new("admin.errors.connect.invalid", "iss") unless claims["iss"]?.try(&.as_s?) == url
      raise Error.new("admin.errors.connect.invalid", "aud") unless audience?(claims)
      issued = claims["iat"]?.try(&.as_i64?) || raise Error.new("admin.errors.connect.invalid", "iat")
      raise Error.new("admin.errors.connect.invalid", "iat") unless (now - Time.unix(issued)).abs <= 5.minutes
      events = claims["events"]?.try(&.as_h?)
      logout = events.try(&.has_key?("http://schemas.openid.net/event/backchannel-logout")) == true
      raise Error.new("admin.errors.connect.invalid", "événement") if !logout || claims.has_key?("nonce")
      {claims["sub"]?.try(&.as_s?), claims["sid"]?.try(&.as_s?)}
    end

    # Déconnexion chez connect, puis retour à la page de connexion.
    def self.end_session_url : String?
      issuer = url || return
      "#{issuer}/logout?#{URI::Params.encode({"client_id" => client_id || "", "post_logout_redirect_uri" => "#{Config.base_url}/login"})}"
    end

    # Invitation à créer un compte connect (ADR-012 D6) : `{lien, code}`,
    # `nil` si la personne a déjà un compte ou si connect ne répond pas.
    def self.signup_ticket(user : User, return_to : String) : {String, String}?
      return unless configured?
      status, body = transport.post_form("#{url}/api/v1/signup-tickets", {
        "client_id" => client_id || "", "client_secret" => client_secret || "", "email" => user.email.to_s,
        "name" => user.display_name, "locale" => user.locale.to_s, "return_to" => return_to, "by" => "administration",
      })
      unless status == 200
        Log.warn { "Invitation connect refusée pour #{user.email} : HTTP #{status}" }
        return
      end
      json = parse(body)
      return if json["account"]?.try(&.as_bool?)
      ticket_url = json["url"]?.try(&.as_s?)
      code = json["code"]?.try(&.as_s?)
      ticket_url && code ? {ticket_url, code} : nil
    rescue ex : Error
      Log.warn { "Invitation connect impossible pour #{user.email} : #{ex.message}" }
      nil
    end

    # Code échangé au point de jeton (secret du client, vérificateur PKCE) ;
    # rend le jeton d'identité.
    private def self.exchange(code : String, verifier : String) : String
      status, body = transport.post_form("#{url}/token", {
        "grant_type" => "authorization_code", "code" => code, "redirect_uri" => redirect_uri,
        "client_id" => client_id || "", "client_secret" => client_secret || "", "code_verifier" => verifier,
      })
      raise Error.new("admin.errors.connect.invalid", "jeton : HTTP #{status}") unless status == 200
      parse(body)["id_token"]?.try(&.as_s?) || raise Error.new("admin.errors.connect.invalid", "id_token absent")
    end

    private def self.verified(token : String) : Hash(String, JSON::Any)
      header = parse(String.new(Secrets.decode64?(token.split('.').first? || "") || Bytes.empty))
      raise Error.new("admin.errors.connect.invalid", "alg") unless header["alg"]?.try(&.as_s?) == "ES256"
      kid = header["kid"]?.try(&.as_s?)
      status, body = transport.get("#{url}/jwks.json")
      raise Error.new("admin.errors.connect.invalid", "jwks : HTTP #{status}") unless status == 200
      keys = parse(body)["keys"]?.try(&.as_a?) || [] of JSON::Any
      keys.each do |key|
        next unless key["kty"]?.try(&.as_s?) == "EC"
        next if kid && key["kid"]?.try(&.as_s?) != kid
        return parse(String.new(Jose::JWS.verify(token, Jose::JWK::ECKey.from_jwk_hash(key.as_h))))
      rescue Jose::JWS::Error | Jose::JWK::Error | ArgumentError | KeyError
        next
      end
      raise Error.new("admin.errors.connect.invalid", "signature")
    end

    private def self.check(claims : Hash(String, JSON::Any), now : Time) : Nil
      raise Error.new("admin.errors.connect.invalid", "iss") unless claims["iss"]?.try(&.as_s?) == url
      raise Error.new("admin.errors.connect.invalid", "aud") unless audience?(claims)
      expires = claims["exp"]?.try(&.as_i64?) || raise Error.new("admin.errors.connect.invalid", "exp")
      raise Error.new("admin.errors.connect.invalid", "exp") if now - SKEW >= Time.unix(expires)
    end

    private def self.audience?(claims : Hash(String, JSON::Any)) : Bool
      case audience = claims["aud"]?.try(&.raw)
      when String then audience == client_id
      when Array  then audience.compact_map(&.as_s?).includes?(client_id)
      else             false
      end
    end

    private def self.parse(body : String) : Hash(String, JSON::Any)
      JSON.parse(body).as_h? || raise Error.new("admin.errors.connect.invalid", "JSON")
    rescue JSON::ParseException
      raise Error.new("admin.errors.connect.invalid", "JSON")
    end
  end
end

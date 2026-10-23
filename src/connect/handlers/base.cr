# SPDX-License-Identifier: AGPL-3.0-or-later

class Marten::HTTP::Request
  # Session `connect` de la requête, résolue une seule fois.
  property connect_session : PartiduoConnect::Session? = nil
  property connect_session_resolved : Bool = false
end

module PartiduoConnect
  class Denied < Exception
  end

  # Base des handlers : session, compte, langue, lecture des formulaires.
  abstract class BaseHandler < Marten::Handlers::Base
    COOKIE         = "partiduo_connect_session"
    PENDING_COOKIE = "partiduo_connect_pending"
    LOCALE_COOKIE  = "partiduo_connect_locale"

    before_dispatch :activate_locale

    rescue_from Denied do
      error_page(403)
    end

    def session_record : Session?
      unless request.connect_session_resolved
        request.connect_session = Auth::Sessions.find(request.cookies[COOKIE]?.presence, Config.now)
        request.connect_session_resolved = true
      end
      request.connect_session
    end

    def account? : Account?
      session_record.try(&.account)
    end

    def account : Account
      account? || raise Denied.new("session")
    end

    def level : Int32
      (session_record.try(&.level) || 0).to_i32
    end

    # Session complète : au niveau exigé pour gérer son compte.
    def elevated? : Bool
      !account?.nil? && level >= Auth::REQUIRED
    end

    def field(name : String) : String
      (request.data.fetch(name, nil).try(&.to_s) || "").strip
    end

    def query(name : String) : String
      request.query_params.fetch(name, nil).try(&.to_s) || ""
    end

    def query_hash : Hash(String, String)
      hash = {} of String => String
      request.query_params.each { |key, values| hash[key] = values.last.to_s unless values.empty? }
      hash
    end

    def ip : String
      request.headers["X-Real-IP"]?.presence || ""
    end

    def user_agent : String
      request.headers["User-Agent"]? || ""
    end

    def page(template : String, values = {} of String => String, status : Int32 = 200) : Marten::HTTP::Response
      context["current_account"] = account?
      context["elevated"] = elevated?
      context["locale"] = I18n.locale
      context["locales"] = Config::LOCALES
      context["current_path"] = request.full_path
      # Provenance du code (AGPL-3.0, art. 13) : pied de page.
      context["app_version"] = VERSION
      context["source_url"] = PartiduoLicences::SOURCE_URL
      render(template, listed(values), status: status)
    end

    # Une liste vide est vraie dans un `{% if %}` de Marten : elle passe
    # comme `nil`.
    private def listed(values : Hash)
      values.transform_values { |value| value.is_a?(Array) && value.empty? ? nil : value }
    end

    def error_page(status : Int32, message_key : String? = nil) : Marten::HTTP::Response
      page("connect/error.html", {"status" => status, "title_key" => "connect.errors.http.#{status}",
                                  "message_key" => message_key || "connect.errors.http.help"}, status: status)
    end

    def open_session(opened : Auth::Sessions::Opened) : Nil
      request.cookies.set(COOKIE, opened.token, http_only: true, secure: secure_cookies?, same_site: "Lax")
      request.connect_session = opened.session
      request.connect_session_resolved = true
    end

    # Cookie `Lax` : le retour d'un client vers `/authorize` est une
    # navigation de premier niveau d'un autre site, qui doit retrouver la
    # session.
    def secure_cookies? : Bool
      request.secure? || Marten.env.production?
    end

    # Adresse de retour sûre : un chemin local seulement.
    def safe_next(value : String, default : String = "/account") : String
      value.starts_with?('/') && !value.starts_with?("//") && !value.includes?('\\') ? value : default
    end

    # Après une connexion : la suite si le compte est complet, sinon la page
    # du compte pour finir l'enrôlement.
    def after_login(next_path : String) : String
      target = safe_next(next_path)
      return target if elevated?
      "/account?next=#{URI.encode_www_form(target)}"
    end

    # Client nommé par une adresse `/authorize?…` (titre de la connexion).
    def client_for_next(next_path : String) : Client?
      return unless next_path.starts_with?("/authorize?")
      client_id = URI::Params.parse(next_path.partition('?')[2])["client_id"]?
      client_id ? Client.filter(client_id: client_id, active: true).first : nil
    end

    # Langue du compte, sinon celle de la visite (cookie), sinon celle du
    # navigateur (négociée par le middleware I18n de Marten), sinon fr.
    private def activate_locale
      locale = account?.try(&.locale.presence) || request.cookies[LOCALE_COOKIE]?
      I18n.activate(locale) if locale && Config::LOCALES.includes?(locale)
      nil
    end
  end

  # Écran d'un compte ouvert (enrôlement compris).
  abstract class SignedInHandler < BaseHandler
    before_dispatch :require_session

    private def require_session
      return redirect("/login?next=#{URI.encode_www_form(request.full_path)}") if account?.nil?
      nil
    end

    def require_elevated! : Nil
      raise Denied.new("level") unless elevated?
    end
  end

  # Point d'API sans cookie : pas de jeton CSRF (variable de classe non
  # héritée, d'où la macro).
  abstract class ApiHandler < Marten::Handlers::Base
    macro inherited
      protect_from_forgery false
    end

    def form : Hash(String, String)
      hash = {} of String => String
      request.data.each { |key, values| hash[key] = values.last.to_s unless values.empty? }
      hash
    end

    def no_store(response : Marten::HTTP::Response) : Marten::HTTP::Response
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
      response
    end
  end
end

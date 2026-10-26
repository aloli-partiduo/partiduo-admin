# SPDX-License-Identifier: AGPL-3.0-or-later

class Marten::HTTP::Request
  # Session d'administration de la requête, résolue une seule fois.
  property admin_session : PartiduoAdmin::Session? = nil
  property admin_session_resolved : Bool = false
end

module PartiduoAdmin
  # Champ de formulaire présenté par `admin/_field.html` : étiquette reliée,
  # aide et erreurs annoncées (`aria-describedby`, `aria-invalid`).
  class FormField
    include Marten::Template::Object::Auto

    # Option d'un choix ; `help` : ligne d'explication d'un bouton radio.
    record Option, value : String, label : String, selected : Bool = false, help_text : String = "" do
      include Marten::Template::Object::Auto

      # `nil` si vide (une chaîne vide est vraie dans un gabarit).
      def help : String?
        help_text.presence
      end
    end

    getter name : String
    getter label : String
    getter value : String
    getter type : String
    getter options : Array(Option)
    getter errors : Array(String)
    getter required : Bool
    # Aide : `nil` si vide (une chaîne vide est vraie dans un gabarit de
    # Marten : `{% if field.help %}` produisait un paragraphe vide et un
    # `aria-describedby` vers lui).
    @help : String

    def help : String?
      @help.presence
    end

    getter checked : Bool

    def initialize(@name, @label, @value = "", @type = "text", @options = [] of Option, @errors = [] of String,
                   @required = false, @help = "", @checked = false)
    end

    def id : String
      "f-#{name.tr("_", "-")}"
    end

    def error_id : String
      "#{id}-error"
    end

    def help_id : String
      "#{id}-help"
    end

    def describedby : String?
      ids = [] of String
      ids << help_id if help
      ids << error_id unless errors.empty?
      ids.join(' ').presence
    end

    def has_errors : Bool
      !errors.empty?
    end
  end

  # Drapeaux pour un gabarit (`{% if can.archive %}`) : un objet plutôt
  # qu'un dictionnaire, que les gabarits de Marten lisent mal au-delà de
  # huit entrées (partiduo-app, B-UI-004).
  class Flags
    include Marten::Template::Object::Auto

    def initialize(@flags : Hash(String, Bool))
    end

    def [](key : String) : Bool
      @flags.fetch(key) { raise KeyError.new(key) }
    end
  end

  # Base des handlers : session, utilisateur, langue, lecture des
  # formulaires, traduction des erreurs.
  abstract class BaseHandler < Marten::Handlers::Base
    COOKIE         = "partiduo_admin_session"
    PENDING_COOKIE = "partiduo_admin_pending"
    LOCALE_COOKIE  = "partiduo_admin_locale"

    before_dispatch :activate_locale

    rescue_from Access::Denied do
      error_page(403)
    end

    def session_record : Session?
      unless request.admin_session_resolved
        request.admin_session = Auth::Sessions.find(request.cookies[COOKIE]?.presence, Config.now)
        request.admin_session_resolved = true
      end
      request.admin_session
    end

    def user? : User?
      session_record.try(&.user)
    end

    def user : User
      user? || raise Access::Denied.new("session")
    end

    def level : Int32
      (session_record.try(&.level) || 0).to_i32
    end

    def elevated? : Bool
      if current = user?
        level >= Auth.required_level(current)
      else
        false
      end
    end

    def field(name : String) : String
      (request.data.fetch(name, nil).try(&.to_s) || "").strip
    end

    def fields(name : String) : Array(String)
      values = request.data.fetch_all(name, nil)
      return [] of String if values.nil?
      values.map(&.to_s.strip).reject(&.empty?)
    end

    def query(name : String) : String
      request.query_params.fetch(name, nil).try(&.to_s) || ""
    end

    # Lignes par page des listes (utilisateurs, structures).
    PAGE_SIZE = 25

    # Page demandée (`page`) d'une liste, et de quoi la parcourir
    # (`_pagination.html`) : liens précédent et suivant qui gardent les
    # autres paramètres de la recherche (`kept`).
    def paginate(scope : Marten::DB::Query::Set(M), kept : Hash(String, String)) forall M
      page = scope.paginator(PAGE_SIZE).page(query("page").to_i? || 1)
      link = ->(number : Int32) do
        params = kept.reject { |_, value| value.empty? }
        params["page"] = number.to_s unless number == 1
        params.empty? ? request.path : "#{request.path}?#{URI::Params.encode(params)}"
      end
      pager = {
        "number"   => page.number.to_s,
        "pages"    => page.pages_count.to_s,
        "total"    => page.total_count.to_s,
        "previous" => page.previous_page? ? link.call(page.number - 1) : "",
        "next"     => page.next_page? ? link.call(page.number + 1) : "",
        "several"  => page.pages_count > 1,
      }
      {page.to_a, pager}
    end

    def id_param(name : String = "id") : Int64
      params[name].to_s.to_i64
    end

    def ip : String
      if Marten.settings.use_x_forwarded_proto?
        request.headers["X-Real-IP"]?.presence || request.host.to_s
      else
        request.headers["X-Real-IP"]?.presence || ""
      end
    end

    def user_agent : String
      request.headers["User-Agent"]? || ""
    end

    def htmx? : Bool
      request.headers["HX-Request"]? == "true"
    end

    # Redirection compatible HTMX (`HX-Redirect`).
    def go(url : String) : Marten::HTTP::Response
      if htmx?
        response = Marten::HTTP::Response.new(content: "", status: 204)
        response.headers["HX-Redirect"] = url
        response
      else
        redirect(url)
      end
    end

    # Messages d'erreur d'un champ (liste vide s'il n'y en a pas).
    def errs(translated : Hash(String, Array(String)), name : String) : Array(String)
      translated[name]? || [] of String
    end

    def translate(errors : Fleet::Errors) : Hash(String, Array(String))
      errors.transform_values { |keys| keys.map { |key| Catalog.message(key) || I18n.t(key) } }
    end

    def page(template : String, values = {} of String => String, status : Int32 = 200) : Marten::HTTP::Response
      context["current_user"] = user?
      context["elevated"] = elevated?
      context["locale"] = I18n.locale
      context["locales"] = Config::LOCALES
      context["current_path"] = request.full_path
      # Session ouverte par connect : la langue se règle sur la page du
      # compte connect (D-ADM-015), pas par le sélecteur.
      context["connect_account_url"] = session_record.try(&.connect?) ? Connect.url.try { |url| "#{url}/account" } : nil
      # Provenance du code (AGPL-3.0, art. 13) : pied de page.
      context["app_version"] = VERSION
      context["source_url"] = PartiduoLicences::SOURCE_URL
      if current = user?
        context["nav_fleet"] = Access.fleet?(current)
        context["nav_admin"] = !current.file_manager?
        # Admin de cabinet : chiffrement des sauvegardes de son cabinet.
        context["nav_firm_id"] = current.firm_admin? ? current.firm_id : nil
        # Validation à deux : réglage de la structure de l'admin ; pour le
        # super-admin, celui du parc sans cabinet (D-VAL2-001).
        context["nav_approval_firm_id"] = current.firm_admin? ? current.firm_id : (current.super_admin? ? Firm.filter(kind: "fleet").first.try(&.pk) : nil)
        # Assistants ouverts (D-ADM-018) et administrateurs de la structure
        # de l'admin de cabinet (D-ADM-017).
        context["wizard_firm"] = Wizards.allowed?(current, "firm")
        context["wizard_dossier"] = Wizards.allowed?(current, "company")
        # Assistants d'opérations ouverts (D-ADM-022) : tableau de bord,
        # listes et menu.
        wizards = Wizards::KINDS.select { |kind| Wizards.allowed?(current, kind) }
        context["wizard_links"] = wizards.empty? ? nil : wizards.map { |kind| {"kind" => kind, "key" => "admin.wizards.#{kind}.new"} }
        %w[server restore move archive transfer user].each { |kind| context["wizard_#{kind}"] = wizards.includes?(kind) }
        context["open_alerts"] = Alerts.visible(current).count
        context["pending_approvals"] = Approvals.visible(current).filter(state: "pending").count
      end
      render(template, listed(values), status: status)
    end

    # Pour les gabarits de Marten, une liste ou une chaîne vide est vraie
    # dans un `{% if %}` : elles passent comme `nil` (un motif, un lien, un
    # champ facultatif vide s'affichent comme absents). Les valeurs
    # imbriquées (attributs des modèles) passent par leurs méthodes
    # `…_text` ou `presence`.
    private def listed(values : Hash)
      values.transform_values { |value| (value.is_a?(Array) || value.is_a?(String)) && value.empty? ? nil : value }
    end

    def error_page(status : Int32) : Marten::HTTP::Response
      page("admin/error.html", {"status" => status, "title_key" => "admin.errors.http.#{status}"}, status: status)
    end

    def open_session(opened : Auth::Sessions::Opened) : Nil
      # Cookie de session du navigateur : l'échéance est tenue côté serveur.
      request.cookies.set(COOKIE, opened.token, http_only: true, secure: secure_cookies?, same_site: "Strict")
      request.admin_session = opened.session
      request.admin_session_resolved = true
    end

    def secure_cookies? : Bool
      request.secure? || Marten.env.production?
    end

    # Adresse de retour sûre : un chemin local seulement.
    def safe_next(value : String, default : String = "/") : String
      value.starts_with?('/') && !value.starts_with?("//") && !value.includes?('\\') ? value : default
    end

    # Session ouverte par connect : langue du compte connect (claim `locale`,
    # D-ADM-015), sinon celle de la visite (cookie), sinon celle du navigateur
    # (middleware I18n de Marten), sinon fr. Autre session : langue de
    # l'utilisateur, puis cookie.
    private def activate_locale
      session = session_record
      preferred = session && session.connect? ? session.locale.presence : user?.try(&.locale)
      locale = preferred || request.cookies[LOCALE_COOKIE]?
      I18n.activate(locale) if locale && Config::LOCALES.includes?(locale)
      nil
    end
  end

  # Écran derrière la connexion, au niveau exigé par le rôle (ADR-008 D2).
  abstract class ScreenHandler < BaseHandler
    before_dispatch :require_elevated

    private def require_elevated
      return redirect("/login?next=#{URI.encode_www_form(request.full_path)}") if user?.nil?
      unless elevated?
        flash["warning"] = I18n.t("admin.account.elevation_needed")
        return redirect("/account")
      end
      nil
    end

    def dossier! : Dossier
      dossier = Dossier.filter(id: id_param).first
      raise Access::Denied.new("dossier") if dossier.nil? || !Access.in_scope?(user, dossier)
      dossier
    end

    def require_fleet! : Nil
      raise Access::Denied.new("fleet") unless Access.fleet?(user)
    end

    def require_admin! : Nil
      raise Access::Denied.new("admin") if user.file_manager?
    end

    # Autres extensions d'un dossier : codes absents du catalogue (D-ADM-016).
    def other_field(extensions : Array(String), t : Hash(String, Array(String))) : FormField
      FormField.new("extensions", I18n.t("admin.pieces.other.label"), PieceForm.others(extensions),
        errors: errs(t, "extensions"), help: I18n.t("admin.pieces.other.help"))
    end

    # Erreurs du choix des pièces, annoncées en tête du choix : celles qui
    # ne relèvent d'aucune famille (aucun module officiel, module inconnu),
    # puis celles de chaque famille, répétées sous sa légende ; `nil` sans
    # erreur (une liste vide est vraie dans un gabarit).
    def piece_errors(t : Hash(String, Array(String))) : Array(String)?
      list = errs(t, "modules") + Catalog::FAMILIES.flat_map { |family| errs(t, "family.#{family}") }
      list.empty? ? nil : list
    end

    # Réglages de `pieces.js` : type et régime fixés (vides à la création,
    # où ils se choisissent), pièces actives au départ, messages traduits.
    def picker(kind : String, initial : Array(String) = [] of String, regime : String = "") : PiecePicker
      PiecePicker.new(kind, initial, regime)
    end
  end

  # Pages du compte : ouvertes à toute session, même d'enrôlement ou sous le
  # niveau exigé, pour qu'elle s'élève.
  abstract class AccountScreenHandler < BaseHandler
    before_dispatch :require_session

    private def require_session
      return redirect("/login") if user?.nil?
      nil
    end
  end
end

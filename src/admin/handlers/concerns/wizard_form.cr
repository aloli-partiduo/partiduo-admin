# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Champs d'une étape d'assistant (D-ADM-018), remplis depuis le
  # brouillon, avec les erreurs traduites des services ; lignes des
  # administrateurs et récapitulatif.
  class WizardForm
    alias Translated = Hash(String, Array(String))

    # Ligne d'un administrateur de cabinet : adresse, prénom, nom, langue.
    class AdminRow
      include Marten::Template::Object::Auto

      getter index : String
      getter email : String
      getter first_name : String
      getter last_name : String
      getter locales : Array(FormField::Option)
      getter errors : Array(String)

      def initialize(@index, @email, @first_name, @last_name, @locales, @errors)
      end

      def has_errors : Bool
        !errors.empty?
      end
    end

    # Autre administrateur d'un dossier : une adresse.
    class ExtraAdmin
      include Marten::Template::Object::Auto

      getter index : String
      getter email : String

      def initialize(@index, @email)
      end
    end

    def initialize(@handler : ScreenHandler, @draft : WizardDraft, @errors : Translated)
    end

    private def user : User
      @handler.user
    end

    private def e(name : String) : Array(String)
      @errors[name]? || [] of String
    end

    private def text(name : String) : String
      @draft.text(name)
    end

    private def option(value : String, label : String, current : String, help : String = "") : FormField::Option
      FormField::Option.new(value, label, value == current, help)
    end

    private def locales(current : String) : Array(FormField::Option)
      Config::LOCALES.map { |code| option(code, I18n.t("admin.languages.#{code}"), current) }
    end

    def fields(step : String) : Array(FormField)
      case step
      when "identity"   then @draft.kind! == "firm" ? firm_identity : dossier_identity
      when "activity"   then [profile_field]
      when "attachment" then attachment
      when "admins"     then @draft.kind! == "firm" ? [] of FormField : [first_admin]
      when "options"    then [encryption_field]
      else                   [] of FormField
      end
    end

    # --- Cabinet ------------------------------------------------------------------

    private def firm_identity : Array(FormField)
      kind = text("kind").presence || "cabinet"
      [
        FormField.new("kind", I18n.t("admin.firms.kind"), kind, "radios",
          Wizards::FIRM_KINDS.map { |code| option(code, I18n.t("admin.firms.kinds.#{code}"), kind, I18n.t("admin.wizards.firm.kinds.#{code}")) },
          e("kind"), required: true),
        FormField.new("name", I18n.t("admin.firms.name"), text("name"), errors: e("name"), required: true),
        FormField.new("siren", I18n.t("admin.payers.fields.siren"), text("siren"), errors: e("siren")),
        FormField.new("email", I18n.t("admin.users.fields.email"), text("email"), "email", errors: e("email"),
          help: I18n.t("admin.wizards.firm.email_help")),
      ]
    end

    def admin_rows : Array(AdminRow)
      rows = Wizards.firm_admin_rows(@draft)
      slots = Math.max(rows.size + (text("kind") == "independent" && rows.size >= 1 ? 0 : 1), text("slots_admins").to_i? || 1)
      slots = Math.min(Math.max(slots, 1), Administrators::LIMIT)
      (0...slots).map do |index|
        row = rows[index]?
        AdminRow.new((index + 1).to_s, row.try(&.email) || "", row.try(&.first_name) || "", row.try(&.last_name) || "",
          locales(row.try(&.locale) || I18n.locale), e("admins.#{index}"))
      end
    end

    private def encryption_field : FormField
      mode = text("encryption").presence || "exploitation"
      FormField.new("encryption", I18n.t("admin.encryption.mode"), mode, "radios",
        Wizards::FIRM_ENCRYPTIONS.map { |code| option(code, I18n.t("admin.encryption.modes.#{code}"), mode, I18n.t("admin.wizards.firm.encryption.#{code}")) },
        e("encryption"), help: I18n.t("admin.wizards.firm.encryption_help"))
    end

    # --- Entrepreneur et foyer ----------------------------------------------------

    private def dossier_identity : Array(FormField)
      regime = text("regime").presence || "fr"
      locale = text("locale").presence || I18n.locale
      fields = [
        FormField.new("label", I18n.t("admin.wizards.#{@draft.kind!}.label"), text("label"), errors: e("label"), required: true),
        FormField.new("slug", I18n.t("admin.dossiers.fields.slug"), text("slug"), errors: e("slug"), required: true,
          help: I18n.t("admin.dossiers.help.slug", domain: Config.domain)),
        FormField.new("regime", I18n.t("admin.dossiers.fields.regime"), regime, "radios",
          Catalog::REGIMES.map { |code| option(code, I18n.t("admin.regimes.#{code}"), regime) }, e("regime"), required: true,
          help: I18n.t("admin.dossiers.help.regime")),
        FormField.new("locale", I18n.t("admin.dossiers.fields.locale"), locale, "select", locales(locale), e("locale")),
      ]
      if @draft.kind! == "company"
        fields << FormField.new("siren", I18n.t("admin.dossiers.fields.siren"), text("siren"), errors: e("siren"))
        fields << FormField.new("vat_number", I18n.t("admin.dossiers.fields.vat_number"), text("vat_number"))
      end
      fields
    end

    # Profils permis au régime choisi (micro-entreprise et profession
    # libérale : régimes de leur module).
    private def profile_field : FormField
      regime = text("regime").presence || "fr"
      profile = text("profile").presence || "company"
      codes = Wizards::PROFILES.keys.reject { |code| code != "company" && Catalog.regime_excluded?(code, regime) }
      FormField.new("profile", I18n.t("admin.wizards.company.profile"), profile, "radios",
        codes.map { |code| option(code, I18n.t("admin.wizards.company.profiles.#{code}"), profile, I18n.t("admin.wizards.company.profiles_help.#{code}")) },
        e("profile"), required: true, help: I18n.t("admin.wizards.company.profile_help"))
    end

    private def attachment : Array(FormField)
      fields = [] of FormField
      unless user.firm_admin?
        firms = Access.firms(user).filter(active: true).order("name").map { |firm| option(firm.pk.to_s, firm.name.to_s, text("firm_id")) }
        fields << FormField.new("firm_id", I18n.t("admin.dossiers.fields.firm"), text("firm_id"), "select",
          [option("", I18n.t("admin.choose"), "x")] + firms, e("firm_id"), required: true)
      end
      mode = text("payer_mode").presence || "new"
      fields << FormField.new("payer_mode", I18n.t("admin.dossiers.fields.payer"), mode, "radios",
        %w[new existing].map { |code| option(code, I18n.t("admin.wizards.payer.#{code}"), mode, I18n.t("admin.wizards.payer.#{@draft.kind!}_#{code}_help")) },
        required: true)
      payers = Access.payers(user).order("name").map { |payer| option(payer.pk.to_s, "#{payer.name} (#{payer.firm_name})", text("payer_id")) }
      fields << FormField.new("payer_id", I18n.t("admin.wizards.payer.choose"), text("payer_id"), "select",
        [option("", I18n.t("admin.choose"), "x")] + payers, e("payer_id"), help: I18n.t("admin.wizards.payer.choose_help"))
      fields += payer_fields
      servers = Server.filter(active: true).order("name").map { |server| option(server.pk.to_s, "#{server.name} — #{server.domain}", text("server_id")) }
      first_server = servers.first?.try(&.value) || ""
      fields << FormField.new("server_id", I18n.t("admin.dossiers.fields.server"), text("server_id").presence || first_server, "select",
        servers.map { |item| option(item.value, item.label, text("server_id").presence || first_server) }, e("server_id"), required: true)
      schedule = text("backup_schedule").presence || "daily"
      fields << FormField.new("backup_schedule", I18n.t("admin.dossiers.fields.backup_schedule"), schedule, "select",
        Dossier::SCHEDULES.map { |code| option(code, I18n.t("admin.schedules.#{code}"), schedule) })
      fields << FormField.new("backup_retention_days", I18n.t("admin.dossiers.fields.backup_retention_days"),
        text("backup_retention_days").presence || "30", "number", errors: e("backup_retention_days"))
      fields
    end

    # Adresse du donneur d'ordre à créer.
    private def payer_fields : Array(FormField)
      [
        FormField.new("payer_street", I18n.t("admin.payers.fields.street"), text("payer_street"), errors: e("payer_street"),
          help: I18n.t("admin.wizards.payer.address_help")),
        FormField.new("payer_postcode", I18n.t("admin.payers.fields.postcode"), text("payer_postcode")),
        FormField.new("payer_city", I18n.t("admin.payers.fields.city"), text("payer_city"), errors: e("payer_city")),
        FormField.new("payer_country", I18n.t("admin.payers.fields.country"), text("payer_country").presence || "FR",
          errors: e("payer_country"), help: I18n.t("admin.payers.help.country")),
        FormField.new("payer_contact_email", I18n.t("admin.payers.fields.contact_email"), text("payer_contact_email"), "email",
          errors: e("payer_contact_email")),
      ]
    end

    private def first_admin : FormField
      FormField.new("admin_email", I18n.t("admin.wizards.admins.first"), text("admin_email"), "email",
        errors: e("admin_email"), required: true, help: I18n.t("admin.dossiers.help.admin_email"))
    end

    def extra_admins : Array(ExtraAdmin)
      emails = @draft.list("extra_admins").reject(&.empty?)
      slots = Math.min(Math.max(emails.size + 1, text("slots_admins").to_i? || 1), Administrators::LIMIT - 1)
      (0...slots).map { |index| ExtraAdmin.new((index + 1).to_s, emails[index]? || "") }
    end

    # --- Récapitulatif --------------------------------------------------------------

    # Une section par étape : son numéro (lien « Modifier »), ses valeurs.
    def summary : Array(Hash(String, String | Array(Hash(String, String))))
      Wizards.steps(@draft.kind!).each_with_index.compact_map do |step, index|
        next if step == "summary"
        {"number" => (index + 1).to_s, "key" => "admin.wizards.steps.#{step}",
         "link" => "/wizards/#{@draft.kind!}?step=#{index + 1}", "items" => items(step)}
      end.to_a
    end

    private def item(label : String, value : String) : Hash(String, String)
      {"label" => label, "value" => value.presence || "—"}
    end

    private def items(step : String) : Array(Hash(String, String))
      case step
      when "identity" then identity_items
      when "activity" then [item(I18n.t("admin.wizards.company.profile"), I18n.t("admin.wizards.company.profiles.#{text("profile").presence || "company"}"))]
      when "modules" then [item(I18n.t("admin.dossiers.fields.modules"), Catalog.labels(@draft.list("modules")).join(", ")),
                           item(I18n.t("admin.dossiers.fields.extensions"), Catalog.labels(@draft.list("extensions")).join(", "))]
      when "attachment" then attachment_items
      when "admins"     then admin_items
      else                   [item(I18n.t("admin.encryption.mode"), I18n.t("admin.encryption.modes.#{text("encryption").presence || "exploitation"}"))]
      end
    end

    private def identity_items : Array(Hash(String, String))
      if @draft.kind! == "firm"
        return [item(I18n.t("admin.firms.kind"), I18n.t("admin.firms.kinds.#{text("kind").presence || "cabinet"}")),
                item(I18n.t("admin.firms.name"), text("name")), item(I18n.t("admin.payers.fields.siren"), text("siren")),
                item(I18n.t("admin.users.fields.email"), text("email"))]
      end
      [item(I18n.t("admin.wizards.#{@draft.kind!}.label"), text("label")),
       item(I18n.t("admin.dossiers.fields.slug"), text("slug").presence.try { |slug| "#{slug}.#{Config.domain}" } || ""),
       item(I18n.t("admin.dossiers.fields.regime"), I18n.t("admin.regimes.#{text("regime").presence || "fr"}")),
       item(I18n.t("admin.dossiers.fields.locale"), I18n.t("admin.languages.#{text("locale").presence || "fr"}"))] +
        (@draft.kind! == "company" ? [item(I18n.t("admin.dossiers.fields.siren"), text("siren")),
                                      item(I18n.t("admin.dossiers.fields.vat_number"), text("vat_number"))] : [] of Hash(String, String))
    end

    private def attachment_items : Array(Hash(String, String))
      firm = Wizards.firm_id(user, @draft).try { |id| Firm.filter(id: id).first.try(&.name.to_s) } || ""
      payer = if Wizards.new_payer?(@draft)
                I18n.t("admin.wizards.payer.summary_new", name: text("label"),
                  address: [text("payer_street"), "#{text("payer_postcode")} #{text("payer_city")}".strip, text("payer_country")].reject(&.empty?).join(", "))
              else
                text("payer_id").to_i64?.try { |id| Payer.filter(id: id).first.try(&.name.to_s) } || ""
              end
      server = text("server_id").to_i64?.try { |id| Server.filter(id: id).first.try(&.name.to_s) } || ""
      [item(I18n.t("admin.dossiers.fields.firm"), firm), item(I18n.t("admin.dossiers.fields.payer"), payer),
       item(I18n.t("admin.dossiers.fields.server"), server),
       item(I18n.t("admin.dossiers.fields.backup_schedule"),
         "#{I18n.t("admin.schedules.#{text("backup_schedule").presence || "daily"}")} · #{text("backup_retention_days").presence || "30"} j")]
    end

    private def admin_items : Array(Hash(String, String))
      emails = if @draft.kind! == "firm"
                 Wizards.firm_admin_rows(@draft).map { |row| "#{row.email} #{row.first_name} #{row.last_name}".strip }
               else
                 [text("admin_email")] + @draft.list("extra_admins").reject(&.empty?)
               end
      emails.each_with_index.map { |email, index| item("#{I18n.t("admin.administrators.ordinal")} #{index + 1}", email) }.to_a
    end
  end
end

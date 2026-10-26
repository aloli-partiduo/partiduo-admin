# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Note d'une étape d'assistant : niveau Bulma (`info`, `warning`,
  # `danger`, `success`) et texte.
  class WizardNote
    include Marten::Template::Object::Auto

    getter level : String
    getter text : String

    def initialize(@level, @text)
    end
  end

  # Bloc d'information d'une étape (D-ADM-022) : titre, valeurs, notes.
  # Listes vides rendues `nil` : une liste vide est vraie dans un gabarit.
  class WizardSection
    include Marten::Template::Object::Auto

    getter title : String
    @items : Array(Hash(String, String))
    @notes : Array(WizardNote)

    def initialize(@title, @items = [] of Hash(String, String), @notes = [] of WizardNote)
    end

    def items : Array(Hash(String, String))?
      @items.empty? ? nil : @items
    end

    def notes : Array(WizardNote)?
      @notes.empty? ? nil : @notes
    end
  end

  # Clé d'une sauvegarde chiffrée, à l'étape de validation d'une
  # restauration : clé du cabinet utilisée dans le navigateur
  # (`backup-keys.js`), ou clé de sauvegarde sortie de la capsule sur le
  # poste de l'exploitant (D-CHF-005, D-CHF-016). Jamais gardée dans le
  # brouillon.
  class WizardUnlock
    include Marten::Template::Object::Auto

    getter backup : Backup
    getter cabinet : Bool
    getter fingerprint : String
    getter capsule_keys : String
    getter older_key : Bool
    getter errors : Array(String)

    def initialize(@backup, @cabinet, @fingerprint, @capsule_keys, @older_key, @errors)
    end

    def has_errors : Bool
      !errors.empty?
    end
  end

  # Champs, informations et récapitulatif des assistants d'opérations
  # (D-ADM-022) : serveur, restauration, déplacement, archivage,
  # invitation d'un utilisateur. Valeurs lues dans le brouillon, erreurs
  # traduites des services.
  class WizardOperationForm
    alias Translated = Hash(String, Array(String))
    alias Item = Hash(String, String)

    # Emplacement conseillé du jeton sur le serveur (répertoire de
    # configuration de partiduo-agent).
    TOKEN_FILE = "/usr/local/etc/partiduo-agent/token"

    def initialize(@handler : ScreenHandler, @draft : WizardDraft, @errors : Translated)
    end

    private def user : User
      @handler.user
    end

    private def kind : String
      @draft.kind!.to_s
    end

    private def e(name : String) : Array(String)
      @errors[name]? || [] of String
    end

    private def text(name : String) : String
      @draft.text(name)
    end

    private def t(key : String, **options) : String
      options.empty? ? I18n.t("admin.wizards.#{kind}.#{key}") : I18n.t("admin.wizards.#{kind}.#{key}", **options)
    end

    private def option(value : String, label : String, current : String, help : String = "") : FormField::Option
      FormField::Option.new(value, label, value == current, help)
    end

    private def item(label : String, value : String) : Item
      {"label" => label, "value" => value.presence || "—"}
    end

    private def note(level : String, text : String) : WizardNote
      WizardNote.new(level, text)
    end

    private def time(value : Time?) : String
      value.try(&.to_s("%Y-%m-%d %H:%M")) || "—"
    end

    private def dossier : Dossier?
      Wizards.chosen_dossier(user, @draft)
    end

    # --- Champs -------------------------------------------------------------------

    def fields(step : String) : Array(FormField)
      case kind
      when "server"   then server_fields(step)
      when "restore"  then restore_fields(step)
      when "move"     then move_fields(step)
      when "archive"  then archive_fields(step)
      when "transfer" then transfer_fields(step)
      else                 user_fields(step)
      end
    end

    # Transfert vers une autre structure (D-ADM-027).
    private def transfer_fields(step : String) : Array(FormField)
      case step
      when "dossier"      then [dossier_field]
      when "firm"         then [transfer_firm_field]
      when "payer"        then [transfer_payer_field]
      when "consequences" then [reason_field]
      else                     [confirm_field]
      end
    end

    # Structures d'accueil : actives, autres que celle du dossier.
    private def transfer_firm_field : FormField
      current = text("firm_id")
      firms = Firm.filter(active: true).exclude(id: dossier.try(&.firm_id) || 0_i64).order("name").map do |firm|
        option(firm.pk.to_s, "#{firm.name} — #{I18n.t(firm.kind_key)}", current)
      end
      FormField.new("firm_id", I18n.t("admin.wizards.transfer.firm"), current, "select",
        [option("", I18n.t("admin.choose"), "x")] + firms, e("firm_id"), required: true,
        help: firms.empty? ? t("no_firm") : t("firm_help"))
    end

    # Donneurs d'ordre de la structure d'accueil.
    private def transfer_payer_field : FormField
      current = text("payer_id")
      firm = Wizards.transfer_firm(@draft)
      payers = firm ? Payer.filter(firm_id: firm.pk).order("name").to_a : [] of Payer
      options = payers.map { |payer| option(payer.pk.to_s, "#{payer.name} — #{I18n.t(payer.kind_key)}", current) }
      FormField.new("payer_id", I18n.t("admin.dossiers.fields.payer"), current, "select",
        [option("", I18n.t("admin.choose"), "x")] + options, e("payer_id"), required: true,
        help: options.empty? ? t("no_payer") : t("payer_help"))
    end

    private def server_fields(step : String) : Array(FormField)
      case step
      when "identity"     then server_identity
      when "capabilities" then [signing_field]
      else                     [] of FormField
      end
    end

    private def restore_fields(step : String) : Array(FormField)
      case step
      when "dossier" then [dossier_field]
      when "backup"  then [backup_field]
      when "target"  then target_fields
      when "key"     then [confirm_field]
      when "summary" then final?(step) ? [confirm_field] : [] of FormField
      else                [] of FormField
      end
    end

    private def move_fields(step : String) : Array(FormField)
      case step
      when "dossier"      then [dossier_field]
      when "server"       then [destination_field]
      when "consequences" then [reason_field]
      else                     [confirm_field]
      end
    end

    private def archive_fields(step : String) : Array(FormField)
      case step
      when "dossier"      then [dossier_field]
      when "consequences" then [reason_field]
      else                     [confirm_field]
      end
    end

    private def user_fields(step : String) : Array(FormField)
      case step
      when "identity" then user_identity
      when "role"     then role_fields
      when "dossiers" then user_dossier_fields
      when "language" then [locale_field]
      else                 [] of FormField
      end
    end

    private def final?(step : String) : Bool
      Wizards.steps(@draft).last == step
    end

    private def confirm_field : FormField
      FormField.new("confirm", I18n.t("admin.wizards.confirm_legend"), "", "checkboxes",
        [option("yes", I18n.t("admin.wizards.confirm"), "")], e("confirm"), required: true)
    end

    private def server_identity : Array(FormField)
      [
        FormField.new("name", I18n.t("admin.servers.name"), text("name"), errors: e("name"), required: true, help: t("name_help")),
        FormField.new("hostname", I18n.t("admin.servers.hostname"), text("hostname"), errors: e("hostname"), required: true,
          help: t("hostname_help")),
        FormField.new("domain", I18n.t("admin.servers.domain"), Wizards.server_domain(@draft), errors: e("domain"),
          required: true, help: t("domain_help")),
      ]
    end

    private def signing_field : FormField
      FormField.new("public_key", I18n.t("admin.servers.signing_key"), "", errors: e("public_key"), help: t("signing_help"))
    end

    # Dossiers sur lesquels l'opération est possible dans leur état.
    private def dossier_field : FormField
      states = case kind
               when "move" then %w[suspended]
               else             %w[active suspended]
               end
      current = text("dossier_id")
      dossiers = Access.dossiers(user).filter(state__in: states).order("slug").map do |item|
        option(item.pk.to_s, "#{item.slug} — #{item.label} (#{I18n.t(item.state_key)})", current)
      end
      FormField.new("dossier_id", I18n.t("admin.wizards.dossier"), current, "select",
        [option("", I18n.t("admin.choose"), "x")] + dossiers, e("dossier_id"), required: true,
        help: dossiers.empty? ? t("no_dossier") : t("dossier_help"))
    end

    private def backup_field : FormField
      current = text("backup_id")
      backups = dossier.try { |chosen| Backup.filter(dossier_id: chosen.pk, state__in: %w[done verified]).order("-taken_at").to_a.first(30) } || [] of Backup
      options = backups.map do |backup|
        label = "#{time(backup.taken_at)} · #{I18n.t(backup.kind_key)} · #{I18n.t(backup.encryption_key)}"
        help = I18n.t("admin.wizards.restore.backup_line", version: backup.version.to_s.presence || "—",
          tested: backup.test_restored_at.try(&.to_s("%Y-%m-%d")) || "—")
        option(backup.pk.to_s, label, current, help)
      end
      FormField.new("backup_id", I18n.t("admin.wizards.restore.backup"), current, "radios", options, e("backup_id"),
        required: true, help: options.empty? ? t("no_backup") : t("backup_help"))
    end

    private def target_fields : Array(FormField)
      target = Wizards.restore_target(@draft)
      [
        FormField.new("target", I18n.t("admin.restore.target"), target, "radios",
          Wizards.restore_targets(user, dossier).map { |code| option(code, I18n.t("admin.restore.#{code}"), target, t("targets.#{code}")) },
          e("target"), required: true),
        FormField.new("new_slug", I18n.t("admin.restore.new_slug"), text("new_slug"), errors: e("new_slug"),
          help: I18n.t("admin.wizards.restore.new_slug_help", domain: dossier.try(&.server.try(&.domain.to_s)) || Config.domain)),
      ]
    end

    private def destination_field : FormField
      current = text("server_id")
      servers = Server.filter(active: true).exclude(id: dossier.try(&.server_id) || 0_i64).order("name").map do |server|
        option(server.pk.to_s, "#{server.name} — #{server.hostname}", current)
      end
      FormField.new("server_id", I18n.t("admin.move.server"), current, "select",
        [option("", I18n.t("admin.choose"), "x")] + servers, e("server_id"), required: true,
        help: servers.empty? ? I18n.t("admin.move.no_server") : t("server_help"))
    end

    private def reason_field : FormField
      FormField.new("reason", I18n.t("admin.reason"), text("reason"), "textarea", errors: e("reason"), required: true,
        help: t("reason_help"))
    end

    private def user_identity : Array(FormField)
      [
        FormField.new("email", I18n.t("admin.users.fields.email"), text("email"), "email", errors: e("email"), required: true,
          help: t("email_help")),
        FormField.new("first_name", I18n.t("admin.users.fields.first_name"), text("first_name")),
        FormField.new("last_name", I18n.t("admin.users.fields.last_name"), text("last_name")),
      ]
    end

    private def role_fields : Array(FormField)
      role = Wizards.user_role(@draft)
      fields = [FormField.new("role", I18n.t("admin.users.fields.role"), role, "radios",
        Access.assignable_roles(user).map { |code| option(code, I18n.t("admin.roles.#{code}"), role, t("roles.#{code}")) },
        e("role"), required: true)]
      if user.super_admin?
        current = text("firm_id")
        firms = Firm.all.order("name").map { |firm| option(firm.pk.to_s, firm.name.to_s, current) }
        fields << FormField.new("firm_id", I18n.t("admin.users.fields.firm"), current, "select",
          [option("", "—", current)] + firms, e("firm_id"), help: t("firm_help"))
      end
      fields
    end

    private def user_dossier_fields : Array(FormField)
      return [] of FormField unless Wizards.user_role(@draft) == Config::FILE_MANAGER
      chosen = @draft.list("dossier_ids")
      firm_id = Wizards.user_firm_id(user, @draft)
      dossiers = firm_id ? Access.dossiers(user).filter(firm_id: firm_id).exclude(state: "deleted").order("slug").to_a : [] of Dossier
      options = dossiers.map do |item|
        FormField::Option.new(item.pk.to_s, "#{item.slug} — #{item.label}", chosen.includes?(item.pk.to_s))
      end
      [FormField.new("dossier_ids", I18n.t("admin.wizards.user.dossiers"), "", "checkboxes", options, e("dossier_ids"),
        help: options.empty? ? t("no_dossier") : t("dossiers_help"))]
    end

    private def locale_field : FormField
      locale = text("locale").presence || I18n.locale
      FormField.new("locale", I18n.t("admin.users.fields.locale"), locale, "select",
        Config::LOCALES.map { |code| option(code, I18n.t("admin.languages.#{code}"), locale) }, e("locale"),
        help: t("locale_help"))
    end

    # --- Boutons propres à une étape ------------------------------------------------

    def actions(step : String) : Array(Item)
      case {kind, step}
      when {"server", "connect"} then [{"value" => "rotate", "key" => "admin.wizards.server.rotate"}]
      when {"server", "check"}   then [{"value" => "refresh", "key" => "admin.wizards.server.refresh"}]
      when {"server", "capabilities"} then [{"value" => "signing", "key" => "admin.servers.signing_add"},
                                            {"value" => "probe", "key" => "admin.wizards.server.probe"}]
      else [] of Item
      end
    end

    # --- Informations ---------------------------------------------------------------

    def sections(step : String) : Array(WizardSection)
      case {kind, step}
      when {"server", "connect"}       then connect_sections
      when {"server", "check"}         then check_sections
      when {"server", "capabilities"}  then capability_sections
      when {"restore", "target"}       then target_sections
      when {"restore", "check"}        then signature_sections
      when {"move", "server"}          then destination_sections
      when {"move", "consequences"}    then move_sections
      when {"archive", "consequences"} then archive_sections
      when {"user", "dossiers"}        then user_scope_sections
      when {"user", "language"}        then invitation_sections
      when {_, "summary"}              then summary_sections
      else                                  [] of WizardSection
      end
    end

    private def server : Server?
      Wizards.created_server(@draft)
    end

    private def connect_sections : Array(WizardSection)
      server = self.server || return [] of WizardSection
      command = "partiduo-agent --admin-url #{Config.base_url} --token-file #{TOKEN_FILE} " \
                "--server-name #{server.name} --domain #{server.domain} --mode production"
      [WizardSection.new(t("config_title"),
        [item(t("admin_url"), Config.base_url), item(t("token_file"), TOKEN_FILE), item(I18n.t("admin.servers.name"), server.name.to_s),
         item(t("command"), command)],
        [note("info", I18n.t("admin.servers.token_help")), note("warning", t("token_lost"))])]
    end

    private def check_sections : Array(WizardSection)
      server = self.server || return [] of WizardSection
      connected = Wizards.connected?(server)
      [WizardSection.new(t("connection_title"),
        [item(I18n.t("admin.servers.last_seen"), time(server.last_seen_at)), item(I18n.t("admin.servers.agent"), server.agent_version.to_s),
         item(t("mode"), mode_label(server))],
        [connected ? note("success", t("connected")) : note("warning", t("waiting"))])]
    end

    private def mode_label(server : Server) : String
      mode = server.agent_mode.to_s
      %w[dry-run local production].includes?(mode) ? t("modes.#{mode.tr("-", "_")}") : (mode.presence || "—")
    end

    private def capability_sections : Array(WizardSection)
      server = self.server || return [] of WizardSection
      agent_notes = [] of WizardNote
      agent_notes << note("warning", t("version_differs", console: VERSION)) if !server.agent_version.to_s.empty? && server.agent_version != VERSION
      agent_notes << note("warning", t("dry_run")) if server.agent_mode == "dry-run"
      disk = server.disk_total_bytes ? [item(I18n.t("admin.health.disk"), server.disk_free_percent)] : [] of Item
      disk_notes = disk.empty? ? [note("info", t("disk_unknown"))] : [] of WizardNote
      usage = LetsEncrypt.usage.find { |entry| entry.domain == server.domain } || LetsEncrypt::Usage.new(server.domain.to_s, 0, Config::LE_WEEKLY_LIMIT)
      keys = server.signing_keys.reject(&.revoked)
      key_notes = keys.empty? ? [note("warning", t("no_signing_key"))] : [note("success", t("signing_ready"))]
      [
        WizardSection.new(t("agent_title"), [item(I18n.t("admin.servers.agent"), server.agent_version.to_s), item(t("mode"), mode_label(server))], agent_notes),
        WizardSection.new(t("disk_title"), disk, disk_notes),
        WizardSection.new(I18n.t("admin.quota.title"), [item(server.domain.to_s, "#{usage.issued} / #{usage.limit}")]),
        WizardSection.new(I18n.t("admin.servers.signing_title"), keys.map { |key| item(t("signing_fingerprint"), key.fingerprint.to_s) }, key_notes),
      ]
    end

    # Dossier suspendu que le super-admin déplace : la cible « déplacement »
    # (ADR-013 D7).
    private def target_sections : Array(WizardSection)
      return [] of WizardSection unless Wizards.restore_targets(user, dossier).includes?("move")
      [WizardSection.new(I18n.t("admin.move.title"), notes: [note("info", t("move_hint"))])]
    end

    # Contrôle de signature, intégrité et clé de la sauvegarde retenue.
    private def signature_sections : Array(WizardSection)
      chosen = dossier.try { |item| Wizards.restore_backup(@draft, item) } || return [] of WizardSection
      state = Wizards.signature_state(chosen)
      level = case state
              when "known_key"                 then "success"
              when "unsigned", "no_server_key" then "warning"
              else                                  "danger"
              end
      key_note = if chosen.cabinet_sealed
                   note("info", t("key_cabinet"))
                 elsif chosen.sealed
                   note("info", t("key_exploitation"))
                 else
                   note("info", t("key_none"))
                 end
      [
        WizardSection.new(t("signature_title"),
          [item(I18n.t("admin.backups.origin"), chosen.origin.to_s), item(t("signing_key"), chosen.signing_key.to_s)],
          [note(level, t("signatures.#{state}")), note("info", t("signature_agent"))]),
        WizardSection.new(t("integrity_title"),
          [item(I18n.t("admin.backups.taken_at"), time(chosen.taken_at)), item("SHA-256", chosen.sha256.to_s),
           item(I18n.t("admin.backups.version"), chosen.version.to_s), item(I18n.t("admin.backups.tested"), chosen.test_restored_at.try(&.to_s("%Y-%m-%d")) || "")]),
        WizardSection.new(I18n.t("admin.encryption.title"), [item(I18n.t("admin.encryption.column"), I18n.t(chosen.encryption_key))], [key_note]),
      ]
    end

    private def destination_sections : Array(WizardSection)
      target = text("server_id").to_i64?.try { |id| Server.filter(id: id).first } || return [] of WizardSection
      notes = Wizards.connected?(target) ? [] of WizardNote : [note("warning", t("destination_silent"))]
      [WizardSection.new(t("destination_title"),
        [item(I18n.t("admin.servers.hostname"), target.hostname.to_s), item(I18n.t("admin.servers.domain"), target.domain.to_s),
         item(I18n.t("admin.servers.last_seen"), time(target.last_seen_at)), item(I18n.t("admin.servers.agent"), target.agent_version.to_s)],
        notes)]
    end

    private def move_sections : Array(WizardSection)
      chosen = dossier
      notes = [note("warning", t("warn_name")), note("warning", t("warn_unreachable")), note("info", t("warn_kept")),
               note("info", t("warn_next"))]
      last = chosen.try(&.last_backup)
      suspended = chosen.try(&.suspended_at)
      if last.nil? || (suspended && (last.taken_at || Time::UNIX_EPOCH) < suspended)
        notes.unshift(note("danger", t("warn_backup")))
      end
      [WizardSection.new(t("procedure_title"),
        [item(t("procedure.suspend"), t("procedure.suspend_done")), item(t("procedure.switch"), t("procedure.switch_now")),
         item(t("procedure.restore"), t("procedure.restore_next")), item(t("procedure.retire"), t("procedure.retire_manual"))],
        notes)]
    end

    private def archive_sections : Array(WizardSection)
      chosen = dossier
      mode = chosen.try { |item| I18n.t(item.effective_encryption_key) } || "—"
      [WizardSection.new(t("consequences_title"),
        [item(t("archive_encryption"), mode), item(t("archive_retention"), t("years", count: Protocol::ARCHIVE_RETENTION_YEARS))],
        [note("warning", t("warn_stop")), note("info", t("warn_kept")), note("info", t("warn_restore")), note("info", t("warn_delete"))])]
    end

    private def transfer_step_sections(step : String) : Array(WizardSection)
      case step
      when "firm"         then transfer_firm_sections
      when "consequences" then transfer_sections
      when "summary"      then summary_sections
      else                     [] of WizardSection
      end
    end

    # Structure d'accueil : réglage de validation, chiffrement, clé.
    private def transfer_firm_sections : Array(WizardSection)
      firm = Wizards.transfer_firm(@draft) || return [] of WizardSection
      chosen = dossier
      after = chosen ? Transfers.encryption_after(chosen, firm) : firm.backup_encryption.to_s
      [WizardSection.new(t("destination_title"),
        [item(I18n.t("admin.firms.kind"), I18n.t(firm.kind_key)),
         item(I18n.t("admin.wizards.approval.mode"), I18n.t("admin.dual_approval.modes.#{ApprovalMode.mode(firm)}")),
         item(I18n.t("admin.encryption.title"), I18n.t("admin.encryption.modes.#{after}"))],
        firm.has_backup_key ? [] of WizardNote : [note("info", t("destination_no_key"))])]
    end

    # Conséquences du transfert : accès, donneur d'ordre, chiffrement et
    # sauvegardes, administrateurs du dossier, demandes en attente, accords.
    private def transfer_sections : Array(WizardSection)
      chosen = dossier || return [] of WizardSection
      firm = Wizards.transfer_firm(@draft) || return [] of WizardSection
      managers = Transfers.managers(chosen)
      after = Transfers.encryption_after(chosen, firm)
      [
        WizardSection.new(t("access_title"),
          [item(t("managers"), managers.map(&.email.to_s).join(", ")), item(I18n.t("admin.administrators.title"), Administrators.emails(chosen).join(", "))],
          [note("warning", t("warn_managers")), note("info", t("warn_admins")), note("info", t("warn_requests"))]),
        WizardSection.new(t("payer_title"),
          [item(t("payer_before"), chosen.payer_name), item(t("payer_after"), Wizards.transfer_payer(@draft).try(&.name.to_s) || "")],
          [note("info", t("warn_payer"))]),
        WizardSection.new(I18n.t("admin.encryption.title"),
          [item(t("encryption_before"), I18n.t(chosen.effective_encryption_key)), item(t("encryption_after"), I18n.t("admin.encryption.modes.#{after}"))],
          [note("info", t("warn_encryption")), note("warning", t("warn_backups")), note("info", t("warn_backup_now"))]),
        WizardSection.new(I18n.t("admin.wizards.approval.title"),
          [item(chosen.firm_name, I18n.t("admin.dual_approval.modes.#{ApprovalMode.mode_for(chosen)}")),
           item(firm.name.to_s, I18n.t("admin.dual_approval.modes.#{ApprovalMode.mode(firm)}"))],
          [note("info", I18n.t("admin.wizards.approval.transfer_note"))]),
      ]
    end

    private def user_scope_sections : Array(WizardSection)
      return [] of WizardSection if Wizards.user_role(@draft) == Config::FILE_MANAGER
      [WizardSection.new(I18n.t("admin.wizards.steps.dossiers"), notes: [note("info", t("scope.#{Wizards.user_role(@draft)}"))])]
    end

    # Aperçu du courriel d'invitation, dans la langue choisie ; le lien
    # personnel est créé à la validation.
    private def invitation_sections : Array(WizardSection)
      subject, body = Mailer.invitation_text(text("locale").presence || I18n.locale, t("link_placeholder"))
      [WizardSection.new(t("email_title"), [item(t("email_to"), text("email")), item(t("email_subject"), subject), item(t("email_body"), body)],
        [note("info", t("connect_language")), note("info", t("signup_code"))])]
    end

    # Validation : mode de la structure du dossier. Archivage et déplacement
    # sont des opérations sensibles à deux personnes (une demande, D-ADM-027) ;
    # la restauration reste hors de la validation à deux (la clé d'une
    # sauvegarde chiffrée n'est jamais conservée) ; le transfert exige
    # l'accord des deux structures.
    private def summary_sections : Array(WizardSection)
      return gated_invite_sections if kind == "user"
      return [] of WizardSection unless %w[restore move archive transfer].includes?(kind)
      chosen = dossier || return [] of WizardSection
      mode = ApprovalMode.mode_for(chosen)
      key = case kind
            when "restore"  then "admin.wizards.approval.note"
            when "transfer" then "admin.wizards.approval.transfer_note"
            else                 "admin.wizards.approval.#{mode}_note"
            end
      notes = [note("info", I18n.t(key))]
      notes.unshift(note("warning", I18n.t("admin.wizards.restore.replace_warning"))) if kind == "restore" && Wizards.restore_target(@draft) == "replace"
      items = [item(I18n.t("admin.wizards.approval.mode"), I18n.t("admin.dual_approval.modes.#{mode}"))]
      if kind == "transfer"
        items = [item(chosen.firm_name, I18n.t("admin.dual_approval.modes.#{mode}"))]
        Wizards.transfer_firm(@draft).try { |firm| items << item(firm.name.to_s, I18n.t("admin.dual_approval.modes.#{ApprovalMode.mode(firm)}")) }
      end
      [WizardSection.new(I18n.t("admin.wizards.approval.title"), items, notes)]
    end

    # Invitation d'un admin dans une structure qui a déjà son équipe : une
    # demande, validée selon le réglage de la structure (D-ADM-023).
    private def gated_invite_sections : Array(WizardSection)
      firm = Administrators.invite_gate(@handler.user, Wizards.user_input(@handler.user, @draft)) || return [] of WizardSection
      mode = ApprovalMode.mode(firm)
      # Demande du super-admin retenue jusqu'à l'échéance (D-ADM-028).
      held = mode == ApprovalMode::SINGLE && Approvals.held_firm?(@handler.user, firm)
      [WizardSection.new(I18n.t("admin.wizards.approval.title"),
        [item(I18n.t("admin.wizards.approval.mode"), I18n.t("admin.dual_approval.modes.#{mode}"))],
        [note("info", I18n.t(held ? "admin.dual_approval.note.held" : "admin.firm_approvals.help.wizard"))])]
    end

    # --- Clé de la sauvegarde ---------------------------------------------------------

    def unlock(step : String) : WizardUnlock?
      return unless kind == "restore" && step == "key"
      chosen = dossier || return
      backup = Wizards.restore_backup(@draft, chosen) || return
      return unless backup.sealed
      WizardUnlock.new(backup, backup.cabinet_sealed, BackupCrypto.display_fingerprint(backup.key_fingerprint.to_s),
        backup.capsule_fingerprints.map { |key| "#{BackupCrypto.display_fingerprint(key[0, 16])}…" }.join(", "),
        backup.cabinet_sealed && backup.key_fingerprint != chosen.firm.try(&.backup_key_fingerprint), e("data_key"))
    end

    # --- Récapitulatif ----------------------------------------------------------------

    def summary : Array(Hash(String, String | Array(Item)))
      Wizards.steps(@draft).each_with_index.compact_map do |step, index|
        next if %w[summary key connect check capabilities].includes?(step)
        {"number" => (index + 1).to_s, "key" => "admin.wizards.steps.#{step}",
         "link" => "/wizards/#{kind}?step=#{index + 1}", "items" => items(step)}
      end.to_a
    end

    private def items(step : String) : Array(Item)
      return [item(I18n.t("admin.wizards.dossier"), dossier.try { |chosen| "#{chosen.slug} — #{chosen.label}" } || "")] if step == "dossier"
      return [item(I18n.t("admin.reason"), text("reason"))] if step == "consequences"
      case kind
      when "server"   then server_items
      when "restore"  then restore_items(step)
      when "move"     then [item(I18n.t("admin.move.server"), text("server_id").to_i64?.try { |id| Server.filter(id: id).first.try(&.name.to_s) } || "")]
      when "transfer" then transfer_items(step)
      when "user"     then user_items(step)
      else                 [] of Item
      end
    end

    private def transfer_items(step : String) : Array(Item)
      return [item(I18n.t("admin.wizards.transfer.firm"), Wizards.transfer_firm(@draft).try(&.name.to_s) || "")] if step == "firm"
      [item(I18n.t("admin.dossiers.fields.payer"), Wizards.transfer_payer(@draft).try(&.name.to_s) || "")]
    end

    private def server_items : Array(Item)
      [item(I18n.t("admin.servers.name"), text("name")), item(I18n.t("admin.servers.hostname"), text("hostname")),
       item(I18n.t("admin.servers.domain"), Wizards.server_domain(@draft))]
    end

    private def restore_items(step : String) : Array(Item)
      case step
      when "backup" then backup_items
      when "target" then target_items
      else               check_items
      end
    end

    private def user_items(step : String) : Array(Item)
      case step
      when "identity" then [item(I18n.t("admin.users.fields.email"), text("email")),
                            item(I18n.t("admin.users.fields.first_name"), text("first_name")),
                            item(I18n.t("admin.users.fields.last_name"), text("last_name"))]
      when "role"     then role_items
      when "dossiers" then [item(I18n.t("admin.wizards.user.dossiers"), Wizards.user_dossiers(user, @draft).map(&.slug.to_s).join(", "))]
      else                 [item(I18n.t("admin.users.fields.locale"), I18n.t("admin.languages.#{text("locale").presence || I18n.locale}"))]
      end
    end

    private def backup_items : Array(Item)
      chosen = dossier.try { |item| Wizards.restore_backup(@draft, item) }
      [item(I18n.t("admin.wizards.restore.backup"),
        chosen.try { |backup| "#{time(backup.taken_at)} · #{I18n.t(backup.kind_key)} · #{I18n.t(backup.encryption_key)}" } || "")]
    end

    private def target_items : Array(Item)
      target = Wizards.restore_target(@draft)
      items = [item(I18n.t("admin.restore.target"), I18n.t("admin.restore.#{target}"))]
      items << item(I18n.t("admin.restore.new_slug"), text("new_slug")) if target == "new"
      items
    end

    private def check_items : Array(Item)
      chosen = dossier.try { |item| Wizards.restore_backup(@draft, item) }
      [item(t("signature_title"), chosen.try { |backup| t("signatures.#{Wizards.signature_state(backup)}") } || "")]
    end

    private def role_items : Array(Item)
      firm = Wizards.user_firm_id(user, @draft).try { |id| Firm.filter(id: id).first.try(&.name.to_s) } || ""
      [item(I18n.t("admin.users.fields.role"), I18n.t("admin.roles.#{Wizards.user_role(@draft)}")), item(I18n.t("admin.users.fields.firm"), firm)]
    end
  end
end

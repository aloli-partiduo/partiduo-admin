# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Tableau de bord : alertes ouvertes, dossiers par état, quota Let's
  # Encrypt, dernières tâches.
  class DashboardHandler < ScreenHandler
    def get
      dossiers = Access.dossiers(user)
      counts = Dossier::STATES.map { |state| {"state" => state, "key" => "admin.dossiers.states.#{state}", "count" => dossiers.filter(state: state).count} }
      page("admin/dashboard.html", {
        "counts"    => counts,
        "alerts"    => Alerts.visible(user).order("-opened_at").to_a.first(20),
        "quota"     => LetsEncrypt.usage(Config.now),
        "tasks"     => Access.tasks(user).order("-id").to_a.first(10),
        "approvals" => Approvals.visible(user).filter(state: "pending").order("-id").to_a,
      })
    end
  end

  class DossiersHandler < ScreenHandler
    def get
      scope = Access.dossiers(user).order("slug")
      state = query("state")
      scope = scope.filter(state: state) if Dossier::STATES.includes?(state)
      search = query("q").strip.downcase
      list = scope.to_a
      list = list.select { |dossier| dossier.slug.to_s.includes?(search) || dossier.label.to_s.downcase.includes?(search) } unless search.empty?
      page("admin/dossiers.html", {"dossiers" => list, "state" => state, "q" => query("q"), "states" => Dossier::STATES.map { |code| {"code" => code, "key" => "admin.dossiers.states.#{code}"} },
                                   "can_create" => !user.file_manager?})
    end
  end

  # Création d'un dossier (ADR-008 D3) : régime, modules, extensions,
  # sous-domaine, cabinet, donneur d'ordre obligatoire, administrateur à
  # inviter.
  class DossierNewHandler < ScreenHandler
    def get
      require_admin!
      form(Fleet::DossierInput.new(slug: "", label: "", regime: "fr", firm_id: PartiduoAdmin.id?(user.firm_id),
        server_id: PartiduoAdmin.id?(Server.filter(active: true).order("id").first.try(&.pk))), Fleet::Errors.new)
    end

    def post
      require_admin!
      modules, extensions = PieceForm.split(fields("modules"), fields("extensions"))
      input = Fleet::DossierInput.new(
        slug: field("slug"), label: field("label"), regime: field("regime"), locale: field("locale").presence || "fr",
        siren: field("siren").gsub(/\s/, ""), vat_number: field("vat_number"), modules: modules, extensions: extensions,
        admin_email: field("admin_email"), server_id: field("server_id").to_i64?,
        firm_id: user.firm_admin? ? PartiduoAdmin.id?(user.firm_id) : field("firm_id").to_i64?, payer_id: field("payer_id").to_i64?,
        package: Config.dossier_package, backup_schedule: field("backup_schedule").presence || "daily",
        backup_retention_days: field("backup_retention_days").to_i? || 0, kind: field("kind").presence || "company",
        extra_admins: field("extra_admins").split(/[\s,;]+/).reject(&.empty?))
      outcome = Fleet.create_dossier(user, input)
      if outcome.ok?
        flash["success"] = I18n.t("admin.dossiers.created", slug: outcome.value!.slug.to_s)
        return redirect("/dossiers/#{outcome.value!.pk}")
      end
      form(input, outcome.errors, 422)
    end

    private def form(input : Fleet::DossierInput, errors : Fleet::Errors, status : Int32 = 200)
      t = translate(errors)
      page("admin/dossier_new.html", {
        "identity"     => identity_fields(input, t),
        "choices"      => choice_fields(input, t),
        "families"     => PieceForm.families(nil, nil, input.modules + input.extensions, t),
        "other"        => other_field(input.extensions, t),
        "fields"       => assignment_fields(input, t),
        "base_errors"  => errs(t, "base") + errs(t, "package"),
        "package_key"  => "admin.packages.#{Config.dossier_package}",
        "pieces"       => picker(""),
        "piece_errors" => piece_errors(t),
      }, status: status)
    end

    private def option(value : String, label : String, current : String, help : String = "") : FormField::Option
      FormField::Option.new(value, label, value == current, help)
    end

    private def identity_fields(input : Fleet::DossierInput, t : Hash(String, Array(String))) : Array(FormField)
      [
        FormField.new("slug", I18n.t("admin.dossiers.fields.slug"), input.slug, errors: errs(t, "slug"), required: true,
          help: I18n.t("admin.dossiers.help.slug", domain: Config.domain)),
        FormField.new("label", I18n.t("admin.dossiers.fields.label"), input.label, errors: errs(t, "label"), required: true),
        FormField.new("locale", I18n.t("admin.dossiers.fields.locale"), input.locale, "select",
          Config::LOCALES.map { |code| option(code, I18n.t("admin.languages.#{code}"), input.locale) }, errs(t, "locale")),
        FormField.new("siren", I18n.t("admin.dossiers.fields.siren"), input.siren, errors: errs(t, "siren")),
        FormField.new("vat_number", I18n.t("admin.dossiers.fields.vat_number"), input.vat_number),
      ]
    end

    # Choix uniques, en boutons radio : type de dossier (A-PER-5, jamais
    # modifié ensuite) et régime fiscal.
    private def choice_fields(input : Fleet::DossierInput, t : Hash(String, Array(String))) : Array(FormField)
      [
        FormField.new("kind", I18n.t("admin.dossiers.fields.kind"), input.kind, "radios",
          Protocol::DOSSIER_KINDS.map { |code| option(code, I18n.t("admin.kinds.#{code}"), input.kind, I18n.t("admin.dossiers.help.kinds.#{code}")) },
          errs(t, "kind"), required: true, help: I18n.t("admin.dossiers.help.kind")),
        FormField.new("regime", I18n.t("admin.dossiers.fields.regime"), input.regime, "radios",
          %w[fr be].map { |code| option(code, I18n.t("admin.regimes.#{code}"), input.regime) },
          errs(t, "regime"), required: true, help: I18n.t("admin.dossiers.help.regime")),
      ]
    end

    private def assignment_fields(input : Fleet::DossierInput, t : Hash(String, Array(String))) : Array(FormField)
      firms = Access.firms(user).filter(active: true).order("name").map { |firm| option(firm.pk.to_s, firm.name.to_s, input.firm_id.to_s) }
      payers = Access.payers(user).order("name").map { |payer| option(payer.pk.to_s, "#{payer.name} (#{payer.firm_name})", input.payer_id.to_s) }
      servers = Server.filter(active: true).order("name").map { |server| option(server.pk.to_s, "#{server.name} — #{server.domain}", input.server_id.to_s) }
      fields = [
        FormField.new("admin_email", I18n.t("admin.dossiers.fields.admin_email"), input.admin_email, "email",
          errors: errs(t, "admin_email"), required: true, help: I18n.t("admin.dossiers.help.admin_email")),
        FormField.new("extra_admins", I18n.t("admin.wizards.admins.others"), input.extra_admins.join("\n"), "textarea",
          errors: errs(t, "extra_admins"), help: I18n.t("admin.dossiers.help.extra_admins")),
        FormField.new("server_id", I18n.t("admin.dossiers.fields.server"), input.server_id.to_s, "select", servers,
          errs(t, "server_id"), required: true),
      ]
      unless user.firm_admin?
        fields << FormField.new("firm_id", I18n.t("admin.dossiers.fields.firm"), input.firm_id.to_s, "select", firms,
          errs(t, "firm_id"), required: true, help: firms.empty? ? I18n.t("admin.dossiers.help.no_firm") : "")
      end
      fields << FormField.new("payer_id", I18n.t("admin.dossiers.fields.payer"), input.payer_id.to_s, "select",
        [option("", I18n.t("admin.choose"), "x")] + payers, errs(t, "payer_id"), required: true,
        help: I18n.t(payers.empty? ? "admin.dossiers.help.no_payer" : "admin.dossiers.help.payer"))
      fields << FormField.new("backup_schedule", I18n.t("admin.dossiers.fields.backup_schedule"), input.backup_schedule, "select",
        Dossier::SCHEDULES.map { |code| option(code, I18n.t("admin.schedules.#{code}"), input.backup_schedule) })
      fields << FormField.new("backup_retention_days", I18n.t("admin.dossiers.fields.backup_retention_days"),
        input.backup_retention_days.to_s, "number", errors: errs(t, "backup_retention_days"))
      fields
    end
  end

  # Fiche d'un dossier : inventaire, supervision, sauvegardes, tâches,
  # actions permises au rôle.
  class DossierHandler < ScreenHandler
    def get
      dossier = dossier!
      failed_task = dossier.state == "error" ? Task.filter(dossier_id: dossier.pk, state: "failed").order("-id").first : nil
      managers = user.file_manager? ? [] of User : User.filter(firm_id: dossier.firm_id, role: Config::FILE_MANAGER, active: true).order("email").to_a
      assigned = Assignment.filter(dossier_id: dossier.pk).map(&.user_id)
      admins = Administrators.list(dossier)
      page("admin/dossier.html", {
        "dossier"          => dossier,
        "backups"          => Backup.filter(dossier_id: dossier.pk).order("-id").to_a.first(30),
        "tasks"            => Task.filter(dossier_id: dossier.pk).order("-id").to_a.first(20),
        "failed_task"      => failed_task,
        "can_retry_failed" => failed_task ? Tasks.retryable?(failed_task) && !user.file_manager? : false,
        "approvals"        => Approval.filter(dossier_id: dossier.pk).order("-id").to_a.first(10),
        "alerts"           => Alert.filter(dossier_id: dossier.pk, resolved_at__isnull: true).to_a,
        "managers"         => managers.map { |manager| {"id" => manager.pk.to_s, "email" => manager.email.to_s, "assigned" => assigned.includes?(manager.pk)} },
        "can"              => flags(dossier),
        "encryption_modes" => encryption_modes(dossier),
        "encryption_gated" => Administrators.firm_gated?(dossier.firm!),
        "firm_mode_key"    => dossier.firm!.backup_encryption_key,
        "approval_mode"    => ApprovalMode.mode_for(dossier),
        "confirms_alone"   => Access.can?(user, :approve, dossier),
        "today"            => Config.now.to_s("%F"),
        "move_servers"     => move_servers(dossier),
        "kind_key"         => "admin.kinds.#{dossier.kind.presence || "company"}",
        "admin_count"      => admins.size.to_s,
        "admin_others"     => Math.max(admins.size - 1, 0).to_s,
        "module_labels"    => Catalog.labels(dossier.module_list).join(", "),
        "extension_labels" => Catalog.labels(dossier.extension_list).join(", ").presence,
      })
    end

    # Serveurs vers lesquels un super-admin peut déplacer ce dossier
    # suspendu (ADR-013 D7).
    private def move_servers(dossier : Dossier)
      return [] of Hash(String, String) unless user.super_admin? && dossier.state == "suspended"
      Server.filter(active: true).exclude(id: dossier.server_id).order("name").map do |server|
        {"id" => server.pk.to_s, "name" => server.name.to_s, "hostname" => server.hostname.to_s}
      end
    end

    # Chiffrement des sauvegardes du dossier réglable par cet utilisateur.
    private def encryption?(dossier : Dossier) : Bool
      BackupEncryption.can_manage?(user, dossier.firm!) && Access.can?(user, :restore, dossier) &&
        %w[creating active suspended].includes?(dossier.state)
    end

    private def encryption_modes(dossier : Dossier)
      BackupEncryption::MODES.map do |mode|
        {"value" => mode, "key" => "admin.encryption.modes.#{mode}", "selected" => dossier.backup_encryption == mode}
      end
    end

    # Actions permises au rôle dans l'état du dossier.
    private def flags(dossier : Dossier) : Flags
      Flags.new({
        "modules"         => Access.can?(user, :modules, dossier) && dossier.state == "active",
        "backup"          => Access.can?(user, :backup, dossier) && %w[active suspended].includes?(dossier.state),
        "suspend"         => Access.can?(user, :suspend, dossier) && dossier.state == "active",
        "resume"          => Access.can?(user, :resume, dossier) && dossier.state == "suspended",
        "archive"         => Access.can?(user, :archive, dossier) && %w[active suspended].includes?(dossier.state),
        "restore_archive" => Access.can?(user, :restore_archive, dossier) && dossier.state == "archived",
        "restore"         => Access.can?(user, :restore, dossier) && %w[active suspended].includes?(dossier.state),
        "move"            => user.super_admin? && dossier.state == "suspended",
        "delete"          => Access.can?(user, :request_delete, dossier) && dossier.delete_state?,
        "access"          => Access.can?(user, :request_admin_invite, dossier) && dossier.state == "active",
        "assign"          => !user.file_manager?,
        "encryption"      => encryption?(dossier),
        "transfer"        => Transfers.can_request?(user) && Transfers::STATES.includes?(dossier.state),
      })
    end
  end

  # Modules et extensions d'un dossier actif (ADR-006 D2 : désactiver
  # conserve les données), choisis par familles (D-ADM-016) : seules les
  # pièces admises par le type du dossier sont proposées.
  class DossierModulesHandler < ScreenHandler
    def get
      dossier = dossier!
      raise Access::Denied.new("modules") unless Access.can?(user, :modules, dossier)
      form(dossier, dossier.module_list, dossier.extension_list, Fleet::Errors.new)
    end

    def post
      dossier = dossier!
      modules, extensions = PieceForm.split(fields("modules"), fields("extensions"))
      outcome = Fleet.change_modules(user, dossier, modules, extensions)
      if outcome.ok?
        flash["success"] = I18n.t("admin.tasks.enqueued")
        return redirect("/dossiers/#{dossier.pk}")
      end
      form(dossier, modules, extensions, outcome.errors, 422)
    end

    private def form(dossier : Dossier, modules : Array(String), extensions : Array(String), errors : Fleet::Errors, status = 200)
      t = translate(errors)
      kind = dossier.kind.presence || "company"
      regime = dossier.regime.to_s
      page("admin/dossier_modules.html", {
        "dossier"      => dossier,
        "kind_key"     => "admin.kinds.#{kind}",
        "regime_key"   => "admin.regimes.#{regime}",
        "families"     => PieceForm.families(kind, regime, modules + extensions, t),
        "other"        => other_field(extensions, t),
        "piece_errors" => piece_errors(t),
        "base_errors"  => errs(t, "base"),
        "pieces"       => picker(kind, dossier.module_list + dossier.extension_list, regime),
      }, status: status)
    end
  end

  # Actions sans formulaire : suspendre, réactiver, archiver, restaurer
  # l'archive, sauvegarder.
  class DossierActionHandler < ScreenHandler
    def post
      dossier = dossier!
      action = params["action"].to_s
      # Archivage d'une structure à deux personnes : une demande (D-ADM-027).
      if action == "archive" && Fleet.dual?(dossier)
        request = Approvals.request_archive(user, dossier, field("reason"))
        return DossierApprovalRequestHandler.requested(self, request, dossier)
      end
      outcome = case action
                when "backup" then Fleet.backup_now(user, dossier)
                else               Fleet.lifecycle(user, dossier, action, field("reason"))
                end
      if outcome.ok?
        flash["success"] = I18n.t("admin.tasks.enqueued")
      else
        flash["danger"] = outcome.errors.values.flatten.map { |key| I18n.t(key) }.join(" ")
      end
      go("/dossiers/#{dossier.pk}")
    end
  end

  # Restauration à une date. Si la sauvegarde retenue est chiffrée et
  # qu'aucune clé de sauvegarde n'accompagne la demande, la page de la clé
  # la demande d'abord (D-CHF-005, D-CHF-016).
  class DossierRestoreHandler < ScreenHandler
    def post
      dossier = dossier!
      date = Time.parse(field("date"), "%F", Time::Location::UTC) rescue nil
      backup_id = field("backup_id").to_i64?
      if date && backup_id.nil? && field("data_key").empty? && Access.can?(user, :restore, dossier)
        backup = Fleet.backup_for(dossier, date)
        if backup && backup.sealed
          search = URI::Params.encode({"purpose" => "restore", "target" => field("target"), "new_slug" => field("new_slug"),
                                       "date" => field("date")})
          return go("/backups/#{backup.pk}/unlock?#{search}")
        end
      end
      outcome = if date.nil?
                  Fleet::Outcome(Task).failure("date", "admin.errors.invalid")
                else
                  Fleet.restore(user, dossier, date, field("target"), field("new_slug"), backup_id, field("data_key"))
                end
      if outcome.ok?
        flash["success"] = I18n.t("admin.tasks.enqueued")
      else
        flash["danger"] = outcome.errors.values.flatten.map { |key| I18n.t(key) }.join(" ")
      end
      go("/dossiers/#{dossier.pk}")
    end
  end

  # Déplacement vers un autre serveur (ADR-013 D7) : super-admin, dossier
  # suspendu ; le nom bascule aussitôt.
  class DossierMoveHandler < ScreenHandler
    def post
      dossier = dossier!
      # Structure à deux personnes : une demande (D-ADM-027).
      if Fleet.dual?(dossier)
        request = Approvals.request_move(user, dossier, field("server_id").to_i64?, field("reason"))
        return DossierApprovalRequestHandler.requested(self, request, dossier)
      end
      outcome = Fleet.move(user, dossier, field("server_id").to_i64?, field("reason"))
      if outcome.ok?
        flash[dossier.dns_state == "error" ? "warning" : "success"] =
          I18n.t(dossier.dns_state == "error" ? "admin.move.done_dns_error" : "admin.move.done")
      else
        flash["danger"] = outcome.errors.values.flatten.map { |key| I18n.t(key) }.join(" ")
      end
      go("/dossiers/#{dossier.pk}")
    end
  end

  # Opérations sensibles : suppression définitive, recours d'accès, à une
  # ou deux personnes selon le réglage de la structure (D-VAL2-001).
  class DossierApprovalRequestHandler < ScreenHandler
    # Demande d'archivage ou de déplacement enregistrée (D-ADM-027), ou son
    # refus, sur la fiche du dossier.
    def self.requested(handler : ScreenHandler, request : Fleet::Outcome(Approval), dossier : Dossier) : Marten::HTTP::Response
      if request.ok?
        handler.flash["success"] = I18n.t("admin.approvals.requested", reference: request.value!.reference.to_s)
      else
        handler.flash["danger"] = request.errors.values.flatten.map { |key| I18n.t(key) }.join(" ")
      end
      handler.go("/dossiers/#{dossier.pk}")
    end

    def post
      dossier = dossier!
      outcome = case params["kind"].to_s
                when "delete" then Approvals.request_delete(user, dossier, field("reason"))
                when "access" then Approvals.request_admin_invite(user, dossier, field("email"), field("reason"))
                else               Fleet::Outcome(Approval).failure("base", "admin.errors.invalid")
                end
      if outcome.ok?
        approval = outcome.value!
        # Une personne : le demandeur habilité confirme aussitôt, après
        # ré-authentification (D-VAL2-004).
        if Approvals.can_confirm_alone?(user, approval)
          flash["info"] = I18n.t("admin.dual_approval.requested_single", reference: approval.reference.to_s)
          return go("/approvals/#{approval.pk}/confirm")
        end
        key = approval.mode == ApprovalMode::DUAL ? "admin.approvals.requested" : "admin.dual_approval.requested_admin"
        flash["success"] = I18n.t(key, reference: approval.reference.to_s)
      else
        flash["danger"] = outcome.errors.values.flatten.map { |key| I18n.t(key) }.join(" ")
      end
      go("/dossiers/#{dossier.pk}")
    end
  end

  class DossierAssignHandler < ScreenHandler
    def post
      dossier = dossier!
      manager = User.filter(id: field("manager_id").to_i64? || 0_i64).first
      raise Access::Denied.new("assign") if manager.nil?
      done = field("command") == "remove" ? Directory.unassign(user, manager, dossier) : Directory.assign(user, manager, dossier)
      raise Access::Denied.new("assign") unless done
      flash["success"] = I18n.t("admin.saved")
      go("/dossiers/#{dossier.pk}")
    end
  end

  class BackupTestHandler < ScreenHandler
    def post
      backup = Backup.filter(id: id_param).first
      raise Access::Denied.new("backup") if backup.nil? || !Access.in_scope?(user, backup.dossier!)
      outcome = Fleet.test_restore(user, backup, field("data_key"))
      flash[outcome.ok? ? "success" : "danger"] = outcome.ok? ? I18n.t("admin.tasks.enqueued") : outcome.errors.values.flatten.map { |key| I18n.t(key) }.join(" ")
      go("/dossiers/#{backup.dossier_id}")
    end
  end
end

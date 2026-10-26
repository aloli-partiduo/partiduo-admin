# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAdmin
  # Actions de la première version (ADR-008 D5) : chaque action vérifie les
  # droits (`Access`) et l'état du dossier, enregistre une tâche, trace dans
  # le journal d'audit. Les erreurs sont des clés i18n par champ.
  module Fleet
    alias Errors = Hash(String, Array(String))

    # Issue d'une action : erreurs par champ (clés i18n) ou objet produit.
    class Outcome(T)
      getter value : T?
      getter errors : Errors
      # Code de création du compte connect d'une invitation (ADR-012 D6), à
      # montrer une fois à qui invite.
      property signup_code : String? = nil

      def initialize(@value : T? = nil, @errors : Errors = Errors.new)
      end

      def ok? : Bool
        errors.empty?
      end

      def value! : T
        @value || raise NilAssertionError.new("action refusée : #{errors}")
      end

      def self.failure(field : String, key : String) : Outcome(T)
        new(nil, {field => [key]})
      end
    end

    record DossierInput,
      slug : String, label : String, regime : String, locale : String = "fr",
      siren : String = "", vat_number : String = "",
      modules : Array(String) = ["accounting", "invoicing"], extensions : Array(String) = [] of String,
      admin_email : String = "", server_id : Int64? = nil, firm_id : Int64? = nil, payer_id : Int64? = nil,
      package : String = "app", backup_schedule : String = "daily", backup_retention_days : Int32 = 30,
      kind : String = "company", extra_admins : Array(String) = [] of String

    EMAIL = /\A[^@\s'"]+@[^@\s'"]+\.[^@\s'"]+\z/

    def self.any(value) : JSON::Any
      Tasks.any(value)
    end

    # --- Création -----------------------------------------------------------

    # Contrôles d'une création, sans rien créer : ceux du formulaire, de
    # chaque étape d'un assistant et de sa validation finale (D-ADM-018).
    def self.dossier_errors(user : User, input : DossierInput, now : Time = Config.now) : Errors
      errors = identity_errors(input, input.slug.strip.downcase)
      administrator_errors(input, errors)
      references(user, input, now, errors)
      errors
    end

    # Autres administrateurs à inviter (D-ADM-017) : adresses valides,
    # distinctes entre elles et du premier, dans la limite de la liste.
    private def self.administrator_errors(input : DossierInput, errors : Errors) : Nil
      seen = Set{input.admin_email.strip.downcase}
      keys = input.extra_admins.compact_map do |email|
        address = email.strip.downcase
        if !EMAIL.matches?(address)
          "admin.errors.email"
        elsif !seen.add?(address)
          "admin.errors.administrators.duplicate"
        end
      end
      keys << "admin.errors.administrators.too_many" if input.extra_admins.size >= Administrators::LIMIT
      keys.uniq.each { |key| add(errors, "extra_admins", key) }
    end

    def self.create_dossier(user : User, input : DossierInput, now : Time = Config.now) : Outcome(Dossier)
      slug = input.slug.strip.downcase
      errors = dossier_errors(user, input, now)
      server, firm, payer = references(user, input, now, Errors.new)
      return Outcome(Dossier).new(nil, errors) unless errors.empty? && server && firm && payer

      # Un foyer n'a ni SIREN ni numéro de TVA : ils ne sont pas retenus.
      household = input.kind == "household"
      dossier = Dossier.create!(
        slug: slug, label: input.label.strip, regime: input.regime, locale: input.locale, kind: input.kind,
        siren: household ? "" : input.siren, vat_number: household ? "" : input.vat_number.strip.upcase,
        modules: input.modules.uniq.join(','), extensions: input.extensions.uniq.join(','),
        admin_email: input.admin_email.strip.downcase, server: server, firm: firm, payer: payer,
        package: input.package, state: "creating", backup_schedule: input.backup_schedule,
        backup_retention_days: input.backup_retention_days,
      )
      # Premier administrateur, puis les autres : invités après la création
      # de l'instance (D-ADM-017).
      Administrators.declare(dossier, [dossier.admin_email.to_s] + input.extra_admins)
      # Le nom d'abord (ADR-013 D5) : l'exécutant attend qu'il désigne son
      # serveur avant le certificat ; un échec est repris par la
      # planification.
      Dns.request(dossier, user, now)
      params = Tasks.dossier_params(dossier)
      {"name" => dossier.label, "regime" => dossier.regime, "locale" => dossier.locale, "siren" => dossier.siren,
       "vat" => dossier.vat_number, "admin_email" => dossier.admin_email, "kind" => dossier.kind}.each { |key, value| params[key] = any(value.to_s) }
      Tasks.enqueue("instance.create", server, params, user, dossier)
      Audit.log(user, "dossier.create", target: dossier,
        detail: {"modules" => dossier.modules.to_s, "extensions" => dossier.extensions.to_s, "payer" => payer.name.to_s,
                 "kind" => dossier.kind.to_s, "administrators" => (input.extra_admins.size + 1).to_s})
      Outcome(Dossier).new(dossier)
    end

    # Accumule une clé d'erreur sur un champ.
    private def self.add(errors : Errors, field : String, key : String) : Nil
      (errors[field] ||= [] of String) << key
    end

    # Contrôles de la saisie elle-même.
    private def self.identity_errors(input : DossierInput, slug : String) : Errors
      errors = Errors.new
      if !Protocol.valid_slug?(slug)
        add(errors, "slug", "admin.errors.dossier.slug")
      elsif Dossier.filter(slug: slug).exists?
        add(errors, "slug", "admin.errors.dossier.slug_taken")
      end
      add(errors, "label", "admin.errors.required") if input.label.strip.empty?
      add(errors, "regime", "admin.errors.dossier.regime") unless Catalog::REGIMES.includes?(input.regime)
      kind_errors(input, errors)
      add(errors, "locale", "admin.errors.dossier.locale") unless Config::LOCALES.includes?(input.locale)
      add(errors, "siren", "admin.errors.siren") unless input.siren.empty? || Siren.valid?(input.siren)
      add(errors, "modules", "admin.errors.dossier.modules") unless valid_modules?(input.modules)
      add(errors, "extensions", "admin.errors.dossier.extensions") unless valid_extensions?(input.extensions)
      add(errors, "admin_email", "admin.errors.email") unless EMAIL.matches?(input.admin_email.strip)
      schedule_errors(input, errors)
      errors
    end

    # Type de dossier déclaré, puis règles des pièces choisies pour ce type
    # (`Catalog`, D-ADM-016 : exclusions et pièces requises du type,
    # dépendances, incompatibilités) : le cœur refuserait le
    # provisionnement, mieux vaut le dire au formulaire.
    private def self.kind_errors(input : DossierInput, errors : Errors) : Nil
      if !Protocol.valid_dossier_kind?(input.kind)
        add(errors, "kind", "admin.errors.dossier.kind")
      elsif valid_modules?(input.modules)
        piece_errors(input.kind, input.regime, input.modules + input.extensions, errors)
      end
    end

    # Régime invalide (déjà refusé) : ses restrictions ne sont pas jugées.
    private def self.piece_errors(kind : String, regime : String, codes : Array(String), errors : Errors) : Nil
      valid = Catalog::REGIMES.includes?(regime) ? regime : nil
      Catalog.errors(kind, valid, codes).each { |field, keys| keys.each { |key| add(errors, field, key) } }
    end

    private def self.schedule_errors(input : DossierInput, errors : Errors) : Nil
      # Paquet : celui de cette administration (Config.dossier_package), jamais
      # une valeur libre (il désigne le paquet FreeBSD qui servira l'instance).
      if !Protocol.valid_package?(input.package)
        add(errors, "package", "admin.errors.dossier.package")
      elsif input.package != Config.dossier_package
        add(errors, "package", "admin.errors.dossier.package_build")
      end
      add(errors, "backup_schedule", "admin.errors.invalid") unless Dossier::SCHEDULES.includes?(input.backup_schedule)
      add(errors, "backup_retention_days", "admin.errors.dossier.retention") unless (1..3650).includes?(input.backup_retention_days)
    end

    def self.valid_modules?(modules : Array(String)) : Bool
      !modules.empty? && modules.all? { |code| Protocol::MODULES.includes?(code) }
    end

    def self.valid_extensions?(extensions : Array(String)) : Bool
      extensions.all? { |code| Protocol::CODE.matches?(code) }
    end

    # Serveur, cabinet et donneur d'ordre désignés, droits et quota.
    private def self.references(user : User, input : DossierInput, now : Time, errors : Errors) : {Server?, Firm?, Payer?}
      server = input.server_id.try { |id| Server.filter(id: id, active: true).first }
      firm = input.firm_id.try { |id| Firm.filter(id: id, active: true).first }
      payer = input.payer_id.try { |id| Payer.filter(id: id).first }
      add(errors, "server_id", "admin.errors.required") if server.nil?
      add(errors, "firm_id", "admin.errors.required") if firm.nil?
      add(errors, "payer_id", "admin.errors.dossier.payer_required") if payer.nil?
      if firm
        add(errors, "payer_id", "admin.errors.dossier.payer_scope") if payer && payer.firm_id != firm.pk && !user.super_admin?
        add(errors, "firm_id", "admin.errors.forbidden") unless Access.can_create_dossier?(user, firm.pk)
      end
      add(errors, "base", "admin.errors.dossier.quota") if server && LetsEncrypt.quota_reached?(server.domain.to_s, now)
      {server, firm, payer}
    end

    # --- Modules et extensions (ADR-006 D2) --------------------------------

    def self.change_modules(user : User, dossier : Dossier, modules : Array(String), extensions : Array(String)) : Outcome(Task)
      return Outcome(Task).failure("base", "admin.errors.forbidden") unless Access.can?(user, :modules, dossier)
      return Outcome(Task).failure("base", "admin.errors.dossier.not_active") unless dossier.state == "active"
      return Outcome(Task).failure("modules", "admin.errors.dossier.modules") unless valid_modules?(modules)
      return Outcome(Task).failure("extensions", "admin.errors.dossier.extensions") unless valid_extensions?(extensions)
      errors = Errors.new
      piece_errors(dossier.kind.presence || "company", dossier.regime.to_s, modules + extensions, errors)
      return Outcome(Task).new(nil, errors) unless errors.empty?
      # Extensions retirées avant les modules (une extension requiert un
      # module, jamais l'inverse), modules ajoutés avant les extensions ;
      # l'exécutant affine l'ordre selon les dépendances que rend l'instance
      # (D-AFN-006). Les données d'une pièce désactivée sont conservées.
      disable = (dossier.extension_list - extensions) + (dossier.module_list - modules)
      enable = (modules - dossier.module_list) + (extensions - dossier.extension_list)
      return Outcome(Task).failure("base", "admin.errors.dossier.no_change") if enable.empty? && disable.empty?
      params = Tasks.dossier_params(dossier)
      params["enable"] = any(enable)
      params["disable"] = any(disable)
      params["target_modules"] = any(modules)
      params["target_extensions"] = any(extensions)
      task = Tasks.enqueue("instance.modules", dossier.server!, params, user, dossier)
      Audit.log(user, "dossier.modules", target: dossier, detail: {"enable" => enable.join(','), "disable" => disable.join(',')})
      Outcome(Task).new(task)
    end

    # --- Cycle de vie -------------------------------------------------------

    TRANSITIONS = {
      "suspend"         => {"instance.suspend", "active"},
      "resume"          => {"instance.resume", "suspended"},
      "archive"         => {"instance.archive", "active|suspended"},
      "restore_archive" => {"instance.restore_archive", "archived"},
    }

    def self.lifecycle(user : User, dossier : Dossier, action : String, reason : String = "") : Outcome(Task)
      if refused = lifecycle_refusal(user, dossier, action)
        return Outcome(Task).failure(*refused)
      end
      kind, _ = TRANSITIONS[action]
      params = Tasks.dossier_params(dossier)
      params["reason"] = any(reason.presence || action)
      if action == "archive"
        # Archive chiffrée selon le réglage du dossier (D-CHF-001).
        settings = BackupEncryption.task_settings(dossier) || return Outcome(Task).failure("base", "admin.errors.encryption.no_key")
        params["encryption"] = settings
      end
      task = Tasks.enqueue(kind, dossier.server!, params, user, dossier)
      Audit.log(user, "dossier.#{action}", target: dossier, detail: {"reason" => reason})
      Outcome(Task).new(task)
    end

    # Premier refus d'une action du cycle de vie (champ, clé), sans rien
    # enregistrer : celui du formulaire et des étapes d'un assistant
    # (D-ADM-022). Archive : clé du cabinet exigée par son chiffrement.
    def self.lifecycle_refusal(user : User, dossier : Dossier, action : String) : {String, String}?
      _, from = TRANSITIONS[action]? || return {"base", "admin.errors.invalid"}
      return {"base", "admin.errors.forbidden"} unless Access.can?(user, action_symbol(action), dossier)
      return {"base", "admin.errors.dossier.state"} unless from.split('|').includes?(dossier.state)
      return {"base", "admin.errors.encryption.no_key"} if action == "archive" && BackupEncryption.task_settings(dossier).nil?
      nil
    end

    private def self.action_symbol(action : String) : Symbol
      case action
      when "suspend"         then :suspend
      when "resume"          then :resume
      when "archive"         then :archive
      when "restore_archive" then :restore_archive
      else                        :none
      end
    end

    # --- Sauvegardes (ADR-008 D5) -------------------------------------------

    def self.backup_now(user : User?, dossier : Dossier, kind : String = "manual") : Outcome(Task)
      if user && !Access.can?(user, :backup, dossier)
        return Outcome(Task).failure("base", "admin.errors.forbidden")
      end
      return Outcome(Task).failure("base", "admin.errors.dossier.state") unless %w[active suspended].includes?(dossier.state)
      settings = BackupEncryption.task_settings(dossier) || return Outcome(Task).failure("base", "admin.errors.encryption.no_key")
      params = Tasks.dossier_params(dossier)
      params["kind"] = any(kind)
      params["encryption"] = settings
      task = Tasks.enqueue("backup.run", dossier.server!, params, user, dossier)
      Audit.log(user, "backup.request", target: dossier, detail: {"kind" => kind, "encryption" => dossier.effective_encryption},
        actor_label: user ? nil : "system")
      Outcome(Task).new(task)
    end

    # Paramètres de lecture d'une sauvegarde : emplacements dans le stockage,
    # empreintes, mode et destinataire de sa clé (D-CHF-016).
    private def self.source_params(params : Tasks::Params, backup : Backup) : Nil
      params["backup_id"] = any(backup.pk!.as(Int64))
      params["path"] = any(backup.path)
      params["media_path"] = any(backup.media_path)
      params["sha256"] = any(backup.sha256)
      params["media_sha256"] = any(backup.media_sha256) unless backup.media_sha256.to_s.empty?
      params["backup_encryption"] = BackupEncryption.source(backup) unless backup.encryption_mode == "none"
      # Clés de signature du serveur qui l'a prise : le manifeste est
      # authentifié avant toute lecture (D-CHF-018).
      params["signers"] = any(BackupEncryption.signers(backup))
    end

    # Restauration test. Sauvegarde chiffrée : sans `data_key`, l'exécutant
    # ne vérifie que la signature, les empreintes et la structure ; avec la
    # clé de la sauvegarde (capsule ouverte par la clé d'exploitation ou
    # dans le navigateur de l'admin du cabinet), il la relit en entier
    # (D-CHF-017).
    def self.test_restore(user : User?, backup : Backup, data_key : String = "") : Outcome(Task)
      dossier = backup.dossier!
      if user && !Access.can?(user, :test_restore, dossier)
        return Outcome(Task).failure("base", "admin.errors.forbidden")
      end
      return Outcome(Task).failure("base", "admin.errors.backup.unusable") unless %w[done verified].includes?(backup.state)
      keys = nil
      unless data_key.empty?
        accepted = BackupEncryption.accept_data_key(backup, data_key) || return Outcome(Task).failure("data_key", "admin.errors.encryption.wrong_key")
        keys = [accepted]
      end
      params = Tasks.dossier_params(dossier)
      source_params(params, backup)
      params["key_provided"] = any(true) if keys
      task = Tasks.enqueue("backup.test_restore", dossier.server!, params, user, dossier, data_keys: keys)
      Audit.log(user, "backup.test_restore", target: dossier,
        detail: {"backup" => backup.pk.to_s, "encryption" => backup.encryption_mode.to_s, "key_provided" => (!keys.nil?).to_s},
        actor_label: user ? nil : "system")
      Outcome(Task).new(task)
    end

    # Sauvegarde qu'une restauration à cette date reprendrait (dernière prise
    # ce jour-là ou avant).
    def self.backup_for(dossier : Dossier, date : Time) : Backup?
      Backup.filter(dossier_id: dossier.pk, state__in: %w[done verified], taken_at__lte: date.at_end_of_day)
        .order("-taken_at").first
    end

    # Restauration à une date : la dernière sauvegarde prise à cette date ou
    # avant, dans une instance neuve (`new`, sous-domaine `new_slug`) ou en
    # remplacement (`replace`, après une sauvegarde de sûreté), ou sur le
    # nouveau serveur d'un dossier déplacé (`move`, ADR-013 D7).
    #
    # Sauvegarde chiffrée (D-CHF-005, D-CHF-016) : `data_key` est sa clé de
    # sauvegarde, sortie de la capsule sur le poste de l'exploitant ou dans
    # le navigateur de l'admin du cabinet ; elle est contrôlée ici
    # (destinataire), remise une seule fois à l'exécutant, jamais conservée
    # ni journalisée. `backup_id` fixe la sauvegarde dont la clé a été
    # fournie.
    def self.restore(user : User, dossier : Dossier, date : Time, target : String, new_slug : String = "",
                     backup_id : Int64? = nil, data_key : String = "") : Outcome(Task)
      if refused = restore_refusal(user, dossier, target)
        return Outcome(Task).failure(*refused)
      end
      backup = restored_backup(dossier, date, backup_id)
      return Outcome(Task).failure("date", "admin.errors.backup.none_before") if backup.nil?
      keys, refusal = restore_keys(backup, data_key)
      return Outcome(Task).failure("data_key", refusal) if refusal
      params = Tasks.dossier_params(dossier)
      source_params(params, backup)
      params["key_provided"] = any(true) if keys
      params["target"] = any(target)
      if target == "replace"
        # Sauvegarde de sûreté, chiffrée selon le réglage actuel.
        params["encryption"] = BackupEncryption.task_settings(dossier) || return Outcome(Task).failure("base", "admin.errors.encryption.no_key")
      end
      if target == "new"
        field, refusal = restore_copy(user, dossier, backup, new_slug, params)
        return Outcome(Task).failure(field, refusal) if refusal
      end
      task = Tasks.enqueue("backup.restore", dossier.server!, params, user, dossier, data_keys: keys)
      Audit.log(user, "backup.restore", target: dossier,
        detail: {"backup" => backup.pk.to_s, "target" => target, "new_slug" => new_slug, "date" => date.to_s("%F"),
                 "encryption" => backup.encryption_mode.to_s, "key_provided" => (!keys.nil?).to_s})
      Outcome(Task).new(task)
    end

    # Refus d'une restauration (champ, clé), avant de chercher la sauvegarde.
    def self.restore_refusal(user : User, dossier : Dossier, target : String) : {String, String}?
      return {"base", "admin.errors.forbidden"} unless Access.can?(user, :restore, dossier)
      return {"target", "admin.errors.invalid"} unless %w[move new replace].includes?(target)
      return {"base", "admin.errors.dossier.state"} unless %w[active suspended].includes?(dossier.state)
      # Déplacement (ADR-013 D7) : instance installée sur le serveur du
      # dossier, qui ne l'a pas encore ; dossier suspendu, super-admin.
      if target == "move"
        return {"base", "admin.errors.forbidden"} unless user.super_admin?
        return {"base", "admin.errors.dossier.state"} unless dossier.state == "suspended"
      end
    end

    # --- Déplacement (ADR-013 D7) : manuel, au cas par cas ------------------

    # Un super-admin rattache un dossier suspendu à un autre serveur actif ;
    # son nom bascule vers ce serveur. Viennent ensuite, par la procédure
    # de la fiche d'exploitation, la restauration « déplacement » sur le
    # nouveau serveur (instance et certificat), la reprise du dossier et le
    # retrait de l'ancienne instance.
    def self.move(user : User, dossier : Dossier, server_id : Int64?, reason : String,
                  now : Time = Config.now) : Outcome(Dossier)
      refused = move_dossier_refusal(user, dossier) || move_server_refusal(dossier, server_id) ||
                move_reason_refusal(reason) || move_busy_refusal(dossier)
      return Outcome(Dossier).failure(*refused) if refused
      target = Server.get!(id: server_id)
      origin = dossier.server!
      dossier.server = target
      dossier.save!
      Audit.log(user, "dossier.move", target: dossier,
        detail: {"from" => origin.name.to_s, "to" => target.name.to_s, "reason" => reason.strip})
      Dns.request(dossier, user, now)
      Outcome(Dossier).new(dossier)
    end

    # Refus d'un déplacement, par partie (le service et chaque étape de
    # l'assistant, D-ADM-022) : super-admin et dossier suspendu ; serveur
    # actif autre que le sien ; aucune tâche en cours sur le dossier.
    def self.move_dossier_refusal(user : User, dossier : Dossier) : {String, String}?
      return {"base", "admin.errors.forbidden"} unless user.super_admin?
      return {"base", "admin.errors.dossier.state"} unless dossier.state == "suspended"
      nil
    end

    def self.move_server_refusal(dossier : Dossier, server_id : Int64?) : {String, String}?
      target = server_id.try { |id| Server.filter(id: id, active: true).first }
      return {"server_id", "admin.errors.dossier.move_server"} if target.nil? || target.pk == dossier.server_id
      nil
    end

    def self.move_reason_refusal(reason : String) : {String, String}?
      reason.strip.size < 5 ? {"reason", "admin.errors.required"} : nil
    end

    def self.move_busy_refusal(dossier : Dossier) : {String, String}?
      return {"base", "admin.errors.dossier.busy"} if Task.filter(dossier_id: dossier.pk, state__in: %w[pending running]).exists?
      nil
    end

    # Instance neuve d'une restauration : dossier créé (état `creating`),
    # sous-domaine et hôte dans les paramètres ; ou champ et motif du refus.
    private def self.restore_copy(user : User, dossier : Dossier, backup : Backup, new_slug : String,
                                  params : Tasks::Params) : {String, String?}
      if refused = restore_copy_refusal(dossier, new_slug)
        return {refused[0], refused[1].as(String?)}
      end
      slug = new_slug.strip.downcase
      copy = Dossier.create!(slug: slug, label: dossier.label, regime: dossier.regime, locale: dossier.locale, kind: dossier.kind,
        siren: dossier.siren, vat_number: dossier.vat_number, modules: dossier.modules, extensions: dossier.extensions,
        admin_email: dossier.admin_email, server: dossier.server!, firm: dossier.firm!, payer: dossier.payer!,
        package: dossier.package, version: backup.version.presence || dossier.version, state: "creating",
        backup_encryption: dossier.backup_encryption.to_s)
      # Administrateurs de la sauvegarde : ceux du dossier, en attente de
      # l'installation de la copie (D-ADM-017).
      Administrators.declare(copy, Administrators.emails(dossier))
      # Nom de l'instance neuve, avant son certificat (ADR-013 D5).
      Dns.request(copy, user)
      params["new_slug"] = any(slug)
      params["new_host"] = any(copy.host)
      {"", nil}
    end

    # Refus d'une instance neuve (champ, clé) : sous-domaine valide et
    # libre, quota de certificats du domaine.
    def self.restore_copy_refusal(dossier : Dossier, new_slug : String) : {String, String}?
      slug = new_slug.strip.downcase
      return {"new_slug", "admin.errors.dossier.slug"} unless Protocol.valid_slug?(slug)
      return {"new_slug", "admin.errors.dossier.slug_taken"} if Dossier.filter(slug: slug).exists?
      # Instance neuve : un certificat de plus, compté comme à la création.
      return {"base", "admin.errors.dossier.quota"} if LetsEncrypt.quota_reached?(dossier.server!.domain.to_s, Config.now)
      nil
    end

    # Sauvegarde que reprend une restauration : celle désignée
    # (`backup_id`), sinon la dernière prise à la date.
    def self.restored_backup(dossier : Dossier, date : Time, backup_id : Int64?) : Backup?
      return backup_for(dossier, date) if backup_id.nil?
      Backup.filter(id: backup_id, dossier_id: dossier.pk, state__in: %w[done verified]).first
    end

    # Clé de sauvegarde à remettre (sauvegarde chiffrée) ou motif du refus :
    # absente ou fausse.
    private def self.restore_keys(backup : Backup, data_key : String) : {Array(String)?, String?}
      return {nil, nil} unless backup.sealed
      return {nil, "admin.errors.encryption.key_required"} if data_key.empty?
      accepted = BackupEncryption.accept_data_key(backup, data_key)
      accepted ? {[accepted], nil} : {nil, "admin.errors.encryption.wrong_key"}
    end
  end

  # SIREN : neuf chiffres, clé de Luhn.
  module Siren
    def self.valid?(value : String) : Bool
      return false unless value.matches?(/\A\d{9}\z/)
      sum = value.chars.reverse!.each_with_index.sum do |char, index|
        digit = char.to_i
        digit *= 2 if index.odd?
        digit > 9 ? digit - 9 : digit
      end
      sum % 10 == 0
    end
  end
end

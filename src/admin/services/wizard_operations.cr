# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Assistants des opérations du parc (D-ADM-022) : ajouter un serveur,
  # restaurer, déplacer, archiver un dossier, inviter un utilisateur. Mêmes
  # principes que les assistants de création (D-ADM-018) : chaque étape est
  # jugée par les contrôles des services des formulaires, appelés sans rien
  # enregistrer (`Directory.server_refusal`, `Fleet.restore_refusal`,
  # `Fleet.restore_copy_refusal`, `Fleet.move_*_refusal`,
  # `Fleet.lifecycle_refusal`, `Directory.invite_errors`,
  # `Directory.assignable?`) ; la validation appelle les services des
  # formulaires (`Directory.create_server`, `Fleet.restore`, `Fleet.move`,
  # `Fleet.lifecycle`, `Directory.invite_user`, `Directory.assign`), qui
  # enregistrent les mêmes tâches de l'exécutant.
  module Wizards
    # Rôle proposé d'abord à l'invitation (les autres : ceux que
    # l'utilisateur peut attribuer).
    DEFAULT_ROLE = Config::FILE_MANAGER

    # Étape d'un champ propre à ces parcours ; `nil` : règle commune.
    def self.operation_step_of(kind : String, field : String) : String?
      case {kind, field}
      when {"server", "connection"} then "check"
      when {"restore", "data_key"}  then "key"
      when {"restore", "date"}      then "backup"
      when {_, "confirm"}           then "summary"
      end
    end

    # Erreurs de la saisie entière d'un parcours d'opération.
    def self.operation_errors(user : User, draft : WizardDraft) : Errors
      case draft.kind!
      when "server"  then server_errors(user, draft)
      when "restore" then restore_errors(user, draft)
      when "move"    then move_errors(user, draft)
      when "archive" then archive_errors(user, draft)
      else                user_errors(user, draft)
      end
    end

    # Brouillon d'un parcours sur un dossier, ouvert depuis sa fiche
    # (`?dossier=`) : le dossier est retenu, l'assistant passe à l'étape
    # suivante si le dossier convient. Les saisies qui dépendaient d'un
    # autre dossier sont oubliées.
    def self.preselect(user : User, draft : WizardDraft, dossier_id : Int64) : Nil
      return unless %w[restore move archive].includes?(draft.kind!)
      return if draft.text("dossier_id") == dossier_id.to_s && !draft.new_record?
      draft.data = {"dossier_id" => dossier_id.to_s}.to_json
      draft.step = 1
      draft.reached = 1
      draft.save!
      return unless errors_until(user, draft, "dossier").empty?
      draft.step = 2
      draft.reached = 2
      draft.save!
    end

    # Dossier choisi a changé : les étapes suivantes sont à refaire.
    def self.dossier_changed(draft : WizardDraft, before : String) : Nil
      return if before.empty? || before == draft.text("dossier_id")
      data = draft.values.select { |key, _| key == "dossier_id" || key == "reason" }
      draft.data = data.to_json
      draft.reached = 1
      draft.save!
    end

    # Opération confirmée explicitement (case « J'ai pris connaissance des
    # conséquences ») : exigée à la validation d'une restauration, d'un
    # déplacement, d'un archivage.
    private def self.confirm_errors(confirmed : Bool) : Errors
      confirmed ? Errors.new : Errors{"confirm" => ["admin.wizards.errors.confirm"]}
    end

    private def self.refused(errors : Errors, field : String, refusal : {String, String}?) : Nil
      add(errors, field, refusal[1]) if refusal
    end

    # --- Serveur ----------------------------------------------------------------------

    def self.created_server(draft : WizardDraft) : Server?
      draft.text("server_id").to_i64?.try { |id| Server.filter(id: id).first }
    end

    # Étapes déjà franchies sans retour possible : l'identité et le
    # récapitulatif d'un serveur déclaré.
    def self.locked(draft : WizardDraft) : Int32
      draft.kind! == "server" && created_server(draft) ? 2 : 0
    end

    # L'exécutant s'est présenté avec le jeton du serveur.
    def self.connected?(server : Server) : Bool
      !server.last_seen_at.nil?
    end

    private def self.server_errors(user : User, draft : WizardDraft) : Errors
      errors = Errors.new
      if server = created_server(draft)
        add(errors, "connection", "admin.wizards.server.errors.not_connected") unless connected?(server)
        return errors
      end
      refusal = Directory.server_refusal(user, draft.text("name"), draft.text("hostname"), server_domain(draft))
      refusal.try { |field, key| add(errors, field, key) }
      errors
    end

    def self.server_domain(draft : WizardDraft) : String
      draft.text("domain").presence || Config.domain
    end

    # Déclaration : le serveur et son jeton, montré une seule fois à
    # l'étape du raccordement.
    def self.finish_server(user : User, draft : WizardDraft) : {Errors, Server?, String?}
      errors = server_errors(user, draft)
      return {errors, nil, nil} unless errors.empty?
      outcome = Directory.create_server(user, draft.text("name"), draft.text("hostname"), server_domain(draft))
      return {outcome.errors, nil, nil} unless outcome.ok?
      server, token = outcome.value!
      store(draft, {"server_id" => server.pk.to_s})
      draft.step = 3
      draft.reached = 3
      draft.save!
      Audit.log(user, "wizard.finish", target: server, detail: {"wizard" => "server"})
      {Errors.new, server, token}
    end

    # --- Restauration -----------------------------------------------------------------

    def self.restore_dossier_of(draft : WizardDraft) : Dossier?
      draft.text("dossier_id").to_i64?.try { |id| Dossier.filter(id: id).first }
    end

    def self.chosen_dossier(user : User, draft : WizardDraft) : Dossier?
      draft.text("dossier_id").to_i64?.try { |id| Access.dossiers(user).filter(id: id).first }
    end

    def self.restore_backup(draft : WizardDraft, dossier : Dossier) : Backup?
      id = draft.text("backup_id").to_i64? || return
      Fleet.restored_backup(dossier, Config.now, id)
    end

    def self.restore_target(draft : WizardDraft) : String
      draft.text("target").presence || "new"
    end

    # Cibles proposées : instance neuve, remplacement de l'instance, et pour
    # un dossier suspendu que le super-admin déplace, l'instance du nouveau
    # serveur (ADR-013 D7).
    def self.restore_targets(user : User, dossier : Dossier?) : Array(String)
      targets = %w[new replace]
      targets << "move" if dossier && Fleet.restore_refusal(user, dossier, "move").nil?
      targets
    end

    private def self.restore_errors(user : User, draft : WizardDraft) : Errors
      errors = Errors.new
      dossier = chosen_dossier(user, draft)
      if dossier.nil?
        add(errors, "dossier_id", "admin.errors.required")
        return errors
      end
      general = Fleet.restore_refusal(user, dossier, "new")
      refused(errors, "dossier_id", general)
      add(errors, "backup_id", "admin.wizards.restore.errors.backup") if restore_backup(draft, dossier).nil?
      target = restore_target(draft)
      specific = Fleet.restore_refusal(user, dossier, target)
      refused(errors, "target", specific) unless specific == general
      if target == "new"
        copy = Fleet.restore_copy_refusal(dossier, draft.text("new_slug"))
        refused(errors, copy.try(&.[0]) == "new_slug" ? "new_slug" : "target", copy)
      end
      errors
    end

    # Restauration : la tâche `backup.restore` du formulaire ; la clé d'une
    # sauvegarde chiffrée accompagne la seule requête de validation, jamais
    # le brouillon.
    def self.finish_restore(user : User, draft : WizardDraft, data_key : String, confirmed : Bool) : {Errors, Task?}
      errors = restore_errors(user, draft).merge(confirm_errors(confirmed))
      return {errors, nil} unless errors.empty?
      dossier = chosen_dossier(user, draft) || return {Errors{"dossier_id" => ["admin.errors.required"]}, nil}
      backup = restore_backup(draft, dossier) || return {Errors{"backup_id" => ["admin.wizards.restore.errors.backup"]}, nil}
      outcome = Fleet.restore(user, dossier, backup.taken_at || Config.now, restore_target(draft), draft.text("new_slug"),
        PartiduoAdmin.id?(backup.pk), data_key)
      return {outcome.errors, nil} unless outcome.ok?
      Audit.log(user, "wizard.finish", target: dossier, detail: {"wizard" => "restore", "target" => restore_target(draft)})
      discard(draft)
      {Errors.new, outcome.value!}
    end

    # Contrôle de signature tel que l'administration le voit : clé qui a
    # signé le manifeste, clés déclarées du serveur d'origine (l'exécutant
    # vérifie la signature avant toute lecture, D-CHF-018).
    def self.signature_state(backup : Backup) : String
      return "unsigned" if backup.manifest_signature.to_s.empty? || backup.signing_key.to_s.empty?
      keys = Server.filter(name: backup.origin.to_s).first.try(&.signing_keys) || [] of SigningKey
      return "no_server_key" if keys.empty?
      key = keys.find { |item| item.fingerprint == backup.signing_key } || return "unknown_key"
      revoked = key.revoked_at
      taken = backup.taken_at
      return "revoked" if revoked && taken && revoked <= taken
      "known_key"
    end

    # --- Déplacement ------------------------------------------------------------------

    private def self.move_errors(user : User, draft : WizardDraft) : Errors
      errors = Errors.new
      dossier = chosen_dossier(user, draft)
      if dossier.nil?
        add(errors, "dossier_id", "admin.errors.required")
        return errors
      end
      refused(errors, "dossier_id", Fleet.move_dossier_refusal(user, dossier) || Fleet.move_busy_refusal(dossier))
      refused(errors, "server_id", Fleet.move_server_refusal(dossier, draft.text("server_id").to_i64?))
      refused(errors, "reason", Fleet.move_reason_refusal(draft.text("reason")))
      errors
    end

    # Bascule (ADR-013 D7) : le service du formulaire ; la restauration sur
    # le nouveau serveur suit, par l'assistant de restauration préparé pour
    # ce dossier (cible « déplacement »).
    def self.finish_move(user : User, draft : WizardDraft, confirmed : Bool) : {Errors, Dossier?}
      errors = move_errors(user, draft).merge(confirm_errors(confirmed))
      return {errors, nil} unless errors.empty?
      dossier = chosen_dossier(user, draft) || return {Errors{"dossier_id" => ["admin.errors.required"]}, nil}
      outcome = Fleet.move(user, dossier, draft.text("server_id").to_i64?, draft.text("reason"))
      return {outcome.errors, nil} unless outcome.ok?
      Audit.log(user, "wizard.finish", target: dossier, detail: {"wizard" => "move"})
      discard(draft)
      following = Wizards.draft(user, "restore")
      following.data = {"dossier_id" => dossier.pk.to_s, "target" => "move"}.to_json
      following.step = 2
      following.reached = 2
      following.save!
      {Errors.new, dossier}
    end

    # --- Archivage --------------------------------------------------------------------

    private def self.archive_errors(user : User, draft : WizardDraft) : Errors
      errors = Errors.new
      dossier = chosen_dossier(user, draft)
      if dossier.nil?
        add(errors, "dossier_id", "admin.errors.required")
        return errors
      end
      refused(errors, "dossier_id", Fleet.lifecycle_refusal(user, dossier, "archive"))
      # Motif exigé comme au formulaire de la fiche (champ requis).
      add(errors, "reason", "admin.errors.required") if draft.text("reason").empty?
      errors
    end

    def self.finish_archive(user : User, draft : WizardDraft, confirmed : Bool) : {Errors, Task?}
      errors = archive_errors(user, draft).merge(confirm_errors(confirmed))
      return {errors, nil} unless errors.empty?
      dossier = chosen_dossier(user, draft) || return {Errors{"dossier_id" => ["admin.errors.required"]}, nil}
      outcome = Fleet.lifecycle(user, dossier, "archive", draft.text("reason"))
      return {outcome.errors, nil} unless outcome.ok?
      Audit.log(user, "wizard.finish", target: dossier, detail: {"wizard" => "archive"})
      discard(draft)
      {Errors.new, outcome.value!}
    end

    # --- Invitation d'un utilisateur --------------------------------------------------

    def self.user_role(draft : WizardDraft) : String
      draft.text("role").presence || DEFAULT_ROLE
    end

    def self.user_input(user : User, draft : WizardDraft) : Directory::UserInput
      Directory::UserInput.new(email: draft.text("email"), first_name: draft.text("first_name"),
        last_name: draft.text("last_name"), role: user_role(draft),
        firm_id: user.firm_admin? ? PartiduoAdmin.id?(user.firm_id) : draft.text("firm_id").to_i64?,
        locale: draft.text("locale").presence || I18n.locale)
    end

    # Dossiers que l'invité recevra : seulement pour un gestionnaire de
    # dossiers (les admins voient tous ceux de leur structure).
    def self.user_dossiers(user : User, draft : WizardDraft) : Array(Dossier)
      return [] of Dossier unless user_role(draft) == Config::FILE_MANAGER
      ids = draft.list("dossier_ids").compact_map(&.to_i64?)
      return [] of Dossier if ids.empty?
      Access.dossiers(user).filter(id__in: ids).order("slug").to_a
    end

    # Structure de l'invité, telle que l'invitation la retiendra.
    def self.user_firm_id(user : User, draft : WizardDraft) : Int64?
      Directory.invited_firm_id(user, user_input(user, draft))
    end

    private def self.user_errors(user : User, draft : WizardDraft) : Errors
      input = user_input(user, draft)
      errors = Directory.invite_errors(user, input)
      add(errors, "locale", "admin.errors.invalid") unless Config::LOCALES.includes?(input.locale)
      if input.role == Config::FILE_MANAGER
        firm_id = Directory.invited_firm_id(user, input)
        ids = draft.list("dossier_ids").compact_map(&.to_i64?)
        chosen = user_dossiers(user, draft)
        unless chosen.size == ids.uniq.size && chosen.all? { |dossier| Directory.assignable?(user, dossier, firm_id) }
          add(errors, "dossier_ids", "admin.wizards.user.errors.dossiers")
        end
      end
      errors
    end

    # Invitation, puis dossiers confiés, dans une transaction ; le code de
    # création du compte connect est rendu pour être montré une fois.
    def self.finish_user(user : User, draft : WizardDraft) : {Errors, User?, String?}
      errors = user_errors(user, draft)
      return {errors, nil, nil} unless errors.empty?
      invited : User? = nil
      code = nil
      failure = Errors.new
      Marten::DB::Connection.default.transaction do
        outcome = Directory.invite_user(user, user_input(user, draft))
        failure = outcome.errors
        raise Marten::DB::Errors::Rollback.new unless outcome.ok?
        record = outcome.value!
        user_dossiers(user, draft).each do |dossier|
          next if Directory.assign(user, record, dossier)
          failure = Errors{"dossier_ids" => ["admin.wizards.user.errors.dossiers"]}
          raise Marten::DB::Errors::Rollback.new
        end
        Audit.log(user, "wizard.finish", target: record, detail: {"wizard" => "user"})
        code = outcome.signup_code
        invited = record
      end
      return {failure.empty? ? Errors{"base" => ["admin.errors.wizards.failed"]} : failure, nil, nil} if invited.nil?
      discard(draft)
      {Errors.new, invited, code}
    end
  end
end

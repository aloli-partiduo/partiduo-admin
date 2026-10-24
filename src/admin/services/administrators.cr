# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAdmin
  # Administrateurs multiples (D-ADM-017).
  #
  # *Dossier* : les comptes au profil administrateur dans l'instance du
  # dossier. La console en garde la liste (`DossierAdmin`) ; l'exécutant les
  # ajoute et les retire (`instance.admin_add`, `instance.admin_remove`,
  # contrat d'instance 1.4.0) et relit la liste (`instance.admins`). Ajouter,
  # retirer, rétrograder ou remplacer sont des opérations sensibles : elles
  # passent par une demande (`Approvals`), confirmée seule après
  # ré-authentification ou validée par une autre personne selon le réglage
  # de la structure (D-VAL2-001). Ceux déclarés à la création du dossier
  # sont invités sans demande, comme le premier : la création est la
  # décision.
  #
  # *Cabinet* : les utilisateurs au rôle d'admin de cabinet. Ajout par
  # invitation, changement de rôle (admin ↔ gestionnaire de dossiers),
  # retrait (rôle de gestionnaire), remplacement.
  #
  # Règles communes : jamais zéro administrateur (le dernier ne se retire
  # pas), le retrait de soi-même est confirmé, chaque changement passe au
  # journal d'audit.
  module Administrators
    alias Outcome = Fleet::Outcome
    alias Errors = Fleet::Errors

    # Administrateurs d'un dossier au plus.
    LIMIT = 10

    REMOVALS = Protocol::ADMIN_REMOVALS

    # Référence des ajouts décidés à la création du dossier (pas une demande).
    CREATION_PREFIX = "CR-"

    # --- Dossier ------------------------------------------------------------

    def self.list(dossier : Dossier) : Array(DossierAdmin)
      DossierAdmin.filter(dossier_id: dossier.pk).order("created_at", "id").to_a
    end

    def self.emails(dossier : Dossier) : Array(String)
      list(dossier).map(&.email.to_s)
    end

    # Déclare des administrateurs en attente (création, copie restaurée) :
    # adresses en minuscules, doublons et vides écartés, dans l'ordre reçu.
    def self.declare(dossier : Dossier, emails : Array(String)) : Nil
      emails.map(&.strip.downcase).reject(&.empty?).uniq!.each do |email|
        next if DossierAdmin.filter(dossier_id: dossier.pk, email: email).exists?
        DossierAdmin.create!(dossier: dossier, email: email, state: "pending")
      end
    end

    # Demande d'ajout, ou de remplacement de `replaces` (retiré par
    # `replace_removal` une fois le nouveau ajouté).
    def self.request_add(user : User, dossier : Dossier, email : String, reason : String, replaces : String = "",
                         replace_removal : String = "revoke", now : Time = Config.now) : Outcome(Approval)
      if refusal = request_refusal(user, dossier)
        return Outcome(Approval).failure("base", refusal)
      end
      address = email.strip.downcase
      rows = list(dossier)
      replaced = replaces.strip.downcase
      errors = Errors.new
      add(errors, "email", "admin.errors.email") unless Fleet::EMAIL.matches?(address)
      add(errors, "email", "admin.errors.administrators.already") if rows.any?(&.email.==(address))
      add(errors, "email", "admin.errors.administrators.too_many") if replaced.empty? && rows.size >= LIMIT
      unless replaced.empty?
        add(errors, "replaces", "admin.errors.administrators.unknown") unless rows.any? { |row| row.email == replaced && row.state == "active" }
        add(errors, "replace_removal", "admin.errors.invalid") unless REMOVALS.includes?(replace_removal)
      end
      return Outcome(Approval).new(nil, errors) unless errors.empty?
      params = {"email" => address, "replaces" => replaced, "replace_removal" => replaced.empty? ? "" : replace_removal}
      Approvals.request(user, dossier, "admin_add", reason, params, now)
    end

    # Demande de retrait (`revoke`) ou de rétrogradation (`demote`). Jamais
    # le dernier administrateur actif ; soi-même, seulement confirmé.
    def self.request_remove(user : User, dossier : Dossier, email : String, removal : String, reason : String,
                            self_confirmed : Bool, now : Time = Config.now) : Outcome(Approval)
      if refusal = request_refusal(user, dossier)
        return Outcome(Approval).failure("base", refusal)
      end
      address = email.strip.downcase
      rows = list(dossier)
      unless rows.any? { |row| row.email == address && row.state == "active" }
        return Outcome(Approval).failure("email", "admin.errors.administrators.unknown")
      end
      return Outcome(Approval).failure("removal", "admin.errors.invalid") unless REMOVALS.includes?(removal)
      if rows.none? { |row| row.email != address && row.state == "active" }
        return Outcome(Approval).failure("base", "admin.errors.administrators.last")
      end
      if address == user.email.to_s.downcase && !self_confirmed
        return Outcome(Approval).failure("self_confirm", "admin.errors.administrators.self_confirm")
      end
      Approvals.request(user, dossier, "admin_remove", reason, {"email" => address, "removal" => removal}, now)
    end

    private def self.request_refusal(user : User, dossier : Dossier) : String?
      return "admin.errors.forbidden" unless Access.can?(user, :administrators, dossier)
      "admin.errors.dossier.not_active" unless dossier.state == "active"
    end

    # Relecture de la liste dans l'instance : ce que la société a changé
    # elle-même dans son dossier (ADR-002 D3) est repris.
    def self.refresh(user : User, dossier : Dossier) : Outcome(Task)
      return Outcome(Task).failure("base", "admin.errors.forbidden") unless Access.can?(user, :refresh_administrators, dossier)
      return Outcome(Task).failure("base", "admin.errors.dossier.not_active") unless dossier.state == "active"
      task = Tasks.enqueue("instance.admins", dossier.server!, Tasks.dossier_params(dossier), user, dossier)
      Audit.log(user, "administrators.refresh", target: dossier)
      Outcome(Task).new(task)
    end

    # Paramètres de la tâche d'une demande validée.
    def self.task_params(approval : Approval, params : Tasks::Params) : String
      params["email"] = Tasks.any(approval.param("email"))
      if approval.kind == "admin_remove"
        params["removal"] = Tasks.any(approval.param("removal"))
        return "instance.admin_remove"
      end
      unless approval.param("replaces").empty?
        params["replaces"] = Tasks.any(approval.param("replaces"))
        params["replace_removal"] = Tasks.any(approval.param("replace_removal"))
      end
      "instance.admin_add"
    end

    # --- Effets des tâches ----------------------------------------------------

    # Instance créée : le premier administrateur est actif ; les autres
    # déclarés à la création sont ajoutés par l'exécutant, au nom de qui a
    # créé le dossier.
    def self.after_creation(task : Task, dossier : Dossier) : Nil
      rows = list(dossier)
      first = rows.find(&.email.==(dossier.admin_email.to_s.downcase)) || rows.first?
      return if first.nil?
      first.state = "active"
      first.save!
      requester = task.requested_by_id.try { |id| User.filter(id: id).first }
      rows.each do |row|
        next if row.pk == first.pk || row.state != "pending"
        params = Tasks.dossier_params(dossier)
        params["email"] = Tasks.any(row.email)
        params["reason"] = Tasks.any("dossier.create")
        params["approval_ref"] = Tasks.any("#{CREATION_PREFIX}#{dossier.pk}")
        params["approval_mode"] = Tasks.any(ApprovalMode::SINGLE)
        params["approvers"] = Tasks.any([requester.try(&.email.to_s) || "partiduo-admin"])
        Tasks.enqueue("instance.admin_add", dossier.server!, params, requester, dossier)
      end
    end

    # Copie restaurée installée : ses administrateurs sont ceux de la
    # sauvegarde.
    def self.after_restored_copy(copy : Dossier) : Nil
      DossierAdmin.filter(dossier_id: copy.pk, state: "pending").update(state: "active")
    end

    def self.added(task : Task, dossier : Dossier, result : JSON::Any) : Nil
      params = task.params_json
      email = (result["email"]?.try(&.as_s?) || params["email"]?.try(&.as_s?) || "").downcase
      return if email.empty?
      row = DossierAdmin.filter(dossier_id: dossier.pk, email: email).first || DossierAdmin.new(dossier: dossier, email: email)
      row.state = "active"
      row.save!
      replaced = params["replaces"]?.try(&.as_s?).to_s
      DossierAdmin.filter(dossier_id: dossier.pk, email: replaced).delete unless replaced.empty?
      sync_first(dossier)
      Audit.log(nil, "administrators.added", target: dossier, actor_label: "agent:#{task.server.try(&.name)}",
        detail: {"email" => email, "replaces" => replaced, "created" => result["user_created"]?.to_s,
                 "promoted" => result["promoted"]?.to_s, "reference" => params["approval_ref"]?.try(&.as_s?).to_s})
    end

    def self.removed(task : Task, dossier : Dossier, result : JSON::Any) : Nil
      params = task.params_json
      email = (params["email"]?.try(&.as_s?) || "").downcase
      DossierAdmin.filter(dossier_id: dossier.pk, email: email).delete
      sync_first(dossier)
      Audit.log(nil, "administrators.removed", target: dossier, actor_label: "agent:#{task.server.try(&.name)}",
        detail: {"email" => email, "removal" => params["removal"]?.try(&.as_s?).to_s,
                 "changed" => result["changed"]?.to_s, "reference" => params["approval_ref"]?.try(&.as_s?).to_s})
    end

    # Liste relue dans l'instance : les administrateurs actifs et non
    # révoqués sont gardés (moyen d'authentification noté), ceux que la
    # société a retirés disparaissent, ceux qu'elle a ajoutés apparaissent ;
    # les ajouts encore en attente ne sont pas touchés.
    def self.refreshed(task : Task, dossier : Dossier, result : JSON::Any, now : Time) : Nil
      entries = result["admins"]?.try(&.as_a?) || [] of JSON::Any
      present = entries.select { |entry| entry["active"]?.try(&.as_bool?) != false && entry["revoked"]?.try(&.as_bool?) != true }
      seen = present.compact_map(&.["email"]?.try(&.as_s?).try(&.downcase))
      gone = DossierAdmin.filter(dossier_id: dossier.pk, state: "active").to_a.reject { |row| seen.includes?(row.email) }
      gone.each(&.delete)
      present.each do |entry|
        email = entry["email"]?.try(&.as_s?).try(&.downcase) || next
        row = DossierAdmin.filter(dossier_id: dossier.pk, email: email).first || DossierAdmin.new(dossier: dossier, email: email)
        row.state = "active"
        row.usable = entry["usable"]?.try(&.as_bool?)
        row.checked_at = now
        row.save!
      end
      sync_first(dossier)
      Audit.log(nil, "administrators.refreshed", target: dossier, actor_label: "agent:#{task.server.try(&.name)}",
        detail: {"count" => seen.size.to_s, "removed" => gone.map(&.email.to_s).join(',')})
    end

    # `Dossier#admin_email` suit le premier de la liste : adresse proposée
    # pour un recours d'accès.
    private def self.sync_first(dossier : Dossier) : Nil
      first = list(dossier).find(&.state.==("active")) || return
      return if dossier.admin_email == first.email
      dossier.admin_email = first.email
      dossier.save!
    end

    private def self.add(errors : Errors, field : String, key : String) : Nil
      (errors[field] ||= [] of String) << key
    end

    # --- Cabinet ---------------------------------------------------------------

    ROLES = [Config::FIRM_ADMIN, Config::FILE_MANAGER]

    # Admins de cabinet de la structure, du plus ancien au plus récent.
    def self.firm_admins(firm : Firm) : Array(User)
      User.filter(firm_id: firm.pk, role: Config::FIRM_ADMIN).order("created_at", "id").to_a
    end

    # Autres membres : gestionnaires de dossiers, qui peuvent devenir admins.
    def self.firm_members(firm : Firm) : Array(User)
      User.filter(firm_id: firm.pk, role: Config::FILE_MANAGER).order("created_at", "id").to_a
    end

    # Le super-admin, pour toute structure ; un admin de cabinet, pour la
    # sienne.
    def self.can_manage_firm?(user : User, firm : Firm) : Bool
      return true if user.super_admin?
      user.firm_admin? && user.active == true && user.firm_id == firm.pk
    end

    # Dernier admin actif d'une structure : il ne se retire pas, ne se
    # rétrograde pas et ne se désactive pas. Le parc sans cabinet a ses
    # super-admins.
    def self.last_firm_admin?(user : User) : Bool
      firm = user.firm
      return false if firm.nil? || firm.fleet? || !user.firm_admin? || user.active != true
      User.filter(firm_id: firm.pk, role: Config::FIRM_ADMIN, active: true).exclude(id: user.pk).count.zero?
    end

    # Invitation d'un admin de la structure (même chemin que l'écran des
    # utilisateurs).
    def self.invite_firm_admin(actor : User, firm : Firm, input : Directory::UserInput) : Outcome(User)
      return Outcome(User).failure("base", "admin.errors.forbidden") unless can_manage_firm?(actor, firm)
      Directory.invite_user(actor, input.copy_with(role: Config::FIRM_ADMIN, firm_id: PartiduoAdmin.id?(firm.pk)))
    end

    # Changement de rôle dans la structure : admin de cabinet ou
    # gestionnaire de dossiers (retrait des administrateurs).
    def self.set_role(actor : User, firm : Firm, target : User, role : String, self_confirmed : Bool) : Outcome(User)
      if refusal = role_refusal(actor, firm, target, role, self_confirmed)
        return Outcome(User).failure(*refusal)
      end
      return Outcome(User).new(target) if target.role == role
      before = target.role.to_s
      target.role = role
      target.save!
      Audit.log(actor, "user.role", target: target, detail: {"before" => before, "after" => role, "firm" => firm.name.to_s})
      # Équipe réduite : la validation à deux se désactive d'elle-même s'il
      # ne reste qu'une personne habilitée (D-VAL2-003).
      ApprovalMode.after_team_change(target)
      Outcome(User).new(target)
    end

    private def self.role_refusal(actor : User, firm : Firm, target : User, role : String,
                                  self_confirmed : Bool) : {String, String}?
      return {"base", "admin.errors.forbidden"} unless can_manage_firm?(actor, firm) && target.firm_id == firm.pk
      return {"base", "admin.errors.forbidden"} if target.super_admin?
      return {"role", "admin.errors.invalid"} unless ROLES.includes?(role)
      return if target.role == role
      return {"role", "admin.errors.firm.independent_role"} if firm.independent? && role != Config::FIRM_ADMIN
      if target.firm_admin? && last_firm_admin?(target)
        return {"base", "admin.errors.administrators.last"}
      end
      return {"self_confirm", "admin.errors.administrators.self_confirm"} if target.pk == actor.pk && !self_confirmed
    end

    # Remplacement : le nouvel admin est invité, puis l'ancien devient
    # gestionnaire de dossiers. Rien n'est changé si l'invitation est refusée.
    def self.replace_firm_admin(actor : User, firm : Firm, previous : User, input : Directory::UserInput,
                                self_confirmed : Bool) : Outcome(User)
      unless previous.firm_admin? && previous.firm_id == firm.pk
        return Outcome(User).failure("replaces", "admin.errors.administrators.unknown")
      end
      if previous.pk == actor.pk && !self_confirmed
        return Outcome(User).failure("self_confirm", "admin.errors.administrators.self_confirm")
      end
      invited = invite_firm_admin(actor, firm, input)
      return invited unless invited.ok?
      demoted = set_role(actor, firm, previous, Config::FILE_MANAGER, true)
      return Outcome(User).new(nil, demoted.errors) unless demoted.ok?
      invited
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAdmin
  # Opérations sensibles (ADR-008 D3, D5) : suppression définitive, recours
  # d'accès, ajout et retrait d'un administrateur du dossier (D-ADM-017) ;
  # actions propres à une structure, sans dossier (D-ADM-023, demandes
  # `Approval::FIRM_KINDS`, exécutées par `Administrators.apply_approval`).
  # Une personne demande ; selon le réglage de la structure (`ApprovalMode`,
  # D-VAL2-001) :
  #
  # * deux personnes : une *autre* personne habilitée (admin du cabinet du
  #   dossier ou super-admin) valide ;
  # * une personne : le demandeur, s'il est lui-même habilité à valider,
  #   confirme seul après une authentification forte récente et une
  #   confirmation explicite (D-VAL2-004).
  #
  # Alors seulement la tâche est enregistrée, avec la référence, le mode et
  # les noms, reportés dans le journal de l'instance.
  module Approvals
    alias Outcome = Fleet::Outcome

    # Suppression définitive : seulement un dossier archivé dont la durée de
    # conservation légale (dix ans) est écoulée — ou un dossier d'essai
    # (paquet `devel`), sans archive ni durée légale.
    def self.request_delete(user : User, dossier : Dossier, reason : String, now : Time = Config.now) : Outcome(Approval)
      return Outcome(Approval).failure("base", "admin.errors.forbidden") unless Access.can?(user, :request_delete, dossier)
      return Outcome(Approval).failure("base", "admin.errors.dossier.state") unless dossier.delete_state?
      unless dossier.retention_elapsed?(now)
        return Outcome(Approval).failure("base", "admin.errors.dossier.retention_running")
      end
      create(user, dossier, "delete", reason, {} of String => String, now)
    end

    # Recours d'accès : réémission de l'invitation de l'administrateur du
    # dossier (ADR-008 D3), à l'adresse que désigne la société.
    def self.request_admin_invite(user : User, dossier : Dossier, email : String, reason : String,
                                  now : Time = Config.now) : Outcome(Approval)
      return Outcome(Approval).failure("base", "admin.errors.forbidden") unless Access.can?(user, :request_admin_invite, dossier)
      return Outcome(Approval).failure("base", "admin.errors.dossier.not_active") unless dossier.state == "active"
      return Outcome(Approval).failure("email", "admin.errors.email") unless Fleet::EMAIL.matches?(email.strip)
      create(user, dossier, "admin_invite", reason, {"email" => email.strip.downcase}, now)
    end

    # Demande d'une autre opération sensible déjà contrôlée par son service
    # (administrateurs du dossier, D-ADM-017) : même motif exigé, une seule
    # demande en attente par type et par dossier, mode de la structure.
    def self.request(user : User, dossier : Dossier, kind : String, reason : String, params : Hash(String, String),
                     now : Time = Config.now) : Outcome(Approval)
      raise ArgumentError.new("demande inconnue : #{kind}") unless Approval::KINDS.includes?(kind)
      create(user, dossier, kind, reason, params, now)
    end

    # Demande d'une action propre à une structure (D-ADM-023), déjà
    # contrôlée par son service (`Administrators`, `ApprovalMode`) : une
    # seule demande en attente par type et par cible (`params["target"]`),
    # mode de la structure. Le motif est facultatif : les écrans de la
    # structure le proposent sans l'exiger.
    def self.request_firm(user : User, firm : Firm, kind : String, reason : String, params : Hash(String, String),
                          now : Time = Config.now) : Outcome(Approval)
      raise ArgumentError.new("demande de structure inconnue : #{kind}") unless Approval::FIRM_KINDS.includes?(kind)
      target = params["target"]? || ""
      open = Approval.filter(firm_id: firm.pk, kind: kind, state: "pending", expires_at__gt: now).to_a
      if open.any? { |approval| approval.param("target") == target }
        return Outcome(Approval).failure("base", "admin.errors.approval.already_pending")
      end
      mode = ApprovalMode.mode(firm, now)
      approval = Approval.create!(kind: kind, reference: Secrets.reference("DV"), firm: firm,
        params: params.to_json, reason: reason.strip, requested_by: user, expires_at: now + Config::APPROVAL_TTL, mode: mode)
      Audit.log(user, "approval.request", target: approval,
        detail: {"kind" => kind, "firm" => firm.name.to_s, "target" => target, "mode" => mode})
      Outcome(Approval).new(approval)
    end

    private def self.create(user : User, dossier : Dossier, kind : String, reason : String,
                            params : Hash(String, String), now : Time) : Outcome(Approval)
      return Outcome(Approval).failure("reason", "admin.errors.required") if reason.strip.size < 5
      if Approval.filter(dossier_id: dossier.pk, kind: kind, state: "pending", expires_at__gt: now).exists?
        return Outcome(Approval).failure("base", "admin.errors.approval.already_pending")
      end
      mode = ApprovalMode.mode_for(dossier, now)
      approval = Approval.create!(kind: kind, reference: Secrets.reference("DV"), dossier: dossier,
        params: params.to_json, reason: reason.strip, requested_by: user, expires_at: now + Config::APPROVAL_TTL, mode: mode)
      Audit.log(user, "approval.request", target: approval, detail: {"kind" => kind, "dossier" => dossier.slug.to_s, "mode" => mode})
      Outcome(Approval).new(approval)
    end

    # Le demandeur peut-il confirmer seul ? Structure réglée sur « une
    # personne » et demandeur habilité à valider (admin du cabinet du
    # dossier ou super-admin) : un gestionnaire de dossiers qui demande un
    # recours d'accès attend toujours un admin.
    def self.can_confirm_alone?(user : User, approval : Approval, now : Time = Config.now) : Bool
      return false unless approval.state == "pending" && approval.requested_by_id == user.pk
      return false unless habilitated?(user, approval)
      ApprovalMode.mode(approval.target_firm!, now) == ApprovalMode::SINGLE
    end

    # Habilité à décider de cette demande : admin du cabinet du dossier ou
    # super-admin ; pour une demande de structure, qui peut gérer ses
    # admins (le super-admin seul pour un compte de super-admin, D-ADM-023).
    def self.habilitated?(user : User, approval : Approval) : Bool
      if dossier = approval.dossier
        return Access.can?(user, :approve, dossier)
      end
      firm = approval.firm
      return false if firm.nil?
      return member?(user, firm) if Approval::MEMBER_KINDS.includes?(approval.kind)
      Administrators.can_request_firm?(user, firm, approval.super_scope?)
    end

    # Membre habilité de la structure : admin actif de la structure ;
    # super-admin actif pour le parc sans cabinet.
    def self.member?(user : User, firm : Firm) : Bool
      return false unless user.active == true
      return user.super_admin? if firm.fleet?
      user.firm_admin? && user.firm_id == firm.pk
    end

    # Validation par une *autre* personne habilitée : toujours possible,
    # quel que soit le réglage (deux personnes valent mieux qu'une).
    #
    # Une demande de structure ne crée pas de tâche : l'action est faite
    # aussitôt, et la valeur rendue est vide (`nil`).
    def self.approve(user : User, approval : Approval, now : Time = Config.now) : Outcome(Task)
      if failure = open_failure(approval, now)
        return failure
      end
      if approval.requested_by_id == user.pk
        return Outcome(Task).failure("base", "admin.errors.approval.same_person")
      end
      return Outcome(Task).failure("base", "admin.errors.forbidden") unless Access.can_approve?(user, approval)
      recourse = recourse?(user, approval)
      if recourse && now < recourse_at(approval)
        return Outcome(Task).failure("base", "admin.errors.approval.recourse_wait")
      end
      requester = approval.requested_by!
      # Admins avisés d'un recours : ceux de la structure avant la décision
      # (le compte qu'elle désactive compris).
      notified = recourse ? firm_admins(approval.target_firm!) : [] of User
      outcome = if approval.firm_target?
                  apply_firm(user, approval, ApprovalMode::DUAL, now)
                else
                  issue(user, approval, [requester.email.to_s, user.email.to_s], ApprovalMode::DUAL, now)
                end
      return outcome unless outcome.ok?
      detail = {"kind" => approval.kind.to_s, "requested_by" => requester.email.to_s, "mode" => ApprovalMode::DUAL}
      if dossier = approval.dossier
        detail["dossier"] = dossier.slug.to_s
      else
        detail["firm"] = approval.firm!.name.to_s
      end
      if recourse
        recourse_done(user, approval, detail, notified)
      else
        Audit.log(user, "approval.approve", target: approval, detail: detail)
      end
      outcome
    end

    # --- Dernier recours du super-admin (D-ADM-024) ---------------------------

    # Validation en dernier recours : un super-admin valide la demande d'une
    # structure dont il n'est pas membre (cabinet, gestionnaire
    # indépendant). Le parc sans cabinet est la structure des super-admins :
    # ils y valident sans délai.
    def self.recourse?(user : User, approval : Approval) : Bool
      return false unless user.super_admin?
      firm = approval.target_firm
      !firm.nil? && !firm.fleet?
    end

    # Heure à partir de laquelle le recours est possible : la demande est
    # restée `Config.recourse_delay` sans décision d'un admin habilité de la
    # structure (une décision l'aurait close). Heure de la demande selon
    # l'horloge de la console : son échéance moins sa durée de vie.
    def self.recourse_at(approval : Approval) : Time
      approval.expires_at! - Config::APPROVAL_TTL + Config.recourse_delay
    end

    # Le recours attend encore son heure (écrans : bouton « Valider »
    # remplacé par l'heure du recours).
    def self.recourse_waiting?(user : User, approval : Approval, now : Time = Config.now) : Bool
      recourse?(user, approval) && now < recourse_at(approval)
    end

    # Admins actifs d'une structure (sans les super-admins du parc).
    private def self.firm_admins(firm : Firm) : Array(User)
      User.filter(firm_id: firm.pk, role: Config::FIRM_ADMIN, active: true).order("email").to_a
    end

    # Recours fait : tracé comme tel (`approval.recourse`, délai attendu),
    # et les admins actifs de la structure en sont avisés par courriel, le
    # canal des autres avis de la console.
    private def self.recourse_done(user : User, approval : Approval, detail : Hash(String, String), recipients : Array(User)) : Nil
      detail["recourse_after_hours"] = Config.recourse_delay.total_hours.to_i.to_s
      detail["requested_at"] = (approval.expires_at! - Config::APPROVAL_TTL).to_s("%Y-%m-%d %H:%M")
      notified, failed = Mailer.recourse(approval, user, recipients)
      detail["notified"] = notified.join(',')
      detail["notice_failed"] = failed.join(',') unless failed.empty?
      Audit.log(user, "approval.recourse", target: approval, detail: detail)
    end

    # Confirmation par le demandeur seul (structure réglée sur « une
    # personne », D-VAL2-004) : authentification forte récente
    # (`strong_recent`, établie par le handler) et confirmation explicite —
    # le sous-domaine du dossier retapé pour une suppression définitive, une
    # case cochée pour un recours d'accès. Les contrôles de l'état du dossier
    # et de la durée légale sont ceux de la validation à deux.
    def self.confirm_alone(user : User, approval : Approval, strong_recent : Bool, confirmation : String,
                           now : Time = Config.now) : Outcome(Task)
      if failure = open_failure(approval, now)
        return failure
      end
      return Outcome(Task).failure("base", "admin.errors.forbidden") unless approval.requested_by_id == user.pk
      return Outcome(Task).failure("base", "admin.errors.approval.needs_admin") unless habilitated?(user, approval)
      if ApprovalMode.mode(approval.target_firm!, now) != ApprovalMode::SINGLE
        return Outcome(Task).failure("base", "admin.errors.approval.dual_required")
      end
      return Outcome(Task).failure("reauth", "admin.errors.approval.reauth") unless strong_recent
      return confirm_firm_alone(user, approval, confirmation, now) if approval.firm_target?
      dossier = approval.dossier!
      expected = approval.kind == "delete" ? dossier.slug.to_s : "yes"
      unless confirmation.strip == expected
        key = approval.kind == "delete" ? "admin.errors.approval.confirmation_slug" : "admin.errors.approval.confirmation"
        return Outcome(Task).failure("confirmation", key)
      end
      outcome = issue(user, approval, [user.email.to_s], ApprovalMode::SINGLE, now)
      if outcome.ok?
        Audit.log(user, "approval.confirm_alone", target: approval,
          detail: {"kind" => approval.kind.to_s, "dossier" => dossier.slug.to_s, "mode" => ApprovalMode::SINGLE})
      end
      outcome
    end

    # Demande de structure confirmée seule (D-ADM-023) : case cochée.
    private def self.confirm_firm_alone(user : User, approval : Approval, confirmation : String, now : Time) : Outcome(Task)
      return Outcome(Task).failure("confirmation", "admin.errors.approval.confirmation") unless confirmation.strip == "yes"
      outcome = apply_firm(user, approval, ApprovalMode::SINGLE, now)
      if outcome.ok?
        Audit.log(user, "approval.confirm_alone", target: approval,
          detail: {"kind" => approval.kind.to_s, "firm" => approval.firm!.name.to_s, "mode" => ApprovalMode::SINGLE})
      end
      outcome
    end

    # Demande encore ouverte ? Sinon l'échec à rendre (une demande échue
    # passe à « expirée »).
    private def self.open_failure(approval : Approval, now : Time) : Outcome(Task)?
      return Outcome(Task).failure("base", "admin.errors.approval.state") unless approval.state == "pending"
      if approval.expires_at! <= now
        approval.state = "expired"
        approval.save!
        return Outcome(Task).failure("base", "admin.errors.approval.expired")
      end
      nil
    end

    # Décision d'une demande de structure (D-ADM-023) : la demande passe à
    # « validée » par une mise à jour conditionnelle, et l'action est faite
    # dans la même transaction (`Administrators.apply_approval`), après les
    # recontrôles : demandeur encore habilité, cible inchangée depuis la
    # demande, règles du service (jamais zéro admin…). Un recontrôle refusé
    # annule tout et clôt la demande (« expirée », `approval.stale`) : il
    # faut la refaire sur l'état présent. Jamais rejouée (D-AFN-010).
    private def self.apply_firm(user : User, approval : Approval, mode : String, now : Time) : Outcome(Task)
      failure = Fleet::Errors.new
      code : String? = nil
      done = false
      Marten::DB::Connection.default.transaction do
        claimed = Approval.filter(id: approval.pk, state: "pending")
          .update(state: "approved", decided_at: now, mode: mode, decided_by_id: user.pk)
        if claimed == 1
          failure, code = Administrators.apply_approval(approval, now)
          raise Marten::DB::Errors::Rollback.new unless failure.empty?
          approval.state = "approved"
          approval.mode = mode
          approval.decided_by = user
          approval.decided_at = now
          approval.save!
          done = true
        end
      end
      unless done
        approval.reload
        return Outcome(Task).failure("base", "admin.errors.approval.state") if failure.empty?
        stale(user, approval, failure, now)
        return Outcome(Task).new(nil, failure)
      end
      outcome = Outcome(Task).new(nil)
      outcome.signup_code = code
      outcome
    end

    # Demande devenue fausse (cible changée, demandeur plus habilité, règle
    # enfreinte) : close, avec la raison au journal d'audit.
    private def self.stale(user : User, approval : Approval, failure : Fleet::Errors, now : Time) : Nil
      closed = Approval.filter(id: approval.pk, state: "pending").update(state: "expired", decided_at: now)
      approval.reload
      return unless closed == 1
      Audit.log(user, "approval.stale", target: approval, outcome: "refused",
        detail: {"kind" => approval.kind.to_s, "errors" => failure.values.flatten.join(',')})
    end

    # Enregistre la tâche de la demande : état du dossier recontrôlé,
    # référence, mode (`approval_mode`, `single` ou `dual`) et personnes
    # (`approvers`) dans les paramètres de la tâche.
    private def self.issue(user : User, approval : Approval, approvers : Array(String), mode : String,
                           now : Time) : Outcome(Task)
      dossier = approval.dossier!
      params = Tasks.dossier_params(dossier)
      params["approval_ref"] = Tasks.any(approval.reference)
      params["approval_mode"] = Tasks.any(mode)
      params["approvers"] = Tasks.any(approvers)
      params["reason"] = Tasks.any(approval.reason)
      kind = case approval.kind
             when "delete"
               # Recontrôle : l'état a pu changer depuis la demande.
               unless dossier.delete_state? && dossier.retention_elapsed?(now)
                 return Outcome(Task).failure("base", "admin.errors.dossier.retention_running")
               end
               params["backups"] = Tasks.any(Backup.filter(dossier_id: dossier.pk).exclude(state: "pruned")
                 .flat_map { |backup| [backup.path.to_s, backup.media_path.to_s] }.reject(&.empty?))
               "instance.delete"
             when "admin_add", "admin_remove"
               return Outcome(Task).failure("base", "admin.errors.dossier.not_active") unless dossier.state == "active"
               Administrators.task_params(approval, params)
             else
               # Recontrôle : le dossier a pu être suspendu ou archivé depuis.
               return Outcome(Task).failure("base", "admin.errors.dossier.not_active") unless dossier.state == "active"
               params["email"] = Tasks.any(approval.param("email"))
               "instance.admin_invite"
             end
      # La demande passe à « validée » par une mise à jour conditionnelle,
      # dans la transaction qui enregistre la tâche : de deux décisions
      # simultanées, une seule crée la tâche (D-AFN-010).
      task : Task? = nil
      Marten::DB::Connection.default.transaction do
        claimed = Approval.filter(id: approval.pk, state: "pending")
          .update(state: "approved", decided_at: now, mode: mode, decided_by_id: user.pk)
        if claimed == 1
          created = Tasks.enqueue(kind, dossier.server!, params, user, dossier)
          approval.state = "approved"
          approval.mode = mode
          approval.decided_by = user
          approval.decided_at = now
          approval.task = created
          approval.save!
          task = created
        end
      end
      issued = task
      if issued.nil?
        approval.reload
        return Outcome(Task).failure("base", "admin.errors.approval.state")
      end
      Outcome(Task).new(issued)
    end

    def self.reject(user : User, approval : Approval, now : Time = Config.now) : Bool
      return false unless approval.state == "pending"
      return false unless approval.requested_by_id == user.pk || Access.can_approve?(user, approval)
      # Mise à jour conditionnelle, comme la validation (D-AFN-010) : une
      # demande validée entre-temps n'est jamais « rejetée » après coup
      # (D-AFN-011, D-CRA-006).
      claimed = Approval.filter(id: approval.pk, state: "pending").update(state: "rejected", decided_at: now)
      if claimed != 1
        approval.reload
        return false
      end
      approval.state = "rejected"
      approval.decided_by = user
      approval.decided_at = now
      approval.save!
      Audit.log(user, "approval.reject", target: approval)
      true
    end

    # Demandes visibles : celles des dossiers de la portée de l'utilisateur,
    # et celles de sa structure pour son admin (D-ADM-023).
    def self.visible(user : User) : Marten::DB::Query::Set(Approval)
      return Approval.all if user.super_admin?
      ids = Access.dossiers(user).map(&.pk!.as(Int64))
      firm_id = user.firm_id
      return Approval.filter(dossier_id__in: ids) unless user.firm_admin? && firm_id
      return Approval.filter(firm_id: firm_id) if ids.empty?
      Approval.filter { q(dossier_id__in: ids) | q(firm_id: firm_id) }
    end

    # Écran où revenir après la décision d'une demande de structure.
    def self.back_path(approval : Approval) : String
      case approval.kind
      when "mode_single" then "/firms/#{approval.firm_id}/approval-mode"
      when "backup_weaken"
        dossier = approval.param("dossier_id")
        dossier.empty? ? "/firms/#{approval.firm_id}/backups" : "/dossiers/#{dossier}"
      when "admin_disable", "admin_enable" then "/users"
      else                                      "/firms/#{approval.firm_id}/admins"
      end
    end
  end
end

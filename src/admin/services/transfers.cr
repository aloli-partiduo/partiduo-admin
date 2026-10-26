# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAdmin
  # Transfert d'un dossier vers une autre structure (D-ADM-027) : il change
  # le cabinet du dossier, donc ses droits, son donneur d'ordre, la clé de
  # ses sauvegardes suivantes et ses journaux.
  #
  # * *Initiative* : le super-admin seul — il voit les deux structures,
  #   leurs donneurs d'ordre et leurs clés ; un admin de cabinet ne voit pas
  #   les autres structures.
  # * *Accord des deux structures* : chacune selon son réglage — une
  #   personne habilitée de la structure (admin actif ; super-admin pour le
  #   parc sans cabinet) à une personne, deux personnes distinctes à deux —,
  #   après ré-authentification forte récente et case cochée. Le demandeur
  #   ne donne jamais d'accord ; aucun recours du super-admin : c'est
  #   l'accord de la structure elle-même qui est demandé.
  # * *Exécution* au dernier accord, dans une transaction, après les
  #   recontrôles relus en base ; tracée des deux côtés.
  module Transfers
    alias Outcome = Fleet::Outcome
    alias Errors = Fleet::Errors

    # États d'un dossier transférable.
    STATES = %w[active suspended]

    # Qui peut demander un transfert : le super-admin actif.
    def self.can_request?(user : User) : Bool
      user.super_admin? && user.active == true
    end

    # --- Chiffrement : jamais affaibli par un transfert ------------------------

    # Surcharge du chiffrement du dossier après le transfert : la sienne s'il
    # en a une ; sinon, si le réglage de la structure d'accueil est moins
    # protecteur que son chiffrement effectif, celui-ci devient sa surcharge
    # (D-ADM-025 : un affaiblissement se demande à la structure qui le
    # décide, ici l'accueil, après le transfert) ; sinon il hérite.
    def self.encryption_override(dossier : Dossier, firm : Firm) : String
      current = dossier.backup_encryption.to_s
      return current unless current.empty?
      effective = dossier.effective_encryption
      BackupEncryption.weaker?(effective, firm.backup_encryption.to_s) ? effective : ""
    end

    def self.encryption_after(dossier : Dossier, firm : Firm) : String
      encryption_override(dossier, firm).presence || firm.backup_encryption.to_s
    end

    # --- Demande -------------------------------------------------------------------

    # Premier refus d'un transfert (champ, clé), sans rien enregistrer :
    # service, étapes de l'assistant et recontrôle de la décision.
    def self.refusal(user : User, dossier : Dossier?, firm : Firm?, payer : Payer?) : {String, String}?
      return {"base", "admin.errors.forbidden"} unless can_request?(user)
      return {"dossier_id", "admin.errors.required"} if dossier.nil?
      return {"dossier_id", "admin.errors.dossier.state"} unless STATES.includes?(dossier.state)
      return {"firm_id", "admin.errors.required"} if firm.nil? || firm.active != true
      return {"firm_id", "admin.errors.transfer.same_firm"} if firm.pk == dossier.firm_id
      if encryption_after(dossier, firm) == "cabinet" && firm.backup_key?.nil?
        return {"firm_id", "admin.errors.transfer.no_key"}
      end
      return {"payer_id", "admin.errors.dossier.payer_required"} if payer.nil?
      return {"payer_id", "admin.errors.dossier.payer_scope"} unless payer.firm_id == firm.pk
      nil
    end

    # Ce que la demande suppose du dossier : structure, donneur d'ordre,
    # état, serveur, surcharge du chiffrement.
    def self.state(dossier : Dossier) : String
      [dossier.firm_id, dossier.payer_id, dossier.state, dossier.server_id, dossier.backup_encryption].join('|')
    end

    def self.request(user : User, dossier : Dossier, firm_id : Int64?, payer_id : Int64?, reason : String,
                     now : Time = Config.now) : Outcome(Approval)
      dossier.reload
      firm = firm_id.try { |id| Firm.filter(id: id).first }
      payer = payer_id.try { |id| Payer.filter(id: id).first }
      if refused = refusal(user, dossier, firm, payer)
        return Outcome(Approval).failure(*refused)
      end
      return Outcome(Approval).failure("firm_id", "admin.errors.required") unless firm && payer
      return Outcome(Approval).failure("reason", "admin.errors.required") if reason.strip.size < 5
      if Approval.filter(dossier_id: dossier.pk, kind: Approval::TRANSFER, state: "pending", expires_at__gt: now).exists?
        return Outcome(Approval).failure("base", "admin.errors.approval.already_pending")
      end
      origin = dossier.firm!
      destination = firm
      params = {"from_firm_id" => origin.pk.to_s, "from_name" => origin.name.to_s, "to_name" => destination.name.to_s,
                "payer_id" => payer.pk.to_s, "payer_name" => payer.name.to_s,
                "previous_payer" => dossier.payer_name, "state" => state(dossier),
                "encryption_from" => dossier.effective_encryption, "encryption_to" => encryption_after(dossier, destination),
                "managers" => managers(dossier).size.to_s}
      modes = {ApprovalMode.mode(origin, now), ApprovalMode.mode(destination, now)}
      approval = Approval.create!(kind: Approval::TRANSFER, reference: Secrets.reference("DV"), dossier: dossier,
        firm: destination, params: params.to_json, reason: reason.strip, requested_by: user,
        expires_at: now + Config::APPROVAL_TTL, mode: modes.includes?(ApprovalMode::DUAL) ? ApprovalMode::DUAL : ApprovalMode::SINGLE)
      detail = {"kind" => Approval::TRANSFER, "dossier" => dossier.slug.to_s, "from" => origin.name.to_s,
                "to" => destination.name.to_s, "origin_mode" => modes[0], "destination_mode" => modes[1]}
      both_sides(user, "approval.request", approval, origin, destination, detail)
      Outcome(Approval).new(approval)
    end

    # Gestionnaires de dossiers à qui ce dossier est confié.
    def self.managers(dossier : Dossier) : Array(User)
      ids = Assignment.filter(dossier_id: dossier.pk).map(&.user_id)
      ids.empty? ? [] of User : User.filter(id__in: ids.compact).order("email").to_a
    end

    # --- Accords -------------------------------------------------------------------

    def self.origin(approval : Approval) : Firm?
      approval.param("from_firm_id").to_i64?.try { |id| Firm.filter(id: id).first }
    end

    def self.destination(approval : Approval) : Firm?
      approval.firm
    end

    # Côté dont l'utilisateur est membre habilité (`origin`, `destination`),
    # `nil` s'il n'est d'aucun des deux.
    def self.side_of(user : User, approval : Approval) : String?
      if firm = origin(approval)
        return "origin" if Approvals.member?(user, firm)
      end
      if firm = destination(approval)
        return "destination" if Approvals.member?(user, firm)
      end
      nil
    end

    def self.side_firm(approval : Approval, side : String) : Firm?
      side == "origin" ? origin(approval) : destination(approval)
    end

    # Accords exigés d'une structure : un à une personne, deux à deux
    # personnes (lu à chaque accord, D-VAL2-006).
    def self.needed(firm : Firm, now : Time = Config.now) : Int32
      ApprovalMode.mode(firm, now) == ApprovalMode::DUAL ? 2 : 1
    end

    # Accords valables d'un côté : ceux de personnes encore habilitées pour
    # cette structure, relues en base.
    def self.valid_consents(approval : Approval, side : String) : Array(ApprovalConsent)
      firm = side_firm(approval, side) || return [] of ApprovalConsent
      ApprovalConsent.filter(approval_id: approval.pk, side: side).order("id").to_a.select do |consent|
        consent.user.try { |person| Approvals.member?(person, firm) } || false
      end
    end

    def self.side_done?(approval : Approval, side : String, now : Time = Config.now) : Bool
      firm = side_firm(approval, side) || return false
      valid_consents(approval, side).size >= needed(firm, now)
    end

    # L'utilisateur peut-il donner son accord maintenant ?
    def self.can_consent?(user : User, approval : Approval, now : Time = Config.now) : Bool
      return false unless approval.transfer? && approval.state == "pending" && approval.expires_at! > now
      return false if approval.requested_by_id == user.pk
      side = side_of(user, approval) || return false
      !ApprovalConsent.filter(approval_id: approval.pk, user_id: user.pk).exists? && !side_done?(approval, side, now)
    end

    # Accord d'une personne habilitée d'une des deux structures :
    # ré-authentification forte récente et case cochée. Le dernier accord
    # exécute le transfert ; la valeur rendue dit s'il est fait.
    def self.consent(user : User, approval : Approval, strong_recent : Bool, confirmation : String,
                     now : Time = Config.now) : Outcome(Bool)
      if refused = consent_refusal(user, approval, strong_recent, confirmation, now)
        return Outcome(Bool).failure(*refused)
      end
      side = side_of(user, approval) || return Outcome(Bool).failure("base", "admin.errors.forbidden")
      firm = side_firm(approval, side) || return Outcome(Bool).failure("base", "admin.errors.forbidden")
      mode = ApprovalMode.mode(firm, now)
      begin
        ApprovalConsent.create!(approval: approval, firm: firm, side: side, user: user, mode: mode)
      rescue ex : Exception
        # Accord concurrent de la même personne, ou demande close entre-temps
        # (la base refuse) : rien n'est enregistré.
        Log.warn { "accord de transfert refusé : #{ex.message}" }
        approval.reload
        return Outcome(Bool).failure("base", approval.state == "pending" ? "admin.errors.transfer.already_consented" : "admin.errors.approval.state")
      end
      Audit.log(user, "transfer.consent", target: approval, firm_id: PartiduoAdmin.id?(firm.pk),
        detail: {"side" => side, "mode" => mode, "dossier" => approval.dossier.try(&.slug.to_s) || "",
                 "from" => approval.param("from_name"), "to" => approval.param("to_name")})
      return Outcome(Bool).new(false) unless SIDES.all? { |each_side| side_done?(approval, each_side, now) }
      complete(user, approval, now)
    end

    SIDES = ApprovalConsent::SIDES

    # Premier refus d'un accord (champ, clé) : demande close, demandeur,
    # personne étrangère aux deux structures, ré-authentification, case,
    # accord déjà donné, structure qui a déjà donné tous ses accords.
    private def self.consent_refusal(user : User, approval : Approval, strong_recent : Bool, confirmation : String,
                                     now : Time) : {String, String}?
      return {"base", "admin.errors.invalid"} unless approval.transfer?
      if key = Approvals.closed_failure(approval, now)
        return {"base", key}
      end
      return {"base", "admin.errors.approval.same_person"} if approval.requested_by_id == user.pk
      side = side_of(user, approval) || return {"base", "admin.errors.forbidden"}
      return {"reauth", "admin.errors.approval.reauth"} unless strong_recent
      return {"confirmation", "admin.errors.approval.confirmation"} unless confirmation.strip == "yes"
      return {"base", "admin.errors.transfer.already_consented"} if ApprovalConsent.filter(approval_id: approval.pk, user_id: user.pk).exists?
      return {"base", "admin.errors.transfer.side_done"} if side_done?(approval, side, now)
      nil
    end

    # Dernier accord : la demande passe à « validée » par une mise à jour
    # conditionnelle et le transfert est fait dans la même transaction,
    # après les recontrôles ; sinon tout est annulé et la demande close
    # (`approval.stale`, des deux côtés). Jamais rejouée.
    private def self.complete(user : User, approval : Approval, now : Time) : Outcome(Bool)
      failure = Errors.new
      done = false
      record = nil.as(Hash(String, String)?)
      Marten::DB::Connection.default.transaction do
        claimed = Approval.filter(id: approval.pk, state: "pending")
          .update(state: "approved", decided_at: now, decided_by_id: user.pk)
        if claimed == 1
          failure, record = apply(approval, now)
          raise Marten::DB::Errors::Rollback.new unless failure.empty?
          done = true
        end
      end
      approval.reload
      unless done
        return Outcome(Bool).failure("base", "admin.errors.approval.state") if failure.empty?
        stale(user, approval, failure, now)
        return Outcome(Bool).new(nil, failure)
      end
      after(user, approval, record || {} of String => String)
      Outcome(Bool).new(true)
    end

    # Recontrôles et changement de rattachement (dans la transaction).
    private def self.apply(approval : Approval, now : Time) : {Errors, Hash(String, String)?}
      changed = {Errors{"base" => ["admin.errors.approval.target_changed"]}, nil}
      dossier = Dossier.get!(id: approval.dossier_id)
      requester = User.get!(id: approval.requested_by_id)
      destination = Firm.get!(id: approval.firm_id)
      payer = approval.param("payer_id").to_i64?.try { |id| Payer.filter(id: id).first }
      return changed unless state(dossier) == approval.param("state") && dossier.firm_id.to_s == approval.param("from_firm_id")
      return {Errors{"base" => ["admin.errors.approval.requester_gone"]}, nil} unless can_request?(requester)
      if refused = refusal(requester, dossier, destination, payer)
        return {Errors{refused[0] => [refused[1]]}, nil}
      end
      return {Errors{"payer_id" => ["admin.errors.dossier.payer_required"]}, nil} if payer.nil?
      return changed unless encryption_after(dossier, destination) == approval.param("encryption_to")
      origin = dossier.firm!
      removed = managers(dossier)
      before_payer = dossier.payer_name
      before_encryption = dossier.effective_encryption
      dossier.backup_encryption = encryption_override(dossier, destination)
      dossier.firm = destination
      dossier.payer = payer
      dossier.save!
      # Les gestionnaires de l'ancienne structure perdent leur accès.
      Assignment.filter(dossier_id: dossier.pk).delete
      # Demandes en attente sur le dossier : décidées dans l'ancienne
      # structure, elles sont closes (à refaire dans la nouvelle).
      closed = Approval.filter(dossier_id: dossier.pk, state: "pending").exclude(id: approval.pk).to_a
      closed.each do |other|
        Approval.filter(id: other.pk, state: "pending").update(state: "expired", decided_at: now)
      end
      record = {"dossier" => dossier.slug.to_s, "from" => origin.name.to_s, "to" => destination.name.to_s,
                "from_firm_id" => origin.pk.to_s, "to_firm_id" => destination.pk.to_s,
                "payer_before" => before_payer, "payer_after" => payer.name.to_s,
                "encryption_before" => before_encryption, "encryption_after" => dossier.effective_encryption,
                "managers_removed" => removed.map(&.email.to_s).join(','),
                "requests_closed" => closed.map(&.reference.to_s).join(','), "approval" => approval.reference.to_s,
                "consents" => consents_summary(approval)}
      {Errors.new, record}
    end

    # Accords donnés, par côté : « origin:a@x,b@y;destination:c@z ».
    private def self.consents_summary(approval : Approval) : String
      SIDES.map do |side|
        "#{side}:#{ApprovalConsent.filter(approval_id: approval.pk, side: side).order("id").compact_map(&.user.try(&.email.to_s)).join(',')}"
      end.join(';')
    end

    # Après le transfert : traces des deux côtés, puis une sauvegarde prise
    # aussitôt avec le chiffrement de l'accueil, première sauvegarde que la
    # nouvelle structure peut restaurer (les précédentes gardent leur
    # chiffrement, D-ADM-027).
    private def self.after(user : User, approval : Approval, record : Hash(String, String)) : Nil
      dossier = Dossier.get!(id: approval.dossier_id)
      origin = Firm.filter(id: record["from_firm_id"]?.try(&.to_i64?)).first
      destination = dossier.firm!
      backup = Fleet.backup_now(nil, dossier, "manual")
      record["backup_task"] = backup.value.try(&.pk.to_s) || backup.errors.values.flatten.join(',')
      both_sides(user, "dossier.transfer", dossier, origin, destination, record)
      references = record["requests_closed"]?.to_s.split(',', remove_empty: true)
      Approval.filter(reference__in: references).each do |other|
        both_sides(user, "approval.stale", other, origin, destination,
          {"kind" => other.kind.to_s, "errors" => "admin.errors.transfer.transferred"})
      end
    end

    # Trace inscrite dans les journaux des deux structures (portée de lecture
    # de leurs admins).
    private def self.both_sides(user : User, action : String, target : Marten::Model, origin : Firm?, destination : Firm?,
                                detail : Hash(String, String)) : Nil
      [origin, destination].compact.uniq!(&.pk).each do |firm|
        Audit.log(user, action, target: target, firm_id: PartiduoAdmin.id?(firm.pk), detail: detail)
      end
    end

    # Demande devenue fausse : close, avec la raison, des deux côtés.
    private def self.stale(user : User, approval : Approval, failure : Errors, now : Time) : Nil
      closed = Approval.filter(id: approval.pk, state: "pending").update(state: "expired", decided_at: now)
      approval.reload
      return unless closed == 1
      both_sides(user, "approval.stale", approval, origin(approval), destination(approval),
        {"kind" => Approval::TRANSFER, "errors" => failure.values.flatten.join(',')})
    end

    # Refus ou retrait : le demandeur, ou une personne habilitée de l'une des
    # deux structures (un refus de l'une suffit).
    def self.can_reject?(user : User, approval : Approval) : Bool
      approval.requested_by_id == user.pk || !side_of(user, approval).nil?
    end
  end
end

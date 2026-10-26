# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Désactivation, réactivation et changement de nature d'une structure
  # (D-ADM-026) : gestes du super-admin (les structures relèvent de lui,
  # ADR-008 D2), soumis au réglage « validation à deux » de la structure dès
  # qu'elle a une équipe, comme ses changements d'admins (D-ADM-023).
  #
  # * Désactiver : ses utilisateurs ne se connectent plus (`User#can_sign_in?`)
  #   et leurs sessions sont révoquées ; aucun dossier n'y est créé. Ses
  #   dossiers continuent de servir leurs sociétés (ADR-008 D3 : jamais les
  #   données).
  # * Changer de nature : cabinet ↔ gestionnaire indépendant. Le parc sans
  #   cabinet ne change pas de nature et aucune structure ne le devient
  #   (un seul, D-VAL2-002). Devenir gestionnaire indépendant exige une
  #   seule personne active, admin de la structure.
  #
  # `set_active` et `set_kind` refusent eux-mêmes le geste direct quand la
  # structure a une équipe (`needs_approval`) : les écrans appellent alors
  # `request_active` ou `request_kind`, et la décision exécute
  # `apply_active` ou `apply_kind` après les recontrôles.
  module Firms
    alias Outcome = Fleet::Outcome
    alias Errors = Fleet::Errors

    KINDS = %w[cabinet independent]

    # État de la structure que suppose une demande : nature et activité.
    def self.state(firm : Firm) : String
      "#{firm.kind}|#{firm.active}"
    end

    # Qui décide de ces gestes : le super-admin actif.
    def self.can_manage?(user : User) : Bool
      user.super_admin? && user.active == true
    end

    # --- Désactivation et réactivation ----------------------------------------

    def self.active_refusal(actor : User, firm : Firm, active : Bool) : {String, String}?
      return {"base", "admin.errors.forbidden"} unless can_manage?(actor)
      return {"base", "admin.errors.firm.fleet_fixed"} if firm.fleet?
      return {"base", "admin.errors.invalid"} if firm.active == active
      nil
    end

    def self.set_active(actor : User, firm : Firm, active : Bool, now : Time = Config.now) : Outcome(Firm)
      firm.reload
      if refused = active_refusal(actor, firm, active)
        return Outcome(Firm).failure(*refused)
      end
      return Outcome(Firm).failure("base", "admin.errors.approval.needs_request") if Administrators.firm_gated?(firm)
      errors = apply_active(actor, firm, active, nil, now)
      errors.empty? ? Outcome(Firm).new(firm) : Outcome(Firm).new(nil, errors)
    end

    def self.request_active(actor : User, firm : Firm, active : Bool, reason : String = "",
                            now : Time = Config.now) : Outcome(Approval)
      firm.reload
      if refused = active_refusal(actor, firm, active)
        return Outcome(Approval).failure(*refused)
      end
      params = {"target" => "firm_state", "firm_state" => state(firm)}
      Approvals.request_firm(actor, firm, active ? "firm_enable" : "firm_disable", reason, params, now)
    end

    # Exécution (geste direct sans équipe, ou demande décidée) ; `approval`
    # relue en base doit supposer l'état présent.
    def self.apply_active(actor : User, firm : Firm, active : Bool, approval : Approval?, now : Time) : Errors
      if approval && approval.param("firm_state") != state(firm)
        return Errors{"base" => ["admin.errors.approval.target_changed"]}
      end
      if refused = active_refusal(actor, firm, active)
        return Errors{refused[0] => [refused[1]]}
      end
      firm.active = active
      firm.save!
      # Désactivée : plus aucune session ouverte de ses utilisateurs.
      User.filter(firm_id: firm.pk).each { |member| Auth::Sessions.revoke_all(member, now) } unless active
      detail = {"kind" => firm.kind.to_s}
      approval.try { |decided| detail["approval"] = decided.reference.to_s }
      Audit.log(actor, active ? "firm.enable" : "firm.disable", target: firm, detail: detail)
      Errors.new
    end

    # --- Nature -------------------------------------------------------------------

    def self.kind_refusal(actor : User, firm : Firm, kind : String) : {String, String}?
      return {"base", "admin.errors.forbidden"} unless can_manage?(actor)
      return {"kind", "admin.errors.firm.fleet_fixed"} if firm.fleet? || kind == "fleet"
      return {"kind", "admin.errors.invalid"} unless KINDS.includes?(kind) && firm.kind != kind
      return unless kind == "independent"
      # Gestionnaire indépendant : une seule personne, admin de sa structure.
      members = User.filter(firm_id: firm.pk, active: true).to_a
      return {"kind", "admin.errors.firm.independent_single"} if members.size > 1
      return {"kind", "admin.errors.firm.independent_role"} if members.any? { |member| !member.firm_admin? }
      nil
    end

    def self.set_kind(actor : User, firm : Firm, kind : String) : Outcome(Firm)
      firm.reload
      if refused = kind_refusal(actor, firm, kind)
        return Outcome(Firm).failure(*refused)
      end
      return Outcome(Firm).failure("base", "admin.errors.approval.needs_request") if Administrators.firm_gated?(firm)
      errors = apply_kind(actor, firm, kind, nil)
      errors.empty? ? Outcome(Firm).new(firm) : Outcome(Firm).new(nil, errors)
    end

    def self.request_kind(actor : User, firm : Firm, kind : String, reason : String = "",
                          now : Time = Config.now) : Outcome(Approval)
      firm.reload
      if refused = kind_refusal(actor, firm, kind)
        return Outcome(Approval).failure(*refused)
      end
      params = {"target" => "kind", "firm_state" => state(firm), "kind_from" => firm.kind.to_s, "kind_to" => kind}
      Approvals.request_firm(actor, firm, "firm_kind", reason, params, now)
    end

    def self.apply_kind(actor : User, firm : Firm, kind : String, approval : Approval?) : Errors
      if approval && approval.param("firm_state") != state(firm)
        return Errors{"base" => ["admin.errors.approval.target_changed"]}
      end
      if refused = kind_refusal(actor, firm, kind)
        return Errors{refused[0] => [refused[1]]}
      end
      before = firm.kind.to_s
      firm.kind = kind
      firm.save!
      detail = {"before" => before, "after" => kind}
      approval.try { |decided| detail["approval"] = decided.reference.to_s }
      Audit.log(actor, "firm.kind", target: firm, detail: detail)
      # Gestionnaire indépendant : une personne, la validation à deux se
      # désactive d'elle-même (D-VAL2-003).
      ApprovalMode.reconcile(firm)
      Errors.new
    end

    # Exécution d'une demande décidée (`Administrators.apply_approval`).
    def self.apply_approval(approval : Approval, firm : Firm, requester : User, now : Time) : Errors
      case approval.kind
      when "firm_disable" then apply_active(requester, firm, false, approval, now)
      when "firm_enable"  then apply_active(requester, firm, true, approval, now)
      else                     apply_kind(requester, firm, approval.param("kind_to"), approval)
      end
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Réglage « validation à deux » d'une structure (D-VAL2-001) : cabinet,
  # gestionnaire indépendant, parc sans cabinet. Réglé par l'admin de la
  # structure (le super-admin pour le parc sans cabinet), consultable par
  # le super-admin.
  class FirmApprovalModeHandler < ScreenHandler
    def get
      render_page(firm!)
    end

    def post
      firm = firm!
      raise Access::Denied.new("approval_mode") unless ApprovalMode.can_manage?(user, firm)
      mode = field("mode")
      unless Approval::MODES.includes?(mode)
        return render_page(firm, {"mode" => [I18n.t("admin.errors.invalid")]}, 422)
      end
      # Retour à une personne : une demande, validée par une autre personne
      # (D-ADM-023).
      if mode == ApprovalMode::SINGLE && ApprovalMode.mode(firm) == ApprovalMode::DUAL
        request = ApprovalMode.request_single(user, firm, field("reason"))
        return ApprovalConfirmHandler.after_firm_request(self, request.value!) if request.ok?
        return render_page(firm, translate(request.errors), 422)
      end
      outcome = ApprovalMode.set(user, firm, mode == ApprovalMode::DUAL)
      if outcome.ok?
        flash["success"] = I18n.t("admin.dual_approval.saved.#{firm.approval_mode}")
        return redirect("/firms/#{firm.pk}/approval-mode")
      end
      render_page(firm, translate(outcome.errors), 422)
    end

    private def firm! : Firm
      firm = Firm.filter(id: id_param).first
      raise Access::Denied.new("firm") if firm.nil? || !ApprovalMode.can_view?(user, firm)
      firm
    end

    private def render_page(firm : Firm, errors = {} of String => Array(String), status : Int32 = 200)
      mode = ApprovalMode.mode(firm)
      team = ApprovalMode.team(firm)
      manage = ApprovalMode.can_manage?(user, firm)
      modes = Approval::MODES.map do |code|
        {"value" => code, "key" => "admin.dual_approval.modes.#{code}", "help" => "admin.dual_approval.help.#{code}",
         "checked" => mode == code, "disabled" => !manage || (code == ApprovalMode::DUAL && team.size < 2)}
      end
      page("admin/firm_approval_mode.html", {
        "firm"        => firm,
        "is_fleet"    => firm.fleet?,
        "mode"        => mode,
        "modes"       => modes,
        "team"        => team,
        "team_size"   => team.size,
        "team_short"  => team.size < 2,
        "manage"      => manage,
        "suggested"   => ApprovalMode.suggested?(firm),
        "pending"     => ApprovalMode.pending(firm),
        "changed_at"  => firm.dual_approval_changed_at.try(&.to_s("%Y-%m-%d %H:%M")),
        "mode_errors" => errs(errors, "mode") + errs(errors, "base"),
        "reason"      => field("reason"),
      }, status: status)
    end
  end

  # Confirmation d'une demande par le demandeur seul (structure réglée sur
  # « une personne », D-VAL2-004) : ré-authentification forte récente, puis
  # confirmation explicite. Si la structure est repassée à deux personnes,
  # la page le dit et la demande attend une autre personne.
  class ApprovalConfirmHandler < ScreenHandler
    def get
      render_page(approval!)
    end

    def post
      approval = approval!
      confirmation = approval.kind == "delete" ? field("confirmation") : (field("confirm") == "yes" ? "yes" : "")
      outcome = Approvals.confirm_alone(user, approval, Auth::Sessions.recent_strong?(session_record, Config.now), confirmation)
      if outcome.ok?
        if task = outcome.value
          flash["success"] = I18n.t("admin.dual_approval.confirmed", reference: approval.reference.to_s)
          return redirect("/tasks/#{task.pk}")
        end
        flash["success"] = I18n.t("admin.firm_approvals.done", reference: approval.reference.to_s)
        # Demande de structure (D-ADM-023) : faite aussitôt.
        if code = outcome.signup_code
          flash["info"] = I18n.t("admin.users.signup_code", code: code)
        end
        return redirect(Approvals.back_path(approval))
      end
      # Demande close par un recontrôle (cible changée) : la page le dit.
      approval.reload
      render_page(approval, translate(outcome.errors), 422)
    end

    # Demande de structure enregistrée (D-ADM-023) : confirmation aussitôt
    # par le demandeur (une personne, D-VAL2-004), sinon attente d'une
    # autre personne, sur l'écran d'où vient la demande.
    def self.after_firm_request(handler : ScreenHandler, approval : Approval) : Marten::HTTP::Response
      if Approvals.can_confirm_alone?(handler.user, approval)
        handler.flash["info"] = I18n.t("admin.dual_approval.requested_single", reference: approval.reference.to_s)
        return handler.go("/approvals/#{approval.pk}/confirm")
      end
      unless held_notice(handler, approval)
        handler.flash["success"] = I18n.t("admin.approvals.requested", reference: approval.reference.to_s)
      end
      handler.go(Approvals.back_path(approval))
    end

    # Demande retenue du super-admin (D-ADM-028) : le message dit que les
    # admins de la structure sont prévenus, et l'échéance. Vrai si c'en est
    # une.
    def self.held_notice(handler : ScreenHandler, approval : Approval) : Bool
      return false unless Approvals.confirm_waiting?(handler.user, approval)
      handler.flash["info"] = I18n.t("admin.dual_approval.requested_held", reference: approval.reference.to_s,
        time: Approvals.recourse_at(approval).to_s("%Y-%m-%d %H:%M UTC"))
      true
    end

    private def approval! : Approval
      approval = Approvals.visible(user).filter(id: id_param).first
      raise Access::Denied.new("approval") if approval.nil? || approval.requested_by_id != user.pk
      approval
    end

    private def render_page(approval : Approval, errors = {} of String => Array(String), status : Int32 = 200)
      dossier = approval.dossier
      now = Config.now
      session = session_record
      strong_at = session.try(&.strong_auth_at)
      page("admin/approval_confirm.html", {
        "approval"           => approval,
        "dossier"            => dossier,
        "firm"               => approval.firm,
        "mode"               => ApprovalMode.mode(approval.target_firm!, now),
        "pending"            => approval.state == "pending" && approval.expires_at! > now,
        "can_confirm"        => Approvals.can_confirm_alone?(user, approval, now),
        "held_until"         => Approvals.confirm_waiting?(user, approval, now) ? Approvals.recourse_at(approval).to_s("%Y-%m-%d %H:%M UTC") : nil,
        "needs_admin"        => !Approvals.habilitated?(user, approval),
        "recent"             => Auth::Sessions.recent_strong?(session, now),
        "strong_at"          => strong_at.try(&.to_s("%H:%M")),
        "window"             => Config::REAUTH_WINDOW.total_minutes.to_i.to_s,
        "has_passkey"        => Passkey.filter(user_id: user.pk).exists?,
        "has_totp"           => !user.super_admin? && user.totp_enabled?,
        "is_delete"          => approval.kind == "delete",
        "confirm_path"       => "/approvals/#{approval.pk}/confirm",
        "connect_reauth"     => Connect.configured? ? "/login/connect?acr=#{Auth.required_level(user)}&fresh=1&next=#{URI.encode_www_form("/approvals/#{approval.pk}/confirm")}" : nil,
        "errors"             => errs(errors, "base") + errs(errors, "reauth"),
        "confirm_errors"     => errs(errors, "confirmation"),
        "confirmation_value" => field_or_empty("confirmation"),
      }, status: status)
    end

    private def field_or_empty(name : String) : String
      request.method == "POST" ? field(name) : ""
    end
  end

  # Ré-authentification par code TOTP (rôles au niveau 2) ; la passkey
  # passe par l'élévation (`ElevateHandler`), qui retient aussi l'heure.
  class ReauthTotpHandler < ScreenHandler
    def post
      back = safe_next(field("next"), "/")
      session = session_record
      raise Access::Denied.new("session") if session.nil?
      result = Auth.reauthenticate_totp(session, field("code"), ip, Config.now)
      if error = result.error
        flash["danger"] = I18n.t(error, seconds: result.wait.try(&.total_seconds.ceil.to_i).to_s)
      else
        flash["success"] = I18n.t("admin.reauth.done")
      end
      redirect(back)
    end
  end
end

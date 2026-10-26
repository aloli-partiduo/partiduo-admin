# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Administrateurs d'une structure (D-ADM-017) : liste, ajout par
  # invitation, remplacement, changement de rôle. Le super-admin pour toute
  # structure, l'admin de cabinet pour la sienne. Une fois l'équipe
  # constituée, chaque changement passe par une demande (D-ADM-023).
  class FirmAdminsHandler < ScreenHandler
    def get
      render_page(firm!, input(""))
    end

    def post
      firm = firm!
      raise Access::Denied.new("firm_admins") unless Administrators.can_manage_firm?(user, firm)
      value = input(field("email")).copy_with(firm_id: PartiduoAdmin.id?(firm.pk))
      replaced = field("replaces").to_i64?.try { |id| User.filter(id: id, firm_id: firm.pk).first }
      if field("replaces").empty? && Administrators.invite_gate(user, value).nil?
        outcome = Administrators.invite_firm_admin(user, firm, value)
      else
        request = if replaced
                    Administrators.request_replace(user, firm, replaced, value, field("self_confirm") == "yes", field("reason"))
                  elsif field("replaces").empty?
                    Administrators.request_invite(user, value, field("reason"))
                  else
                    Fleet::Outcome(Approval).failure("replaces", "admin.errors.administrators.unknown")
                  end
        return ApprovalConfirmHandler.after_firm_request(self, request.value!) if request.ok?
        return render_page(firm, value, translate(request.errors), 422)
      end
      if outcome.ok?
        flash["success"] = I18n.t("admin.users.invited", email: outcome.value!.email.to_s)
        if code = outcome.signup_code
          flash["info"] = I18n.t("admin.users.signup_code", code: code)
        end
        return redirect("/firms/#{firm.pk}/admins")
      end
      render_page(firm, value, translate(outcome.errors), 422)
    end

    private def input(email : String) : Directory::UserInput
      Directory::UserInput.new(email: email, first_name: field("first_name"), last_name: field("last_name"),
        role: Config::FIRM_ADMIN, locale: field("locale").presence || I18n.locale)
    end

    private def firm! : Firm
      firm = Firm.filter(id: id_param).first
      raise Access::Denied.new("firm") if firm.nil? || !Administrators.can_manage_firm?(user, firm)
      firm
    end

    private def render_page(firm : Firm, value : Directory::UserInput, errors = {} of String => Array(String),
                            status : Int32 = 200)
      admins = Administrators.firm_admins(firm)
      # Demandes en attente sur la structure (D-ADM-023) : le compte visé
      # est marqué « en attente de validation ».
      pending = ApprovalMode.pending(firm).select(&.firm_target?)
      waiting = ->(account : User) { pending.find { |approval| approval.param("user_id") == account.pk.to_s } }
      rows = admins.map do |admin|
        {"user" => admin, "is_self" => admin.pk == user.pk, "last" => Administrators.last_firm_admin?(admin),
         "demotable" => !firm.independent?, "pending" => waiting.call(admin)}
      end
      members = firm.independent? ? [] of User : Administrators.firm_members(firm)
      opt = ->(code : String, label : String, current : String) { FormField::Option.new(code, label, code == current) }
      fields = [
        FormField.new("email", I18n.t("admin.users.fields.email"), value.email, "email", errors: errs(errors, "email"), required: true),
        FormField.new("first_name", I18n.t("admin.users.fields.first_name"), value.first_name),
        FormField.new("last_name", I18n.t("admin.users.fields.last_name"), value.last_name),
        FormField.new("locale", I18n.t("admin.users.fields.locale"), value.locale, "select",
          Config::LOCALES.map { |code| opt.call(code, I18n.t("admin.languages.#{code}"), value.locale) }),
      ]
      replaceable = admins.select(&.active)
      if !replaceable.empty? && !firm.independent?
        fields << FormField.new("replaces", I18n.t("admin.administrators.fields.replaces"), field("replaces"), "select",
          [opt.call("", I18n.t("admin.administrators.no_replacement"), field("replaces"))] +
          replaceable.map { |admin| opt.call(admin.pk.to_s, admin.email.to_s, field("replaces")) },
          errs(errors, "replaces"), help: I18n.t("admin.administrators.help.firm_replaces"))
      end
      if Administrators.firm_gated?(firm)
        fields << FormField.new("reason", I18n.t("admin.firm_approvals.fields.reason"), field("reason"),
          help: I18n.t("admin.firm_approvals.help.reason"))
      end
      page("admin/firm_admins.html", {
        "firm"        => firm,
        "rows"        => rows,
        "members"     => members.map { |member| {"user" => member, "pending" => waiting.call(member)} },
        "fields"      => fields,
        "can_add"     => !(firm.independent? && !admins.empty?),
        "base_errors" => errs(errors, "base") + errs(errors, "role") + errs(errors, "firm_id") + errs(errors, "self_confirm"),
        "is_fleet"    => firm.fleet?,
        "gated"       => Administrators.firm_gated?(firm),
        "mode"        => ApprovalMode.mode(firm),
        "pending"     => pending,
        "reason"      => field("reason"),
      }, status: status)
    end
  end

  # Changement de rôle dans une structure : `demote` (admin → gestionnaire
  # de dossiers, retrait des administrateurs) ou `promote`.
  class FirmAdminCommandHandler < ScreenHandler
    def post
      firm = Firm.filter(id: id_param).first
      raise Access::Denied.new("firm") if firm.nil? || !Administrators.can_manage_firm?(user, firm)
      target = User.filter(id: id_param("user_id"), firm_id: firm.pk).first
      raise Access::Denied.new("user") if target.nil?
      role = case params["command"].to_s
             when "demote"  then Config::FILE_MANAGER
             when "promote" then Config::FIRM_ADMIN
             else                raise Access::Denied.new("command")
             end
      self_confirmed = field("self_confirm") == "yes"
      if Administrators.firm_gated?(firm)
        request = Administrators.request_role(user, firm, target, role, self_confirmed, field("reason"))
        return ApprovalConfirmHandler.after_firm_request(self, request.value!) if request.ok?
        flash["danger"] = translate(request.errors).values.flatten.join(" ")
        return go("/firms/#{firm.pk}/admins")
      end
      outcome = Administrators.set_role(user, firm, target, role, self_confirmed)
      if outcome.ok?
        flash["success"] = I18n.t("admin.saved")
      else
        flash["danger"] = translate(outcome.errors).values.flatten.join(" ")
      end
      go(user.firm_admin? && user.pk == target.pk && role != Config::FIRM_ADMIN ? "/" : "/firms/#{firm.pk}/admins")
    end
  end

  # Administrateurs d'un dossier (D-ADM-017) : ceux de l'instance, tels que
  # la console les connaît ; ajout, remplacement et retrait par une demande
  # (validation à une ou deux personnes), relecture dans l'instance.
  class DossierAdminsHandler < ScreenHandler
    def get
      render_page(dossier!)
    end

    def post
      dossier = dossier!
      outcome = Administrators.request_add(user, dossier, field("email"), field("reason"), field("replaces"),
        field("replace_removal").presence || "revoke")
      return render_page(dossier, translate(outcome.errors), 422) unless outcome.ok?
      DossierAdminsHandler.after_request(self, outcome.value!, dossier)
    end

    # Demande enregistrée : confirmation aussitôt par le demandeur habilité
    # (une personne, D-VAL2-004), sinon attente d'une autre personne.
    def self.after_request(handler : ScreenHandler, approval : Approval, dossier : Dossier) : Marten::HTTP::Response
      if Approvals.can_confirm_alone?(handler.user, approval)
        handler.flash["info"] = I18n.t("admin.dual_approval.requested_single", reference: approval.reference.to_s)
        return handler.go("/approvals/#{approval.pk}/confirm")
      end
      key = approval.mode == ApprovalMode::DUAL ? "admin.approvals.requested" : "admin.dual_approval.requested_admin"
      handler.flash["success"] = I18n.t(key, reference: approval.reference.to_s)
      handler.go("/dossiers/#{dossier.pk}/admins")
    end

    private def render_page(dossier : Dossier, errors = {} of String => Array(String), status : Int32 = 200)
      rows = Administrators.list(dossier)
      active = rows.select(&.state.==("active"))
      manage = Access.can?(user, :administrators, dossier) && dossier.state == "active"
      own = user.email.to_s.downcase
      page("admin/dossier_admins.html", {
        "dossier"       => dossier,
        "rows"          => rows.map { |row| {"admin" => row, "is_self" => row.email == own, "pending" => row.state != "active", "last" => active.size <= 1} },
        "manage"        => manage,
        "can_refresh"   => Access.can?(user, :refresh_administrators, dossier) && dossier.state == "active",
        "replaceable"   => active.map(&.email.to_s),
        "pending"       => Approval.filter(dossier_id: dossier.pk, state: "pending", kind__in: %w[admin_add admin_remove admin_invite]).order("-id").to_a,
        "tasks"         => Task.filter(dossier_id: dossier.pk, kind__in: %w[instance.admin_add instance.admin_remove instance.admins]).order("-id").to_a.first(10),
        "approval_mode" => ApprovalMode.mode_for(dossier),
        "limit"         => Administrators::LIMIT,
        "email"         => field("email"),
        "reason"        => field("reason"),
        "errors"        => errors.values.flatten.empty? ? nil : errors,
        "email_errors"  => errs(errors, "email") + errs(errors, "replaces") + errs(errors, "replace_removal"),
        "reason_errors" => errs(errors, "reason"),
        "base_errors"   => errs(errors, "base"),
      }, status: status)
    end
  end

  # Retrait (`remove`) ou relecture (`refresh`) des administrateurs d'un
  # dossier.
  class DossierAdminCommandHandler < ScreenHandler
    def post
      dossier = dossier!
      case params["command"].to_s
      when "refresh"
        outcome = Administrators.refresh(user, dossier)
        flash[outcome.ok? ? "success" : "danger"] =
          outcome.ok? ? I18n.t("admin.tasks.enqueued") : translate(outcome.errors).values.flatten.join(" ")
        go("/dossiers/#{dossier.pk}/admins")
      when "remove"
        outcome = Administrators.request_remove(user, dossier, field("email"), field("removal"), field("reason"),
          field("self_confirm") == "yes")
        return DossierAdminsHandler.after_request(self, outcome.value!, dossier) if outcome.ok?
        flash["danger"] = translate(outcome.errors).values.flatten.join(" ")
        go("/dossiers/#{dossier.pk}/admins")
      else
        raise Access::Denied.new("command")
      end
    end
  end
end

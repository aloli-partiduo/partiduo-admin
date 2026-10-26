# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Ligne de la liste des opérations sensibles. Un objet plutôt qu'un
  # `Hash` : au-delà de huit clés, la recherche d'une clé d'un `Hash` par le
  # moteur de gabarits de Marten échoue (index par empreinte, clé `Value`).
  class ApprovalRow
    include Marten::Template::Object::Auto

    getter approval : Approval
    getter can_decide : Bool
    getter can_validate : Bool
    getter recourse : Bool
    getter recourse_at : String?
    getter can_withdraw : Bool
    getter can_confirm : Bool
    getter firm_link : String?
    getter is_transfer : Bool
    getter can_consent : Bool
    getter dossier_link : Bool

    def initialize(@approval, *, @can_decide, @can_validate, @recourse, @recourse_at, @can_withdraw, @can_confirm,
                   @firm_link, @is_transfer, @can_consent, @dossier_link)
    end
  end

  class ApprovalsHandler < ScreenHandler
    def get
      approvals = Approvals.visible(user).order("-id").to_a.first(100)
      now = Config.now
      rows = approvals.map { |approval| row(approval, now) }
      page("admin/approvals.html", {"rows" => rows, "recourse_hours" => Config.recourse_delay.total_hours.to_i.to_s})
    end

    # Gestes ouverts à l'utilisateur sur une demande.
    private def row(approval : Approval, now : Time) : ApprovalRow
      pending = approval.state == "pending" && approval.expires_at! > now
      decide = pending && Access.can_approve?(user, approval)
      transfer = approval.transfer?
      # Dernier recours du super-admin (D-ADM-024) : avant l'heure, elle
      # est montrée à la place du bouton « Valider ».
      waiting = decide && Approvals.recourse_waiting?(user, approval, now)
      ApprovalRow.new(approval, can_decide: decide, can_validate: decide && !waiting && !transfer,
        recourse: decide && !waiting && Approvals.recourse?(user, approval),
        recourse_at: waiting ? Approvals.recourse_at(approval).to_s("%Y-%m-%d %H:%M UTC") : nil,
        can_withdraw: pending && approval.requested_by_id == user.pk,
        can_confirm: pending && Approvals.can_confirm_alone?(user, approval),
        firm_link: firm_link(approval), is_transfer: transfer,
        can_consent: transfer && Transfers.can_consent?(user, approval, now),
        dossier_link: dossier_link?(approval))
    end

    # Le dossier d'une demande s'ouvre-t-il à l'utilisateur ? (L'admin de la
    # structure d'accueil d'un transfert ne le voit pas encore.)
    private def dossier_link?(approval : Approval) : Bool
      dossier = approval.dossier
      !dossier.nil? && Access.in_scope?(user, dossier)
    end

    # Demande de structure (D-ADM-023) : lien vers l'écran de ses admins ou
    # de son réglage, si l'utilisateur peut l'ouvrir.
    private def firm_link(approval : Approval) : String?
      firm = approval.firm
      return if firm.nil?
      case approval.kind
      when "mode_single"
        ApprovalMode.can_view?(user, firm) ? "/firms/#{firm.pk}/approval-mode" : nil
      when "backup_weaken"
        BackupEncryption.can_manage?(user, firm) ? "/firms/#{firm.pk}/backups" : nil
      when .in?(Approval::STRUCTURE_KINDS)
        Firms.can_manage?(user) ? "/firms/#{firm.pk}/settings" : nil
      else
        Administrators.can_manage_firm?(user, firm) ? "/firms/#{firm.pk}/admins" : nil
      end
    end
  end

  # Transfert d'un dossier vers une autre structure (D-ADM-027) : suivi des
  # accords des deux structures, et accord d'une personne habilitée de
  # l'une d'elles (ré-authentification forte récente, case cochée).
  class TransferHandler < ScreenHandler
    def get
      render_page(approval!)
    end

    def post
      approval = approval!
      outcome = Transfers.consent(user, approval, Auth::Sessions.recent_strong?(session_record, Config.now),
        field("confirm") == "yes" ? "yes" : "")
      if outcome.ok?
        flash["success"] = I18n.t(outcome.value ? "admin.transfers.done" : "admin.transfers.consented",
          reference: approval.reference.to_s)
        return redirect("/approvals/#{approval.pk}/transfer")
      end
      approval.reload
      render_page(approval, translate(outcome.errors), 422)
    end

    private def approval! : Approval
      approval = Approvals.visible(user).filter(id: id_param, kind: Approval::TRANSFER).first
      raise Access::Denied.new("approval") if approval.nil?
      approval
    end

    private def render_page(approval : Approval, errors = {} of String => Array(String), status : Int32 = 200)
      now = Config.now
      session = session_record
      mine = Transfers.side_of(user, approval)
      sides = Transfers::SIDES.map do |side|
        firm = Transfers.side_firm(approval, side)
        consents = ApprovalConsent.filter(approval_id: approval.pk, side: side).order("id").to_a
        # Noms des personnes : pour sa propre structure et le super-admin.
        names = mine == side || user.super_admin? ? consents.compact_map(&.user.try(&.email.to_s)).join(", ") : ""
        {"key" => "admin.transfers.sides.#{side}", "firm" => firm.try(&.name.to_s) || "",
         "mode" => firm ? ApprovalMode.mode(firm, now) : ApprovalMode::SINGLE,
         "needed" => (firm ? Transfers.needed(firm, now) : 1).to_s, "given" => consents.size.to_s,
         "names" => names.presence, "mine" => mine == side}
      end
      dossier = approval.dossier!
      confirm_path = "/approvals/#{approval.pk}/transfer"
      page("admin/transfer.html", {
        "approval"        => approval,
        "dossier"         => dossier,
        "dossier_link"    => Access.in_scope?(user, dossier),
        "sides"           => sides,
        "pending"         => approval.state == "pending" && approval.expires_at! > now,
        "can_consent"     => Transfers.can_consent?(user, approval, now),
        "can_reject"      => approval.state == "pending" && Transfers.can_reject?(user, approval),
        "is_requester"    => approval.requested_by_id == user.pk,
        "encryption_from" => "admin.encryption.modes.#{approval.param("encryption_from")}",
        "encryption_to"   => "admin.encryption.modes.#{approval.param("encryption_to")}",
        "recent"          => Auth::Sessions.recent_strong?(session, now),
        "strong_at"       => session.try(&.strong_auth_at).try(&.to_s("%H:%M")),
        "window"          => Config::REAUTH_WINDOW.total_minutes.to_i.to_s,
        "has_passkey"     => Passkey.filter(user_id: user.pk).exists?,
        "has_totp"        => !user.super_admin? && user.totp_enabled?,
        "confirm_path"    => confirm_path,
        "connect_reauth"  => Connect.configured? ? "/login/connect?acr=#{Auth.required_level(user)}&fresh=1&next=#{URI.encode_www_form(confirm_path)}" : nil,
        "errors"          => errs(errors, "base") + errs(errors, "reauth") + errs(errors, "firm_id") + errs(errors, "payer_id") + errs(errors, "dossier_id"),
        "confirm_errors"  => errs(errors, "confirmation"),
      }, status: status)
    end
  end

  class ApprovalDecisionHandler < ScreenHandler
    def post
      approval = Approvals.visible(user).filter(id: id_param).first
      raise Access::Denied.new("approval") if approval.nil?
      if params["decision"].to_s == "approve"
        outcome = Approvals.approve(user, approval)
        if outcome.ok?
          flash["success"] = I18n.t(approval.firm_target? ? "admin.firm_approvals.approved" : "admin.approvals.approved")
          if code = outcome.signup_code
            flash["info"] = I18n.t("admin.users.signup_code", code: code)
          end
        else
          flash["danger"] = outcome.errors.values.flatten.map { |key| I18n.t(key) }.join(" ")
        end
      else
        raise Access::Denied.new("approval") unless Approvals.reject(user, approval)
        flash["success"] = I18n.t("admin.approvals.rejected")
      end
      go("/approvals")
    end
  end

  class TasksHandler < ScreenHandler
    # Une valeur de filtre par colonne, 50 tâches par page (TaskFilter).
    def get
      filter = TaskFilter.from_query { |name| query(name) }
      paginator = filter.apply(Access.tasks(user)).order("-id").paginator(TaskFilter::PAGE_SIZE)
      current = paginator.page(query("page").to_i? || 1)
      page("admin/tasks.html", {
        "tasks"    => current.to_a,
        "filter"   => filter,
        "kinds"    => kinds(filter.kind),
        "states"   => Protocol::STATES.map { |code| {"code" => code, "key" => "admin.tasks.states.#{code}", "selected" => code == filter.state} },
        "number"   => current.number,
        "pages"    => current.pages_count,
        "total"    => current.total_count,
        "previous" => current.previous_page? ? filter.url(current.number - 1) : "",
        "next"     => current.next_page? ? filter.url(current.number + 1) : "",
        "first"    => current.number > 2 ? filter.url(1) : "",
        "last"     => current.number < current.pages_count - 1 ? filter.url(current.pages_count) : "",
      })
    end

    private def kinds(selected : String)
      without = {"code" => TaskFilter::WITHOUT_SUPERVISION, "key" => "admin.tasks.filters.without_supervision",
                 "selected" => selected == TaskFilter::WITHOUT_SUPERVISION}
      [without] + Protocol::KINDS.map do |code|
        {"code" => code, "key" => "admin.tasks.kinds.#{code.tr(".", "_")}", "selected" => code == selected}
      end
    end
  end

  # Détail d'une tâche et son journal ; rafraîchi par HTMX tant qu'elle
  # n'est pas terminée.
  class TaskHandler < ScreenHandler
    def get
      task = Access.tasks(user).filter(id: id_param).first
      raise Access::Denied.new("task") if task.nil?
      # Rafraîchissement HTMX d'une tâche qui vient de se terminer : page
      # entière rechargée une fois, pour l'état final et le bouton « Relancer ».
      if htmx? && task.finished
        response = Marten::HTTP::Response.new("", status: 200)
        response.headers["HX-Refresh"] = "true"
        return response
      end
      template = htmx? ? "admin/_task_body.html" : "admin/task.html"
      # Code de création du compte connect (ADR-012 D6), à transmettre de
      # vive voix à l'administrateur du dossier : mis en évidence. Vide quand
      # l'administrateur a déjà un compte connect : rien à afficher.
      signup_code = (JSON.parse(task.result.presence || "{}")["signup_code"]?.try(&.as_s?).presence rescue nil)
      page(template, {"task" => task, "result" => task.result.presence || "{}", "signup_code" => signup_code,
                      "can_retry" => Tasks.retryable?(task) && !user.file_manager?, "can_cancel" => task.state == "pending" && !user.file_manager?})
    end
  end

  class TaskCommandHandler < ScreenHandler
    def post
      require_admin!
      task = Access.tasks(user).filter(id: id_param).first
      raise Access::Denied.new("task") if task.nil?
      done = params["command"].to_s == "retry" ? Tasks.retry(user, task) : Tasks.cancel(user, task)
      # Pas de « Enregistré » vert : la relance n'est qu'une mise en file ; le
      # bandeau d'état de la page (_task_body) suit la tâche jusqu'à son issue.
      flash["danger"] = I18n.t("admin.errors.task.state") unless done
      go("/tasks/#{task.pk}")
    end
  end

  class AlertsHandler < ScreenHandler
    def get
      page("admin/alerts.html", {"alerts" => Alerts.visible(user).order("-opened_at").to_a, "quota" => LetsEncrypt.usage(Config.now),
                                 "can_close" => !user.file_manager?})
    end
  end

  # Alerte close à la main (« pris en compte ») : la supervision la rouvre
  # si la cause persiste ; geste inscrit au journal d'audit.
  class AlertCloseHandler < ScreenHandler
    def post
      require_admin!
      alert = Alerts.visible(user).filter(id: id_param).first
      raise Access::Denied.new("alert") if alert.nil?
      Alerts.close(user, alert)
      flash["info"] = I18n.t("admin.alerts.closed")
      go("/alerts")
    end
  end

  class AuditHandler < ScreenHandler
    def get
      raise Access::Denied.new("audit") unless Access.can_view_audit?(user)
      scope = Access.audit(user).order("-id")
      action = query("action").strip
      scope = scope.filter(action__startswith: action) unless action.empty?
      page("admin/audit.html", {"entries" => scope.to_a.first(300), "action" => action})
    end
  end

  class ServersHandler < ScreenHandler
    def get
      require_fleet!
      page("admin/servers.html", {"servers" => Server.all.order("name").to_a, "name" => "", "hostname" => "",
                                  "domain" => Config.domain})
    end

    def post
      require_fleet!
      outcome = Directory.create_server(user, field("name"), field("hostname"), field("domain"))
      if outcome.ok?
        server, token = outcome.value!
        return page("admin/server_token.html", {"server" => server, "token" => token})
      end
      page("admin/servers.html", {"servers" => Server.all.order("name").to_a, "name" => field("name"),
                                  "hostname" => field("hostname"), "domain" => field("domain"), "errors" => translate(outcome.errors)}, status: 422)
    end
  end

  class ServerRotateHandler < ScreenHandler
    def post
      require_fleet!
      server = Server.get!(id: id_param)
      token = Directory.rotate_token(user, server) || raise Access::Denied.new("server")
      page("admin/server_token.html", {"server" => server, "token" => token})
    end
  end
end

module PartiduoAdmin
  # Clé de signature des sauvegardes d'un serveur (D-CHF-018) : déclarée
  # par le super-admin (`ssh-ed25519 …`, celle que beryl a posée), ou
  # révoquée.
  class ServerSigningKeyHandler < ScreenHandler
    def post
      require_fleet!
      server = Server.get!(id: id_param)
      outcome = BackupEncryption.add_signing_key(user, server, field("public_key"))
      if outcome.ok?
        flash["success"] = I18n.t("admin.servers.signing_key_added", fingerprint: outcome.value!.fingerprint.to_s)
      else
        flash["danger"] = outcome.errors.values.flatten.map { |key| I18n.t(key) }.join(" ")
      end
      go("/servers")
    end
  end

  class ServerSigningKeyRevokeHandler < ScreenHandler
    def post
      require_fleet!
      key = SigningKey.filter(id: id_param("key_id"), server_id: id_param).first
      raise Access::Denied.new("signing_key") if key.nil?
      done = BackupEncryption.revoke_signing_key(user, key)
      flash[done ? "success" : "danger"] = I18n.t(done ? "admin.saved" : "admin.errors.invalid")
      go("/servers")
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  class ApprovalsHandler < ScreenHandler
    def get
      approvals = Approvals.visible(user).order("-id").to_a.first(100)
      rows = approvals.map do |approval|
        pending = approval.state == "pending"
        {"approval" => approval, "can_decide" => pending && Access.can_approve?(user, approval),
         "can_withdraw" => pending && approval.requested_by_id == user.pk,
         "can_confirm" => pending && Approvals.can_confirm_alone?(user, approval)}
      end
      page("admin/approvals.html", {"rows" => rows})
    end
  end

  class ApprovalDecisionHandler < ScreenHandler
    def post
      approval = Approvals.visible(user).filter(id: id_param).first
      raise Access::Denied.new("approval") if approval.nil?
      if params["decision"].to_s == "approve"
        outcome = Approvals.approve(user, approval)
        if outcome.ok?
          flash["success"] = I18n.t("admin.approvals.approved")
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
      page(template, {"task" => task, "result" => task.result.presence || "{}",
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
      page("admin/alerts.html", {"alerts" => Alerts.visible(user).order("-opened_at").to_a, "quota" => LetsEncrypt.usage(Config.now)})
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

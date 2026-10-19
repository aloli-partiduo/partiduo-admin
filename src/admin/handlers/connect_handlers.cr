# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Connexion par connect (ADR-012 D4) : départ, retour, déconnexion par
  # canal arrière, invitation qui lie un compte connect.
  class ConnectLoginHandler < BaseHandler
    CONNECT_COOKIE    = "partiduo_admin_connect"
    NEXT_COOKIE       = "partiduo_admin_connect_next"
    INVITATION_COOKIE = "partiduo_admin_invitation"

    def get
      return redirect("/login") unless Connect.configured?
      acr = query("acr").to_i? || Auth::TWO_FACTOR
      url, handle = Connect.begin(acr.clamp(Auth::PASSWORD, Auth::PASSKEY), query("fresh") == "1", query("login_hint"), Config.now)
      expires = Time.utc + Config::CHALLENGE_TIMEOUT
      request.cookies.set(CONNECT_COOKIE, handle, expires: expires, http_only: true, secure: secure_cookies?, same_site: "Lax")
      request.cookies.set(NEXT_COOKIE, safe_next(query("next")), expires: expires, http_only: true, secure: secure_cookies?,
        same_site: "Lax")
      redirect(url)
    end
  end

  # Retour de connect : la session de l'administration s'ouvre au niveau
  # attesté ; un niveau insuffisant pour le rôle repart chez connect avec le
  # niveau exigé.
  class ConnectCallbackHandler < BaseHandler
    def get
      handle = request.cookies[ConnectLoginHandler::CONNECT_COOKIE]?
      next_path = safe_next(request.cookies[ConnectLoginHandler::NEXT_COOKIE]?.to_s)
      invitation = request.cookies[ConnectLoginHandler::INVITATION_COOKIE]?
      request.cookies.delete(ConnectLoginHandler::CONNECT_COOKIE)
      identity = Connect.complete(handle, {"code" => query("code"), "state" => query("state"), "error" => query("error")},
        Config.now)
      outcome = Auth::ConnectLogin.login(identity, invitation, ip, user_agent, Config.now)
      if level = outcome.step_up
        flash["warning"] = I18n.t("admin.account.elevation_needed")
        return redirect("/login/connect?acr=#{level}&next=#{URI.encode_www_form(next_path)}")
      end
      if opened = outcome.opened
        request.cookies.delete(ConnectLoginHandler::INVITATION_COOKIE) if invitation
        request.cookies.delete(ConnectLoginHandler::NEXT_COOKIE)
        session_record.try { |previous| Auth::Sessions.revoke(previous) }
        open_session(opened)
        return redirect(next_path)
      end
      flash["danger"] = I18n.t(outcome.error || "admin.errors.login.invalid")
      redirect("/login")
    rescue error : Connect::Error
      flash["danger"] = I18n.t(error.key)
      redirect("/login")
    end
  end

  # Déconnexion par canal arrière (ADR-012 D8) : sans cookie ni jeton CSRF,
  # le jeton signé par connect fait foi.
  class ConnectBackchannelHandler < Marten::Handlers::Base
    protect_from_forgery false

    def post
      token = request.data.fetch("logout_token", "").to_s
      closed = Auth::ConnectLogin.backchannel_logout(token, Config.now)
      response = Marten::HTTP::Response.new(content: "", status: closed.nil? ? 400 : 200)
      response.headers["Cache-Control"] = "no-store"
      response
    end
  end

  # Invitation acceptée par connect (ADR-012 D6) : gardée dans un cookie le
  # temps de la connexion, liée au retour si l'adresse vérifiée par connect
  # est celle de l'invité.
  class InvitationConnectHandler < BaseHandler
    def get
      raw = params["token"].to_s
      invited = Auth::Invitations.peek(raw, Config.now)
      return page("admin/invitation.html", {"invalid" => true}, status: 404) if invited.nil? || !Connect.configured?
      request.cookies.set(ConnectLoginHandler::INVITATION_COOKIE, raw, expires: Time.utc + 15.minutes, http_only: true,
        secure: secure_cookies?, same_site: "Lax")
      redirect("/login/connect?login_hint=#{URI.encode_www_form(invited.email.to_s)}&next=%2Faccount")
    end
  end
end

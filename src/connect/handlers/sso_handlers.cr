# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoConnect
  # Connexion par le fournisseur d'identité du cabinet (ADR-012 D9).
  class SsoStartHandler < BaseHandler
    SSO_COOKIE  = "partiduo_connect_sso"
    NEXT_COOKIE = "partiduo_connect_sso_next"

    def post
      email = field("email").downcase
      upstream = Sso.for_email(email)
      next_path = safe_next(field("next"))
      if upstream.nil?
        return page("connect/login.html", {"next" => next_path, "email" => email, "client" => client_for_next(next_path),
                                           "error" => I18n.t("connect.errors.sso.none")}, status: 422)
      end
      url, handle = Sso.begin(upstream, email, Config.now)
      expires = Time.utc + Config::CHALLENGE_TIMEOUT
      request.cookies.set(SSO_COOKIE, handle, expires: expires, http_only: true, secure: secure_cookies?, same_site: "Lax")
      request.cookies.set(NEXT_COOKIE, next_path, expires: expires, http_only: true, secure: secure_cookies?, same_site: "Lax")
      redirect(url)
    end
  end

  class SsoCallbackHandler < BaseHandler
    def get
      upstream = Upstream.filter(code: params["code"].to_s, active: true).first
      raise Denied.new("upstream") if upstream.nil?
      handle = request.cookies[SsoStartHandler::SSO_COOKIE]?
      next_path = safe_next(request.cookies[SsoStartHandler::NEXT_COOKIE]?.to_s)
      request.cookies.delete(SsoStartHandler::SSO_COOKIE)
      request.cookies.delete(SsoStartHandler::NEXT_COOKIE)
      identity = Sso.complete(upstream, handle, {"code" => query("code"), "state" => query("state"), "error" => query("error")},
        Config.now)
      # Sans authentification à plusieurs facteurs attestée par le cabinet,
      # aucun dossier n'accepterait la session : le dire ici.
      if identity.level < Auth::REQUIRED
        return error_page(403, "connect.errors.sso.no_mfa")
      end
      opened, return_to = Sso.login(upstream, identity, ip, user_agent, Config.now)
      open_session(opened)
      return redirect(return_to) if !return_to.empty? && next_path == "/account"
      redirect(after_login(next_path))
    rescue error : Sso::Error
      flash["danger"] = I18n.t(error.key)
      redirect("/login")
    end
  end

  # Déconnexion annoncée par le fournisseur du cabinet (désactivation d'un
  # collaborateur, fin de sa session) : sans cookie ni jeton CSRF.
  class SsoBackchannelHandler < ApiHandler
    def post
      upstream = Upstream.filter(code: params["code"].to_s, active: true).first
      closed = upstream ? Sso.backchannel_logout(upstream, form["logout_token"]? || "", Config.now) : nil
      no_store(Marten::HTTP::Response.new(content: "", status: closed.nil? ? 400 : 200))
    end
  end
end

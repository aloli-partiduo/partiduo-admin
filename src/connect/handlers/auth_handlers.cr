# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoConnect
  class HomeHandler < BaseHandler
    def get
      redirect(account? ? "/account" : "/login")
    end
  end

  # Connexion : passkey d'abord (niveau 3), mot de passe puis code TOTP ou
  # code de récupération (niveau 2).
  class LoginHandler < BaseHandler
    def get
      next_path = safe_next(query("next"))
      page("connect/login.html", {"next" => next_path, "email" => query("login_hint"),
                                  "client" => client_for_next(next_path)})
    end

    def post
      result = Auth.login_password(field("email"), request.data.fetch("password", "").to_s, ip, user_agent, Config.now)
      if handle = result.pending
        request.cookies.set(PENDING_COOKIE, handle, expires: Time.utc + Config::PENDING_LIFETIME, http_only: true,
          secure: secure_cookies?, same_site: "Strict")
        return redirect("/login/second-factor?next=#{URI.encode_www_form(safe_next(field("next")))}")
      end
      if opened = result.opened
        open_session(opened)
        return redirect(after_login(field("next")))
      end
      error = I18n.t(result.error || "connect.errors.login.invalid", seconds: result.wait.try(&.total_seconds.ceil.to_i).to_s)
      next_path = safe_next(field("next"))
      page("connect/login.html", {"next" => next_path, "email" => field("email"), "error" => error,
                                  "client" => client_for_next(next_path)}, status: 422)
    end
  end

  class SecondFactorHandler < BaseHandler
    def get
      return redirect("/login") if request.cookies[PENDING_COOKIE]?.nil?
      page("connect/second_factor.html", {"next" => safe_next(query("next"))})
    end

    def post
      result = Auth.login_second_factor(request.cookies[PENDING_COOKIE]?, field("code"), ip, user_agent, Config.now)
      if opened = result.opened
        request.cookies.delete(PENDING_COOKIE)
        open_session(opened)
        if opened.session.method == "recovery_code"
          flash["warning"] = I18n.t("connect.login.recovery_used")
        end
        return redirect(after_login(field("next")))
      end
      if result.error == "connect.errors.login.expired"
        flash["warning"] = I18n.t("connect.errors.login.expired")
        return redirect("/login")
      end
      error = I18n.t(result.error || "connect.errors.login.invalid", seconds: result.wait.try(&.total_seconds.ceil.to_i).to_s)
      page("connect/second_factor.html", {"next" => safe_next(field("next")), "error" => error}, status: 422)
    end
  end

  # Options WebAuthn d'une connexion par passkey (credential découvrable).
  class PasskeyLoginOptionsHandler < BaseHandler
    def post
      options, _ = Auth::Passkeys.authentication_options
      json(options)
    end
  end

  class PasskeyLoginHandler < BaseHandler
    def post
      found = Auth::Passkeys.finish_authentication(field("challenge_id"), field("credential_id"),
        field("authenticator_data"), field("client_data_json"), field("signature"), now: Config.now)
      return json({"ok" => false, "error" => I18n.t("connect.errors.login.invalid")}.to_json) unless found.can_sign_in?
      Auth::Throttle.record_success(found)
      opened = Auth::Sessions.open(found, Auth::PASSKEY, "passkey", ip, user_agent, Config.now)
      Audit.log(found, "auth.login", {"level" => Auth::PASSKEY.to_s, "method" => "passkey"}, ip: ip)
      open_session(opened)
      json({"ok" => true, "redirect" => after_login(field("next"))}.to_json)
    rescue error : Auth::Passkeys::Error
      json({"ok" => false, "error" => I18n.t(error.key)}.to_json, status: 422)
    end
  end

  # Déconnexion (point `end_session_endpoint`) : confirmation, fermeture de
  # la session, avis aux clients (déconnexion unique, ADR-012 D8), puis
  # retour au client s'il a donné une adresse admise.
  class LogoutHandler < BaseHandler
    def get
      return finish if account?.nil?
      page("connect/logout.html", {"params" => logout_params})
    end

    def post
      if session = session_record
        Auth::Sessions.revoke(session, Config.now)
        Audit.log(session.account, "auth.logout", ip: ip)
      end
      request.cookies.delete(COOKIE, same_site: "Lax")
      request.connect_session = nil
      finish
    end

    private def finish : Marten::HTTP::Response
      params = logout_params
      target = params["post_logout_redirect_uri"]? || ""
      client = logout_client(params)
      if client && !target.empty? && client.post_logout_redirect_uri_allowed?(target)
        state = params["state"]? || ""
        return redirect(Oidc.append(target, {"state" => state}))
      end
      page("connect/logged_out.html")
    end

    # Paramètres de la demande, en requête ou en formulaire (champs
    # cachés de la confirmation).
    private def logout_params : Hash(String, String)
      params = query_hash
      %w[post_logout_redirect_uri state client_id id_token_hint].each do |key|
        value = field(key)
        params[key] = value unless value.empty?
      end
      params
    end

    private def logout_client(params : Hash(String, String)) : Client?
      client_id = params["client_id"]?.presence
      if client_id.nil? && (hint = params["id_token_hint"]?.presence)
        client_id = SigningKeys.verify(hint).try(&.["aud"]?).try(&.as_s?)
      end
      client_id ? Client.filter(client_id: client_id, active: true).first : nil
    end
  end

  class LanguageHandler < BaseHandler
    def post
      locale = field("locale")
      if Config::LOCALES.includes?(locale)
        request.cookies.set(LOCALE_COOKIE, locale, expires: Time.utc + 365.days, same_site: "Lax", secure: secure_cookies?)
        if current = account?
          current.locale = locale
          current.save!
        end
      end
      redirect(safe_next(field("next"), "/login"))
    end
  end

  # Création d'un compte (ADR-012 D6) : lien reçu par courriel *et* code
  # transmis par un autre canal ; la session ouverte est une session
  # d'enrôlement, qui mène à la page du compte.
  class SignupHandler < BaseHandler
    def get
      ticket = Signup.find(params["token"].to_s, Config.now)
      return page("connect/signup.html", {"invalid" => true}, status: 404) if ticket.nil?
      page("connect/signup.html", {"ticket" => ticket, "token" => params["token"].to_s, "name" => ticket.display_name})
    end

    def post
      token = params["token"].to_s
      outcome = Signup.redeem(token, field("code"), field("name"), ip, Config.now)
      if created = outcome.account
        opened = Auth::Sessions.open(created, Auth::ENROLLMENT, "signup", ip, user_agent, Config.now,
          return_to: outcome.return_to)
        open_session(opened)
        return redirect("/account")
      end
      error = I18n.t(outcome.error || "connect.errors.signup.invalid")
      ticket = Signup.find(token, Config.now)
      return page("connect/signup.html", {"invalid" => true, "error" => error}, status: 422) if ticket.nil?
      page("connect/signup.html", {"ticket" => ticket, "token" => token, "name" => field("name"), "error" => error},
        status: 422)
    end
  end
end

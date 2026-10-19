# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoConnect
  # Page du compte (ADR-012 D1) : moyens d'authentification, codes de
  # récupération, adresse, journal. Sert aussi à l'enrôlement (session de
  # niveau 0 ou 1 d'un compte inachevé).
  abstract class AccountScreenHandler < SignedInHandler
    # Ajouter un facteur : session complète, ou compte encore inachevé
    # (enrôlement). Un compte complet ouvert par son seul mot de passe ne
    # peut pas s'ajouter de facteur.
    def can_enroll? : Bool
      elevated? || !Auth.complete?(account)
    end

    def require_enroll! : Nil
      raise Denied.new("enroll") unless can_enroll?
    end

    # Facteur qui achève l'enrôlement : la session prend le niveau du
    # facteur (la confiance vient du lien et du code de l'invitation, ou de
    # la session complète).
    def complete_enrollment(level : Int32, method : String) : Nil
      if session = session_record
        Auth::Sessions.raise_level(session, level, method, Config.now)
      end
    end

    def codes_page(codes : Array(String)) : Marten::HTTP::Response
      page("connect/recovery_codes.html", {"codes" => codes, "host" => Config.host, "next" => continue_target})
    end

    # Suite après l'enrôlement : `next` (une demande `/authorize`), sinon le
    # retour vers le dossier qui a invité la personne.
    def continue_target : String?
      next_path = query("next").presence || field("next").presence
      return safe_next(next_path) if next_path && next_path.starts_with?('/')
      session_record.try(&.return_to).presence
    end
  end

  class AccountHandler < AccountScreenHandler
    def get
      current = account
      secret = current.totp_pending_secret
      complete = Auth.complete?(current)
      page("connect/account.html", {
        "account"       => current,
        "level"         => level,
        "complete"      => complete,
        "can_enroll"    => can_enroll?,
        "missing"       => Auth.missing(current).map { |item| "connect.account.missing_items.#{item}" },
        "passkeys"      => Passkey.filter(account_id: current.pk).order("created_at").to_a,
        "recovery_left" => Auth::RecoveryCodes.remaining(current),
        # `nil` et non "" : une chaîne vide est vraie dans un gabarit Marten.
        "totp_secret" => secret,
        "totp_uri"    => secret ? Auth::Totp.provisioning_uri(current, secret) : nil,
        "journal"     => elevated? ? Audit.for(current) : nil,
        "next"        => complete && elevated? ? continue_target : nil,
        "next_field"  => query("next").presence,
        "next_query"  => query("next").presence.try { |value| "?next=#{URI.encode_www_form(value)}" },
      })
    end
  end

  # Suite après l'enrôlement : vers la demande `/authorize` en cours ou le
  # dossier qui a invité la personne.
  class ContinueHandler < AccountScreenHandler
    def post
      require_elevated!
      target = continue_target
      if session = session_record
        session.return_to = ""
        session.save!
      end
      return redirect("/account") if target.nil?
      redirect(target)
    end
  end

  class AccountProfileHandler < AccountScreenHandler
    def post
      require_elevated!
      current = account
      current.display_name = field("display_name")[0, 200]? || ""
      current.save!
      Audit.log(current, "account.profile", ip: ip)
      flash["success"] = I18n.t("connect.account.saved")
      redirect("/account")
    end
  end

  # Mot de passe : choix à l'enrôlement, changement en session complète.
  class AccountPasswordHandler < AccountScreenHandler
    def post
      current = account
      require_enroll!
      password = request.data.fetch("password", "").to_s
      errors = Auth::Passwords.errors(password, current)
      errors << "connect.errors.password.mismatch" if password != request.data.fetch("confirmation", "").to_s
      unless errors.empty?
        flash["danger"] = errors.map { |key| I18n.t(key) }.join(" ")
        return redirect("/account#password")
      end
      first = !current.usable_password?
      current.password_digest = Auth::Passwords.hash(password)
      current.password_changed_at = Config.now
      current.save!
      Audit.log(current, "account.password", ip: ip)
      Mailer.notify(current, "password_changed", ip: ip) unless first
      flash["success"] = I18n.t("connect.account.password_saved")
      redirect("/account#totp")
    end
  end

  class AccountTotpHandler < AccountScreenHandler
    def post
      current = account
      require_enroll!
      if field("command") == "begin"
        Auth::Totp.begin(current)
        return redirect("/account#totp")
      end
      was_complete = Auth.complete?(current)
      if Auth::Totp.confirm(current, field("code").gsub(/\s/, ""), Config.now)
        codes = Auth::RecoveryCodes.ensure(current)
        complete_enrollment(Auth::TWO_FACTOR, "totp") if current.usable_password? && !was_complete
        Audit.log(current, "account.totp", ip: ip)
        Mailer.notify(current, "totp_enabled", ip: ip) if was_complete
        return codes_page(codes) unless codes.empty?
        flash["success"] = I18n.t("connect.account.totp_enabled")
      else
        flash["danger"] = I18n.t("connect.errors.login.code")
      end
      redirect("/account#totp")
    end
  end

  class RecoveryCodesHandler < AccountScreenHandler
    def post
      require_elevated!
      codes = Auth::RecoveryCodes.generate(account)
      Audit.log(account, "account.recovery_codes", ip: ip)
      Mailer.notify(account, "recovery_regenerated", ip: ip)
      codes_page(codes)
    end
  end

  class PasskeyRegisterOptionsHandler < AccountScreenHandler
    def post
      require_enroll!
      options, _ = Auth::Passkeys.registration_options(account)
      json(options)
    end
  end

  class PasskeyRegisterHandler < AccountScreenHandler
    def post
      current = account
      require_enroll!
      was_complete = Auth.complete?(current)
      Auth::Passkeys.finish_registration(current, field("challenge_id"), field("attestation_object"),
        field("client_data_json"), field("name"))
      codes = Auth::RecoveryCodes.ensure(current)
      complete_enrollment(Auth::PASSKEY, "passkey") unless was_complete
      Audit.log(current, "account.passkey", ip: ip)
      Mailer.notify(current, "passkey_added", ip: ip) if was_complete
      flash["success"] = I18n.t("connect.account.passkey_added")
      back = query("next").presence.try { |value| "/account?next=#{URI.encode_www_form(safe_next(value))}" } || "/account"
      return json({"ok" => true, "redirect" => back}.to_json) if codes.empty?
      # Premiers codes de récupération : montrés tout de suite, une seule
      # fois ; `passkey.js` remplace le contenu de la page.
      html = Marten.templates.get_template("connect/_recovery_codes.html")
        .render({"codes" => codes, "host" => Config.host, "next" => continue_target})
      json({"ok" => true, "html" => html}.to_json)
    rescue error : Auth::Passkeys::Error
      json({"ok" => false, "error" => I18n.t(error.key)}.to_json, status: 422)
    end
  end

  # Retrait d'une passkey (appareil perdu) : jamais la dernière si le compte
  # deviendrait inachevé.
  class PasskeyDeleteHandler < AccountScreenHandler
    def post
      current = account
      require_elevated!
      passkey = Passkey.filter(id: params["id"].to_s.to_i64, account_id: current.pk).first
      raise Denied.new("passkey") if passkey.nil?
      others = Passkey.filter(account_id: current.pk).exclude(id: passkey.pk).exists?
      unless others || (current.usable_password? && current.totp_enabled?)
        flash["danger"] = I18n.t("connect.account.passkey_last")
        return redirect("/account")
      end
      passkey.delete
      Audit.log(current, "account.passkey_removed", {"name" => passkey.name.to_s}, ip: ip)
      Mailer.notify(current, "passkey_removed", ip: ip)
      flash["success"] = I18n.t("connect.account.passkey_removed")
      redirect("/account")
    end
  end

  # Élévation par passkey de la session courante (niveau 3).
  class ElevateOptionsHandler < SignedInHandler
    def post
      options, _ = Auth::Passkeys.authentication_options(account)
      json(options)
    end
  end

  class ElevateHandler < SignedInHandler
    def post
      Auth::Passkeys.finish_authentication(field("challenge_id"), field("credential_id"), field("authenticator_data"),
        field("client_data_json"), field("signature"), expected_account: account, now: Config.now)
      if session = session_record
        Auth::Sessions.mark_strong(session, Auth::PASSKEY, "passkey", Config.now)
      end
      Audit.log(account, "auth.elevate", ip: ip)
      json({"ok" => true, "redirect" => safe_next(field("next"))}.to_json)
    rescue error : Auth::Passkeys::Error
      json({"ok" => false, "error" => I18n.t(error.key)}.to_json, status: 422)
    end
  end

  # Niveau plus haut exigé par un client (`acr_values`) : élévation par
  # passkey, ou ajout d'une passkey depuis la page du compte.
  class StepUpHandler < SignedInHandler
    def get
      required = query("acr").to_i? || Auth::PASSKEY
      next_path = safe_next(query("next"))
      return redirect(next_path) if level >= required
      return redirect("/account?next=#{URI.encode_www_form(next_path)}") unless elevated?
      page("connect/step_up.html", {"next" => next_path, "has_passkey" => Auth.has_passkey?(account),
                                    "client" => client_for_next(next_path),
                                    "account_url" => "/account?next=#{URI.encode_www_form(next_path)}"})
    end
  end

  # Changement d'adresse : demande (lien envoyé à la nouvelle adresse),
  # puis confirmation par ce lien dans une session complète.
  class AccountEmailHandler < AccountScreenHandler
    def post
      require_elevated!
      if error = EmailChanges.request(account, field("email"), Config.now)
        flash["danger"] = I18n.t(error)
      else
        flash["success"] = I18n.t("connect.account.email_sent", email: field("email").downcase)
      end
      redirect("/account#email")
    end
  end

  class AccountEmailConfirmHandler < AccountScreenHandler
    def get
      require_elevated!
      page("connect/email_confirm.html", {"token" => params["token"].to_s})
    end

    def post
      require_elevated!
      if error = EmailChanges.confirm(account, params["token"].to_s, ip, Config.now)
        flash["danger"] = I18n.t(error)
      else
        flash["success"] = I18n.t("connect.account.email_changed")
      end
      redirect("/account")
    end
  end
end

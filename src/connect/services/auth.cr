# SPDX-License-Identifier: AGPL-3.0-or-later

# Seul le hachage d'authn : `require "authn"` charge `jwt`, dont
# `openssl_ext` entre en conflit avec `jose` (partiduo-app, B-AUTH-002).
require "authn/password"
require "totp"

module PartiduoConnect
  # Authentification d'un compte (ADR-002, ADR-012 D1), sur les shards
  # maison : `password-policy` et `authn` (mot de passe), `totp`, `webauthn`
  # (voir `Passkeys`).
  module Auth
    ENROLLMENT = 0
    PASSWORD   = 1
    TWO_FACTOR = 2
    PASSKEY    = 3

    # Niveau exigé pour gérer son compte chez `connect`.
    REQUIRED = TWO_FACTOR

    # Compte complet (ADR-002 D7) : une passkey, ou un mot de passe avec un
    # TOTP ; et des codes de récupération dès qu'un facteur existe.
    def self.complete?(account : Account) : Bool
      # Compte authentifié par le fournisseur d'un cabinet (ADR-012 D9) : ses
      # facteurs sont ceux du cabinet.
      return true if account.upstream?
      has_passkey?(account) || (account.usable_password? && account.totp_enabled?)
    end

    def self.has_passkey?(account : Account) : Bool
      Passkey.filter(account_id: account.pk).exists?
    end

    # Ce qui manque : `factor` (ni passkey, ni mot de passe + TOTP),
    # `recovery_codes`.
    def self.missing(account : Account) : Array(String)
      missing = [] of String
      return missing if account.upstream?
      missing << "factor" unless complete?(account)
      if (has_passkey?(account) || account.totp_enabled?) && RecoveryCodes.remaining(account).zero?
        missing << "recovery_codes"
      end
      missing
    end

    # Méthodes d'authentification publiées (`amr`, RFC 8176).
    def self.amr(method : String) : Array(String)
      case method
      when "passkey"       then ["hwk", "user", "mfa"]
      when "totp"          then ["pwd", "otp", "mfa"]
      when "recovery_code" then ["pwd", "mfa"]
      when "password"      then ["pwd"]
      else                      [] of String
      end
    end

    module Passwords
      @@decoy : String?

      # Clés `connect.errors.password.<motif>` (motifs de `PasswordPolicy`).
      def self.errors(password : String, account : Account? = nil) : Array(String)
        errors = Config.password_policy.validate(password).map do |violation|
          "connect.errors.password.#{violation.to_s.underscore}"
        end
        if account
          words = [account.email.to_s.split('@').first? || ""] + account.display_name.to_s.split(/\s+/)
          lowered = password.downcase
          if words.select { |word| word.size >= 4 }.any? { |word| lowered.includes?(word.downcase) }
            errors << "connect.errors.password.personal"
          end
        end
        errors
      end

      def self.hash(password : String) : String
        Authn::Password.hash(password, cost: Config.bcrypt_cost, policy: Config.password_policy)
      end

      # Vérification en temps constant, même pour une adresse inconnue.
      def self.verify(account : Account?, password : String) : Bool
        digest = account.try(&.password_digest)
        if account.nil? || digest.nil?
          Authn::Password.verify(password, decoy)
          return false
        end
        Authn::Password.verify(password, digest)
      end

      private def self.decoy : String
        @@decoy ||= Authn::Password.hash(Secrets.token, cost: Config.bcrypt_cost)
      end
    end

    # TOTP (RFC 6238 : SHA-1, 6 chiffres, 30 s), anti-rejeu par le compteur
    # accepté, enregistré par une mise à jour conditionnelle.
    module Totp
      def self.authenticator(secret : String) : TOTP::Authenticator
        TOTP::Authenticator.from_base32(secret)
      end

      def self.begin(account : Account) : String
        secret = TOTP.generate_secret_base32
        account.totp_pending_secret = secret
        account.save!
        secret
      end

      def self.provisioning_uri(account : Account, secret : String) : String
        authenticator(secret).provisioning_uri(account: account.email.to_s, issuer: Config::ISSUER_NAME)
      end

      def self.confirm(account : Account, code : String, now : Time = Time.utc) : Bool
        secret = account.totp_pending_secret
        return false if secret.nil?
        counter = authenticator(secret).verify(code, time: now)
        return false if counter.nil?
        account.totp_secret = secret
        account.totp_pending_secret = nil
        account.totp_enabled_at = now
        account.last_otp_counter = counter.to_i64
        account.save!
        true
      end

      def self.verify!(account : Account, code : String, now : Time = Time.utc) : Bool
        secret = account.totp_secret
        return false if secret.nil? || !account.totp_enabled?
        after = account.last_otp_counter.try(&.to_u64)
        counter = authenticator(secret).verify(code, time: now, after: after)
        return false if counter.nil?
        value = counter.to_i64
        claimed = Account.filter(id: account.pk, totp_secret: secret)
          .filter { q(last_otp_counter__isnull: true) | q(last_otp_counter__lt: value) }
          .update(last_otp_counter: value)
        return false unless claimed == 1
        account.last_otp_counter = value
        true
      end
    end

    # Codes de récupération (ADR-002 D7) : 16 caractères, empreinte SHA-256.
    # Un seul jeu par personne, quel que soit le nombre de dossiers.
    module RecoveryCodes
      def self.remaining(account : Account) : Int32
        RecoveryCode.filter(account_id: account.pk, used_at__isnull: true).count.to_i32
      end

      def self.generate(account : Account) : Array(String)
        RecoveryCode.filter(account_id: account.pk).delete
        Array.new(Config::RECOVERY_CODES) do
          code = Secrets.readable_code(16)
          RecoveryCode.create!(account: account, code_digest: Secrets.digest(Secrets.normalize_code(code)))
          code
        end
      end

      def self.ensure(account : Account) : Array(String)
        remaining(account).zero? ? generate(account) : [] of String
      end

      def self.consume!(account : Account, code : String, now : Time = Time.utc) : Bool
        RecoveryCode.filter(account_id: account.pk, code_digest: Secrets.digest(Secrets.normalize_code(code)),
          used_at__isnull: true).update(used_at: now) == 1
      end
    end

    # Limitation des tentatives (ADR-002, CNIL 2022-100) : réservation
    # atomique avant l'examen du secret, temporisation croissante à partir du
    # 3ᵉ échec, blocage au 10ᵉ (même mécanisme que l'administration).
    module Throttle
      record Reservation, granted : Bool, locked : Bool = false, wait : Time::Span? = nil,
        reserved_at : Time? = nil, previous_failed_at : Time? = nil

      RESERVE_SQL = <<-SQL
        WITH previous AS (
          SELECT id, last_failed_at FROM connect_account WHERE id = $1 FOR UPDATE
        )
        UPDATE connect_account AS target
           SET failed_attempts = target.failed_attempts + 1,
               last_failed_at = $2
          FROM previous
         WHERE target.id = previous.id
           AND target.locked_at IS NULL
           AND (target.failed_attempts < $3
                OR target.last_failed_at IS NULL
                OR target.last_failed_at
                   + make_interval(secs => LEAST($4 * power(2, LEAST(target.failed_attempts - $3, 20)), $5))
                   <= $2)
        RETURNING target.failed_attempts, previous.last_failed_at
        SQL

      CONFIRM_SQL = <<-SQL
        UPDATE connect_account
           SET locked_at = CASE WHEN failed_attempts >= $3 AND locked_at IS NULL THEN $2 ELSE locked_at END
         WHERE id = $1
        SQL

      RELEASE_SQL = <<-SQL
        UPDATE connect_account
           SET failed_attempts = GREATEST(failed_attempts - 1, 0),
               last_failed_at = CASE WHEN last_failed_at = $2 THEN $3 ELSE last_failed_at END
         WHERE id = $1 AND failed_attempts > 0
        SQL

      def self.delay_for(failures : Int32) : Time::Span
        return Time::Span.zero if failures < Config::THROTTLE_AFTER
        delay = Config::THROTTLE_BASE * (2 ** (failures - Config::THROTTLE_AFTER).clamp(0, 20))
        delay > Config::THROTTLE_MAXIMUM ? Config::THROTTLE_MAXIMUM : delay
      end

      def self.reserve(account : Account, now : Time = Time.utc) : Reservation
        now = now.at_beginning_of_second + (now.nanosecond // 1000).microseconds
        row = Marten::DB::Connection.default.open do |db|
          db.query_one?(RESERVE_SQL, account.pk!.as(Int64), now, Config::THROTTLE_AFTER,
            Config::THROTTLE_BASE.total_seconds.to_i, Config::THROTTLE_MAXIMUM.total_seconds.to_i,
            as: {Int32, Time?})
        end
        if row
          account.failed_attempts = row[0]
          account.last_failed_at = now
          return Reservation.new(granted: true, reserved_at: now, previous_failed_at: row[1])
        end
        account.reload
        return Reservation.new(granted: false, locked: true) if account.locked?
        failures = (account.failed_attempts || 0).to_i32
        wait = (account.last_failed_at || now) + delay_for(failures) - now
        Reservation.new(granted: false, wait: wait > Time::Span.zero ? wait : 1.second)
      end

      def self.confirm_failure(account : Account, now : Time = Time.utc) : Nil
        Marten::DB::Connection.default.open do |db|
          db.exec(CONFIRM_SQL, account.pk!.as(Int64), now, Config::LOCK_AFTER)
        end
        account.reload
      end

      def self.release(account : Account, reservation : Reservation) : Nil
        reserved_at = reservation.reserved_at
        return unless reservation.granted && reserved_at
        Marten::DB::Connection.default.open do |db|
          db.exec(RELEASE_SQL, account.pk!.as(Int64), reserved_at, reservation.previous_failed_at)
        end
        account.reload
      end

      def self.record_success(account : Account) : Nil
        Account.filter(id: account.pk).update(failed_attempts: 0, last_failed_at: nil)
        account.failed_attempts = 0
        account.last_failed_at = nil
      end

      def self.unlock(account : Account) : Nil
        Account.filter(id: account.pk).update(failed_attempts: 0, last_failed_at: nil, locked_at: nil)
        account.reload
      end
    end

    # Défis à usage unique : le client tient une poignée, la base son
    # empreinte ; la consommation marque la ligne dans la même instruction.
    module Challenges
      record Issued, challenge : Challenge, handle : String

      def self.issue(purpose : String, account : Account? = nil, value : String = "",
                     ttl : Time::Span = Config::CHALLENGE_TIMEOUT, now : Time = Time.utc) : Issued
        Challenge.filter(expires_at__lt: now - 1.day).delete if Random.rand(50).zero?
        handle = Secrets.token
        challenge = Challenge.create!(purpose: purpose, handle_digest: Secrets.digest(handle), value: value,
          account: account, expires_at: now + ttl)
        Issued.new(challenge, handle)
      end

      def self.consume(purpose : String, handle : String?, now : Time = Time.utc) : Challenge?
        return if handle.nil? || handle.empty?
        digest = Secrets.digest(handle)
        claimed = Challenge.filter(handle_digest: digest, purpose: purpose, used_at__isnull: true, expires_at__gt: now)
          .update(used_at: now)
        claimed == 1 ? Challenge.get(handle_digest: digest) : nil
      end

      def self.peek(purpose : String, handle : String?, now : Time = Time.utc) : Challenge?
        return if handle.nil? || handle.empty?
        Challenge.filter(handle_digest: Secrets.digest(handle), purpose: purpose, used_at__isnull: true,
          expires_at__gt: now).first
      end
    end

    module Sessions
      record Opened, session : Session, token : String

      def self.open(account : Account, level : Int32, method : String, ip : String = "", user_agent : String = "",
                    now : Time = Time.utc, return_to : String = "") : Opened
        token = Secrets.token
        session = Session.create!(account: account, token_digest: Secrets.digest(token), sid: Secrets.token(24),
          level: level, method: method, ip: ip[0, 64]? || "", user_agent: user_agent[0, 255]? || "",
          return_to: return_to[0, 1000]? || "", auth_time: now, last_seen_at: now,
          expires_at: now + Config::SESSION_LIFETIME, strong_auth_at: level >= REQUIRED ? now : nil)
        if level > ENROLLMENT
          account.last_login_at = now
          account.save!
        end
        Opened.new(session, token)
      end

      def self.find(token : String?, now : Time = Time.utc) : Session?
        return if token.nil? || token.empty?
        session = Session.filter(token_digest: Secrets.digest(token)).first
        return if session.nil? || !session.revoked_at.nil?
        return if session.expires_at! < now || session.last_seen_at! + Config::IDLE_TIMEOUT < now
        account = session.account
        return if account.nil? || !account.can_sign_in?
        if session.last_seen_at! + 1.minute < now
          session.last_seen_at = now
          session.save!
        end
        session
      end

      def self.raise_level(session : Session, level : Int32, method : String, now : Time = Time.utc) : Nil
        return if (session.level || 0) >= level
        session.level = level
        session.method = method
        session.auth_time = now
        session.strong_auth_at = now if level >= REQUIRED
        session.save!
      end

      # Authentification forte à l'instant (élévation, ré-authentification).
      def self.mark_strong(session : Session, level : Int32, method : String, now : Time = Time.utc) : Nil
        if (session.level || 0) < level
          session.level = level
          session.method = method
        end
        session.auth_time = now
        session.strong_auth_at = now
        session.save!
      end

      def self.recent_strong?(session : Session?, now : Time = Time.utc) : Bool
        return false if session.nil? || (session.level || 0) < REQUIRED
        at = session.strong_auth_at
        !at.nil? && at > now - Config::REAUTH_WINDOW && at <= now + 1.minute
      end

      # Fermeture d'une session, et avis aux clients qu'elle avait ouverts
      # (déconnexion unique, ADR-012 D8).
      def self.revoke(session : Session, now : Time = Time.utc) : Nil
        return unless session.revoked_at.nil?
        session.revoked_at = now
        session.save!
        Backchannel.logout(session, now)
      end

      def self.revoke_all(account : Account, now : Time = Time.utc, except : Int64? = nil) : Nil
        sessions = Session.filter(account_id: account.pk, revoked_at__isnull: true)
        sessions = sessions.exclude(id: except) if except
        sessions.to_a.each { |session| revoke(session, now) }
      end
    end

    # Ré-authentification par code TOTP d'une session ouverte.
    def self.reauthenticate_totp(session : Session, code : String, ip : String = "", now : Time = Time.utc) : LoginResult
      account = session.account
      return LoginResult.new(error: "connect.errors.login.expired") if account.nil? || !account.can_sign_in?
      return LoginResult.new(error: "connect.errors.reauth.no_totp") unless account.totp_enabled?
      reservation = Throttle.reserve(account, now)
      unless reservation.granted
        return LoginResult.new(error: reservation.locked ? "connect.errors.login.locked" : "connect.errors.login.wait",
          wait: reservation.wait)
      end
      cleaned = code.gsub(/\s/, "")
      unless cleaned.matches?(/\A\d{6}\z/) && Totp.verify!(account, cleaned, now)
        Throttle.confirm_failure(account, now)
        Audit.log(account, "auth.reauth", {"method" => "totp"}, outcome: "fail", ip: ip)
        return LoginResult.new(error: account.locked? ? "connect.errors.login.locked" : "connect.errors.login.code")
      end
      Throttle.record_success(account)
      Sessions.mark_strong(session, TWO_FACTOR, "totp", now)
      Audit.log(account, "auth.reauth", {"method" => "totp"}, ip: ip)
      LoginResult.new
    end

    # Connexion par mot de passe, puis second facteur. Renvoie une clé
    # d'erreur, une session ouverte, ou un second facteur attendu.
    record LoginResult, error : String? = nil, opened : Sessions::Opened? = nil,
      pending : String? = nil, wait : Time::Span? = nil

    PURPOSE_PENDING = "second_factor"

    def self.login_password(email : String, password : String, ip : String = "", user_agent : String = "",
                            now : Time = Time.utc) : LoginResult
      address = email.strip.downcase
      # Adresse d'un cabinet qui a son fournisseur d'identité (ADR-012 D9) :
      # la connexion passe par lui, jamais par un mot de passe ici.
      return LoginResult.new(error: "connect.errors.login.use_sso") if Sso.for_email(address)
      account = Account.filter(email: address).first
      if account.nil? || !account.can_sign_in?
        Passwords.verify(nil, password)
        Audit.log(nil, "auth.login", {"reason" => "unknown"}, outcome: "fail", ip: ip, label: address)
        return LoginResult.new(error: "connect.errors.login.invalid")
      end
      reservation = Throttle.reserve(account, now)
      unless reservation.granted
        key = reservation.locked ? "connect.errors.login.locked" : "connect.errors.login.wait"
        return LoginResult.new(error: key, wait: reservation.wait)
      end
      unless Passwords.verify(account, password)
        Throttle.confirm_failure(account, now)
        Audit.log(account, "auth.login", {"reason" => "password"}, outcome: "fail", ip: ip)
        return LoginResult.new(error: account.locked? ? "connect.errors.login.locked" : "connect.errors.login.invalid")
      end
      if account.totp_enabled?
        Throttle.release(account, reservation)
        issued = Challenges.issue(PURPOSE_PENDING, account: account, ttl: Config::PENDING_LIFETIME, now: now)
        return LoginResult.new(pending: issued.handle)
      end
      # Mot de passe seul : compte inachevé, session d'enrôlement (niveau 1)
      # qui mène à la page du compte.
      Throttle.record_success(account)
      Audit.log(account, "auth.login", {"level" => PASSWORD.to_s}, ip: ip)
      LoginResult.new(opened: Sessions.open(account, PASSWORD, "password", ip, user_agent, now))
    end

    # Second facteur : code TOTP ou code de récupération. Un code de
    # récupération ferme les autres sessions du compte et prévient la
    # personne (ADR-012 D7, D8).
    def self.login_second_factor(handle : String?, code : String, ip : String = "", user_agent : String = "",
                                 now : Time = Time.utc) : LoginResult
      challenge = Challenges.peek(PURPOSE_PENDING, handle, now)
      account = challenge.try(&.account)
      return LoginResult.new(error: "connect.errors.login.expired") if challenge.nil? || account.nil? || !account.can_sign_in?
      reservation = Throttle.reserve(account, now)
      unless reservation.granted
        key = reservation.locked ? "connect.errors.login.locked" : "connect.errors.login.wait"
        return LoginResult.new(error: key, wait: reservation.wait)
      end
      method = second_factor(account, code, now)
      if method.nil?
        Throttle.confirm_failure(account, now)
        Audit.log(account, "auth.second_factor", outcome: "fail", ip: ip)
        return LoginResult.new(error: account.locked? ? "connect.errors.login.locked" : "connect.errors.login.code")
      end
      # Poignée consommée une seule fois : de deux requêtes concurrentes, une
      # seule ouvre une session.
      if Challenges.consume(PURPOSE_PENDING, handle, now).nil?
        return LoginResult.new(error: "connect.errors.login.expired")
      end
      Throttle.record_success(account)
      Audit.log(account, "auth.login", {"level" => TWO_FACTOR.to_s, "method" => method}, ip: ip)
      opened = Sessions.open(account, TWO_FACTOR, method, ip, user_agent, now)
      if method == "recovery_code"
        Sessions.revoke_all(account, now, except: opened.session.pk.as?(Int64))
        Mailer.notify(account, "recovery_used", ip: ip)
      end
      LoginResult.new(opened: opened)
    end

    # Moyen accepté : `totp` (six chiffres) ou `recovery_code`, sinon `nil`.
    private def self.second_factor(account : Account, code : String, now : Time) : String?
      cleaned = code.strip
      digits = cleaned.gsub(/\s/, "")
      if digits.matches?(/\A\d{6}\z/)
        Totp.verify!(account, digits, now) ? "totp" : nil
      elsif RecoveryCodes.consume!(account, cleaned, now)
        "recovery_code"
      end
    end

    # Clé d'accès perdue (ADR-002 D7) : adresse et code de récupération, sans
    # mot de passe — un compte à passkey seule n'en a pas. Mêmes paliers
    # d'échecs que la connexion. Réussi : session de niveau 2 (permet
    # d'enregistrer une nouvelle passkey), autres sessions fermées, personne
    # prévenue.
    def self.recover_with_code(email : String, code : String, ip : String = "", user_agent : String = "",
                               now : Time = Time.utc) : LoginResult
      address = email.strip.downcase
      account = Account.filter(email: address).first
      if account.nil? || !account.can_sign_in? || account.upstream?
        Audit.log(nil, "auth.recovery", {"reason" => "unknown"}, outcome: "fail", ip: ip, label: address)
        return LoginResult.new(error: "connect.errors.recovery.invalid")
      end
      reservation = Throttle.reserve(account, now)
      unless reservation.granted
        key = reservation.locked ? "connect.errors.login.locked" : "connect.errors.login.wait"
        return LoginResult.new(error: key, wait: reservation.wait)
      end
      unless RecoveryCodes.consume!(account, code, now)
        Throttle.confirm_failure(account, now)
        Audit.log(account, "auth.recovery", outcome: "fail", ip: ip)
        return LoginResult.new(error: account.locked? ? "connect.errors.login.locked" : "connect.errors.recovery.invalid")
      end
      Throttle.record_success(account)
      opened = Sessions.open(account, TWO_FACTOR, "recovery_code", ip, user_agent, now)
      Sessions.revoke_all(account, now, except: opened.session.pk.as?(Int64))
      Audit.log(account, "auth.recovery", {"remaining" => RecoveryCodes.remaining(account).to_s}, ip: ip)
      Mailer.notify(account, "recovery_used", ip: ip)
      LoginResult.new(opened: opened)
    end

    # Suspension par l'exploitation : sessions fermées, clients avisés.
    def self.suspend(account : Account, now : Time = Time.utc) : Nil
      account.active = false
      account.save!
      Sessions.revoke_all(account, now)
      Audit.log(account, "account.suspend")
    end

    def self.reactivate(account : Account) : Nil
      account.active = true
      account.save!
      Throttle.unlock(account)
      Audit.log(account, "account.reactivate")
    end
  end
end

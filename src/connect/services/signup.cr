# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoConnect
  # Création d'un compte (ADR-012 D6) : un dossier, l'administration ou
  # l'exploitation demande une invitation pour une adresse. Elle rend un
  # *lien* (remis par courriel par le demandeur) et un *code* court, montré
  # à celui qui invite, qui le transmet par un autre canal (de vive voix, par
  # téléphone). Les deux sont nécessaires : un courriel intercepté ne suffit
  # pas à créer le compte. `SIGNUP_ATTEMPTS` codes faux annulent
  # l'invitation.
  module Signup
    record Issued, ticket : SignupTicket, token : String, code : String do
      def url : String
        "#{Config.base_url}/signup/#{token}"
      end
    end

    record Outcome, account : Account? = nil, error : String? = nil, return_to : String = ""

    class Error < Exception
      getter key : String

      def initialize(@key : String)
        super(key)
      end
    end

    # Nouvelle invitation ; les précédentes pour la même adresse sont
    # annulées. Refusée si un compte existe déjà (`connect.errors.signup.exists`).
    def self.issue(email : String, display_name : String = "", locale : String = "fr", client : Client? = nil,
                   return_to : String = "", created_by : String = "", now : Time = Time.utc) : Issued
      address = email.strip.downcase
      raise Error.new("connect.errors.signup.email") unless address.matches?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
      raise Error.new("connect.errors.signup.exists") if Account.filter(email: address).exists?
      if !return_to.empty? && (client.nil? || !client.origin_allowed?(return_to))
        raise Error.new("connect.errors.signup.return_to")
      end
      SignupTicket.filter(email: address, used_at__isnull: true, cancelled_at__isnull: true).update(cancelled_at: now)
      token = Secrets.token
      code = Secrets.readable_code(8)
      ticket = SignupTicket.create!(token_digest: Secrets.digest(token),
        code_digest: Secrets.digest(Secrets.normalize_code(code)), email: address,
        display_name: display_name.strip[0, 200]? || "",
        locale: Config::LOCALES.includes?(locale) ? locale : "fr", client: client, return_to: return_to,
        created_by: created_by[0, 255]? || "", expires_at: now + Config::SIGNUP_TTL)
      Audit.log(nil, "signup.issue", {"by" => created_by}, client: client, label: address)
      Issued.new(ticket, token, code)
    end

    # Récupération par l'exploitation (clé d'accès et codes perdus) : retire
    # tous les facteurs du compte, ferme ses sessions (clients avisés), puis
    # émet un lien et un code comme une invitation ; le compte rouvert garde
    # son `sub`. Geste grave : journalisé, la personne est prévenue.
    def self.recover(account : Account, created_by : String = "exploitation", now : Time = Time.utc) : Issued
      Passkey.filter(account_id: account.pk).delete
      RecoveryCode.filter(account_id: account.pk).delete
      account.password_digest = nil
      account.totp_secret = nil
      account.totp_pending_secret = nil
      account.totp_enabled_at = nil
      account.last_otp_counter = nil
      account.save!
      Auth::Throttle.unlock(account)
      Auth::Sessions.revoke_all(account, now)
      SignupTicket.filter(email: account.email, used_at__isnull: true, cancelled_at__isnull: true).update(cancelled_at: now)
      token = Secrets.token
      code = Secrets.readable_code(8)
      ticket = SignupTicket.create!(token_digest: Secrets.digest(token),
        code_digest: Secrets.digest(Secrets.normalize_code(code)), email: account.email.to_s,
        display_name: account.display_name.to_s, locale: account.locale.to_s, account: account,
        created_by: created_by[0, 255]? || "", expires_at: now + Config::SIGNUP_TTL)
      Audit.log(account, "account.recover_issue", {"by" => created_by})
      Mailer.notify(account, "recovery_issued")
      Issued.new(ticket, token, code)
    end

    def self.find(token : String?, now : Time = Time.utc) : SignupTicket?
      return if token.nil? || token.empty?
      SignupTicket.filter(token_digest: Secrets.digest(token), used_at__isnull: true, cancelled_at__isnull: true,
        expires_at__gt: now).first
    end

    # Crée le compte si le code est bon. Chaque essai faux est compté ;
    # au-delà de `SIGNUP_ATTEMPTS`, l'invitation est annulée.
    def self.redeem(token : String?, code : String, display_name : String, ip : String = "",
                    now : Time = Time.utc) : Outcome
      ticket = find(token, now)
      return Outcome.new(error: "connect.errors.signup.invalid") if ticket.nil?
      # Essai compté avant l'examen du code (deux essais simultanés ne
      # passent pas sous la limite).
      counted = SignupTicket.filter(id: ticket.pk, attempts__lt: Config::SIGNUP_ATTEMPTS, used_at__isnull: true,
        cancelled_at__isnull: true).update(attempts: (ticket.attempts || 0) + 1)
      return Outcome.new(error: "connect.errors.signup.invalid") unless counted == 1
      unless Secrets.equal?(Secrets.digest(Secrets.normalize_code(code)), ticket.code_digest.to_s)
        ticket.reload
        if (ticket.attempts || 0) >= Config::SIGNUP_ATTEMPTS
          ticket.cancelled_at = now
          ticket.save!
          Audit.log(nil, "signup.cancelled", {"reason" => "attempts"}, outcome: "fail", ip: ip, label: ticket.email.to_s)
          return Outcome.new(error: "connect.errors.signup.cancelled")
        end
        Audit.log(nil, "signup.code", outcome: "fail", ip: ip, label: ticket.email.to_s)
        return Outcome.new(error: "connect.errors.signup.code")
      end
      claimed = SignupTicket.filter(id: ticket.pk, used_at__isnull: true, cancelled_at__isnull: true).update(used_at: now)
      return Outcome.new(error: "connect.errors.signup.invalid") unless claimed == 1
      # Récupération par l'exploitation : le compte existant rouvert, même
      # `sub` (ses liens avec les dossiers et l'administration restent).
      if recovered = ticket.account
        return Outcome.new(error: "connect.errors.signup.invalid") unless recovered.active
        Audit.log(recovered, "account.recover", {"by" => ticket.created_by.to_s}, ip: ip)
        return Outcome.new(account: recovered, return_to: ticket.return_to.to_s)
      end
      address = ticket.email.to_s
      return Outcome.new(error: "connect.errors.signup.exists") if Account.filter(email: address).exists?
      account = Account.create!(sub: Secrets.token(24), email: address,
        display_name: display_name.strip.presence.try(&.[0, 200]?) || ticket.display_name.to_s,
        locale: ticket.locale.to_s)
      Audit.log(account, "signup.redeem", ip: ip)
      Outcome.new(account: account, return_to: ticket.return_to.to_s)
    end
  end

  # Changement d'adresse (ADR-012 D8) : lien envoyé à la nouvelle adresse,
  # avis à l'ancienne. Le lien entre un compte et les dossiers reste le
  # `sub` ; l'adresse nouvelle est publiée aux clients dès la connexion
  # suivante.
  module EmailChanges
    def self.request(account : Account, new_email : String, now : Time = Time.utc) : String?
      address = new_email.strip.downcase
      return "connect.errors.email.invalid" unless address.matches?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
      return "connect.errors.email.same" if address == account.email.to_s
      return "connect.errors.email.taken" if Account.filter(email: address).exists?
      EmailChange.filter(account_id: account.pk, used_at__isnull: true).update(used_at: now)
      token = Secrets.token
      EmailChange.create!(account: account, token_digest: Secrets.digest(token), new_email: address,
        expires_at: now + Config::EMAIL_CHANGE_TTL)
      Mailer.email_change(account, address, "#{Config.base_url}/account/email/#{token}")
      Audit.log(account, "account.email_request", {"new" => address})
      nil
    end

    def self.confirm(account : Account, token : String, ip : String = "", now : Time = Time.utc) : String?
      digest = Secrets.digest(token)
      claimed = EmailChange.filter(token_digest: digest, account_id: account.pk, used_at__isnull: true,
        expires_at__gt: now).update(used_at: now)
      return "connect.errors.email.link" unless claimed == 1
      change = EmailChange.get!(token_digest: digest)
      address = change.new_email.to_s
      return "connect.errors.email.taken" if Account.filter(email: address).exists?
      previous = account.email.to_s
      account.email = address
      account.save!
      Audit.log(account, "account.email", {"old" => previous, "new" => address}, ip: ip)
      Mailer.notify(account, "email_changed", ip: ip, address: previous)
      nil
    end
  end

  # Clients OpenID Connect : déclarés par l'exploitation (commande
  # `client`), jamais par eux-mêmes.
  module Clients
    record Registered, client : Client, secret : String

    def self.register(name : String, redirect_uris : Array(String), post_logout_redirect_uris = [] of String,
                      backchannel_logout_uri : String = "", client_id : String? = nil) : Registered
      redirect_uris.each { |uri| check_uri!(uri) }
      post_logout_redirect_uris.each { |uri| check_uri!(uri) }
      check_uri!(backchannel_logout_uri) unless backchannel_logout_uri.empty?
      secret = Secrets.token
      client = Client.create!(client_id: client_id.presence || Secrets.token(16), name: name,
        secret_digest: Secrets.digest(secret), redirect_uris: redirect_uris.join("\n"),
        post_logout_redirect_uris: post_logout_redirect_uris.join("\n"), backchannel_logout_uri: backchannel_logout_uri)
      Audit.log(nil, "client.register", {"name" => name}, client: client, label: "exploitation")
      Registered.new(client, secret)
    end

    def self.rotate_secret(client : Client) : String
      secret = Secrets.token
      client.secret_digest = Secrets.digest(secret)
      client.save!
      Audit.log(nil, "client.rotate_secret", client: client, label: "exploitation")
      secret
    end

    # Adresse absolue, en https (http seulement vers `*.localhost`), sans
    # fragment.
    def self.check_uri!(uri : String) : Nil
      parsed = URI.parse(uri)
      host = parsed.host.to_s
      ok = !host.empty? && parsed.fragment.nil? &&
           (parsed.scheme == "https" || (parsed.scheme == "http" && (host == "localhost" || host.ends_with?(".localhost") || host == "127.0.0.1")))
      raise ArgumentError.new("Adresse refusée : #{uri} (https absolu, sans fragment)") unless ok
    rescue URI::Error
      raise ArgumentError.new("Adresse invalide : #{uri}")
    end
  end

  # Registraires (ADR-012) : un jeton par serveur d'hébergement, remis à son
  # exécutant ; il déclare le client de chaque dossier qu'il crée.
  module Registrars
    record Created, registrar : Registrar, token : String

    # Adresses d'un dossier, fixées ici et non par le registraire : retour
    # de connexion, page de connexion après déconnexion, déconnexion par
    # canal arrière (routes de partiduo-ui-bulma).
    CALLBACK    = "/login/federated/connect/callback"
    AFTER       = "/login"
    BACKCHANNEL = "/login/federated/connect/backchannel-logout"

    def self.create(name : String) : Created
      token = Secrets.token
      registrar = Registrar.create!(name: name, token_digest: Secrets.digest(token))
      Audit.log(nil, "registrar.create", {"name" => name}, label: "exploitation")
      Created.new(registrar, token)
    end

    def self.authenticate(authorization : String?, now : Time = Time.utc) : Registrar?
      token = authorization.try { |value| value.starts_with?("Bearer ") ? value[7..].strip : nil }
      return if token.nil? || token.empty?
      registrar = Registrar.filter(token_digest: Secrets.digest(token), active: true).first
      return if registrar.nil?
      registrar.last_used_at = now
      registrar.save!
      registrar
    end

    # Nom d'hôte d'un dossier : un seul nom sous le domaine du parc.
    def self.dossier_host?(host : String) : Bool
      suffix = ".#{Config.domain}"
      return false unless host.ends_with?(suffix)
      label = host[0, host.size - suffix.size]
      label.matches?(/\A[a-z][a-z0-9-]{0,39}\z/) && !%w[admin connect www].includes?(label)
    end

    def self.base_url(host : String) : String
      host.ends_with?(".localhost") ? "http://#{host}:8000" : "https://#{host}"
    end

    # Déclare (ou redéclare : nouveau secret) le client du dossier `host`.
    # Un client déclaré par l'exploitation ou par un autre registraire n'est
    # jamais repris.
    def self.register(registrar : Registrar, host : String) : Clients::Registered
      raise ArgumentError.new("nom de dossier refusé : #{host}") unless dossier_host?(host)
      base = base_url(host)
      existing = Client.filter(client_id: host).first
      if existing
        raise ArgumentError.new("client déjà déclaré par un autre : #{host}") unless existing.registrar == registrar.name
        existing.active = true
        existing.save!
        secret = Clients.rotate_secret(existing)
        Audit.log(nil, "client.reregister", {"registrar" => registrar.name.to_s}, client: existing, label: registrar.name.to_s)
        return Clients::Registered.new(existing, secret)
      end
      registered = Clients.register(host, ["#{base}#{CALLBACK}"], ["#{base}#{AFTER}"], "#{base}#{BACKCHANNEL}", client_id: host)
      registered.client.registrar = registrar.name.to_s
      registered.client.save!
      registered
    end

    # Dossier supprimé : son client est désactivé (gardé pour le journal).
    def self.disable(registrar : Registrar, host : String) : Bool
      client = Client.filter(client_id: host, registrar: registrar.name).first
      return false if client.nil?
      client.active = false
      client.save!
      Audit.log(nil, "client.disable", {"registrar" => registrar.name.to_s}, client: client, label: registrar.name.to_s)
      true
    end
  end
end

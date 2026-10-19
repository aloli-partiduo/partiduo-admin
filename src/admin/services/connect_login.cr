# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  module Auth
    # Connexion par connect (ADR-012 D4).
    module ConnectLogin
      record Outcome, opened : Sessions::Opened? = nil, error : String? = nil, step_up : Int32? = nil

      # Identité attestée par connect → session de l'administration.
      #
      # * Utilisateur lié (`connect_sub`) : session au niveau attesté.
      # * Pas encore lié, avec l'invitation de cet utilisateur
      #   (`invitation`) : lié si l'adresse vérifiée par connect est la sienne
      #   ; l'invitation est alors consommée. Un courriel intercepté ne lie
      #   donc pas le compte d'un autre.
      # * Niveau attesté inférieur à celui qu'exige le rôle (super-admin :
      #   passkey) : `step_up`, le niveau à redemander à connect.
      def self.login(identity : Connect::Identity, invitation : String? = nil, ip : String = "",
                     user_agent : String = "", now : Time = Time.utc) : Outcome
        user = User.filter(connect_sub: identity.subject).first
        if user.nil? && (raw = invitation.presence)
          user, error = link(identity, raw, ip, now)
          return Outcome.new(error: error) if error
        end
        if user.nil?
          Audit.log(nil, "auth.login", outcome: "fail", detail: {"method" => "connect", "reason" => "unknown"}, ip: ip,
            actor_label: identity.email)
          return Outcome.new(error: "admin.errors.connect.unknown")
        end
        return Outcome.new(error: "admin.errors.login.invalid") unless user.can_sign_in?
        required = Auth.required_level(user)
        return Outcome.new(step_up: required) if identity.level < required
        refresh_email(user, identity)
        opened = Sessions.open(user, identity.level, "connect", ip, user_agent, now)
        opened.session.federated_sid = identity.sid
        opened.session.save!
        Audit.log(user, "auth.login", target: user, detail: {"level" => identity.level.to_s, "method" => "connect"}, ip: ip)
        Outcome.new(opened: opened)
      end

      private def self.link(identity : Connect::Identity, raw : String, ip : String, now : Time) : {User?, String?}
        user = Invitations.peek(raw, now)
        return {nil, "admin.errors.login.expired"} if user.nil?
        unless identity.email == user.email.to_s
          Audit.log(user, "auth.invitation", outcome: "fail", target: user, detail: {"reason" => "connect_email"}, ip: ip)
          return {nil, "admin.errors.connect.invitation_email"}
        end
        return {nil, "admin.errors.connect.already_linked"} unless user.connect_sub.nil?
        return {nil, "admin.errors.login.expired"} if Invitations.consume(raw, now).nil?
        user.connect_sub = identity.subject
        user.save!
        Audit.log(user, "auth.invitation", target: user, detail: {"method" => "connect"}, ip: ip)
        {user, nil}
      end

      # Adresse changée chez connect : reportée ici (ADR-012 D8), sauf si un
      # autre utilisateur l'a déjà.
      private def self.refresh_email(user : User, identity : Connect::Identity) : Nil
        return if identity.email.empty? || identity.email == user.email.to_s
        return if User.filter(email: identity.email).exclude(id: user.pk).exists?
        previous = user.email.to_s
        user.email = identity.email
        user.save!
        Audit.log(user, "user.email", target: user, detail: {"old" => previous, "new" => identity.email})
      end

      # Déconnexion par canal arrière : sessions de ce `sid` (ou de la
      # personne) fermées. `nil` si le jeton est refusé.
      def self.backchannel_logout(token : String, now : Time = Time.utc) : Int64?
        subject, sid = Connect.verify_logout_token(token, now)
        user = subject.try { |sub| User.filter(connect_sub: sub).first }
        sessions = Session.filter(revoked_at__isnull: true)
        if sid
          sessions = sessions.filter(federated_sid: sid)
        elsif user
          sessions = sessions.filter(user_id: user.pk, method: "connect")
        else
          return 0_i64
        end
        closed = sessions.update(revoked_at: now).to_i64
        Audit.log(user, "auth.backchannel_logout", detail: {"sessions" => closed.to_s}, actor_label: user ? nil : "connect")
        closed
      rescue Connect::Error
        nil
      end
    end

    module Invitations
      # Lien de création du compte connect gardé avec l'invitation `raw`
      # (ADR-012 D6) ; rend le code à transmettre par un autre canal, `nil`
      # sans connect ou si la personne a déjà un compte.
      def self.attach_connect(user : User, raw : String) : String?
        ticket = Connect.signup_ticket(user, "#{Config.base_url}/invitation/#{raw}/connect")
        return if ticket.nil?
        Invitation.filter(digest: Secrets.digest(raw)).update(signup_url: ticket[0])
        ticket[1]
      end

      def self.signup_url(raw : String?, now : Time = Time.utc) : String?
        return if raw.nil? || raw.empty?
        Invitation.filter(digest: Secrets.digest(raw), used_at__isnull: true, expires_at__gt: now).first
          .try(&.signup_url.presence)
      end
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Courriel texte : invitations et alertes.
  class TextEmail < Marten::Email
    from Config.mail_from
    to @address
    subject @title

    def initialize(@address : String, @title : String, @body : String)
    end

    def text_body : String?
      @body
    end
  end

  module Mailer
    # Invitation d'un utilisateur de l'administration (amorçage, création,
    # réémission).
    def self.invitation(user : User, url : String) : Nil
      subject, body = invitation_text(user.locale.presence || "fr", url)
      TextEmail.new(user.email.to_s, subject, body).deliver
    end

    # Objet et texte de l'invitation dans une langue : le courriel envoyé,
    # et son aperçu dans l'assistant d'invitation (D-ADM-022).
    def self.invitation_text(locale : String, url : String) : {String, String}
      I18n.with_locale(Config::LOCALES.includes?(locale) ? locale : "fr") do
        body = String.build do |io|
          io << I18n.t("admin.emails.invitation.intro") << "\n\n" << url << "\n\n"
          io << I18n.t("admin.emails.invitation.expires", days: Config::INVITATION_TTL.days.to_s) << "\n"
          io << I18n.t("admin.emails.ignore") << "\n"
        end
        {I18n.t("admin.emails.invitation.subject"), body}
      end
    end

    # Invitation de l'administrateur d'un dossier (création, recours
    # d'accès) : le lien vient de l'instance, n'est pas conservé ici.
    def self.invitation_to_dossier(dossier : Dossier, email : String, url : String) : Nil
      I18n.with_locale(dossier.locale.presence || "fr") do
        body = String.build do |io|
          io << I18n.t("admin.emails.dossier_invitation.intro", host: dossier.host) << "\n\n" << url << "\n\n"
          io << I18n.t("admin.emails.ignore") << "\n"
        end
        TextEmail.new(email, I18n.t("admin.emails.dossier_invitation.subject", host: dossier.host), body).deliver
      end
    end

    # Avis aux administrateurs d'un dossier (D-ADM-020) : sujet et texte
    # rédigés par l'instance, dans la langue du destinataire ; envoyés ici
    # seulement quand ni l'instance ni le serveur n'ont pu les remettre.
    def self.notice(email : String, subject : String, body : String) : Nil
      raise ArgumentError.new("avis vide pour #{email}") if subject.strip.empty? || body.strip.empty?
      TextEmail.new(email, subject.gsub(/[[:cntrl:]]/, " ").strip, body).deliver
    end

    # Avis d'une validation en dernier recours par un super-admin
    # (D-ADM-024) aux admins actifs de la structure, chacun dans sa langue.
    # Un échec d'envoi ne défait pas la décision : il est rendu, pour le
    # journal d'audit. Rend les adresses avisées et celles en échec.
    def self.recourse(approval : Approval, decider : User, recipients : Array(User)) : {Array(String), Array(String)}
      notify(recipients, "recours") { |locale| recourse_text(approval, decider, locale) }
    end

    # Avis d'une demande du super-admin sur une structure à une personne
    # (D-ADM-028) aux admins actifs de la structure, chacun dans sa langue,
    # dès la demande : ils peuvent la valider ou la refuser jusqu'à
    # l'échéance, après laquelle le super-admin la confirme seul.
    def self.held(approval : Approval, recipients : Array(User)) : {Array(String), Array(String)}
      notify(recipients, "demande") { |locale| held_text(approval, locale) }
    end

    # Annonce d'une nouvelle clé publique de sauvegarde du cabinet
    # (D-ADM-029) aux *autres* admins actifs du cabinet, chacun dans sa
    # langue : auteur, heure, ancienne et nouvelle empreinte, marche à
    # suivre si le changement n'est pas légitime (B-CRA-001).
    def self.backup_key(change : KeyChange, recipients : Array(User)) : {Array(String), Array(String)}
      notify(recipients, "nouvelle clé") { |locale| backup_key_text(change, locale) }
    end

    # Envoi d'un avis à chaque destinataire, dans sa langue. Un échec
    # d'envoi ne défait pas le geste qui l'a provoqué : il est rendu, pour le
    # journal d'audit. Rend les adresses avisées et celles en échec.
    private def self.notify(recipients : Array(User), label : String, & : String -> {String, String}) : {Array(String), Array(String)}
      notified = [] of String
      failed = [] of String
      recipients.each do |recipient|
        subject, body = yield(recipient.locale.presence || "fr")
        TextEmail.new(recipient.email.to_s, subject, body).deliver
        notified << recipient.email.to_s
      rescue ex
        Log.warn { "avis (#{label}) non envoyé à #{recipient.email} : #{ex.message}" }
        failed << recipient.email.to_s
      end
      {notified, failed}
    end

    # Objet et texte de l'avis d'une demande retenue dans une langue.
    def self.held_text(approval : Approval, locale : String) : {String, String}
      I18n.with_locale(Config::LOCALES.includes?(locale) ? locale : "fr") do
        body = String.build do |io|
          io << I18n.t("admin.emails.held.intro", reference: approval.reference.to_s, kind: I18n.t(approval.kind_key),
            target: approval.target_name, structure: approval.target_firm.try(&.name.to_s) || "") << "\n\n"
          io << I18n.t("admin.emails.held.requested_by", person: approval.requested_by.try(&.email.to_s) || "") << "\n"
          if reason = approval.reason_text
            io << I18n.t("admin.emails.held.reason", reason: reason) << "\n"
          end
          io << "\n" << I18n.t("admin.emails.held.deadline", time: Approvals.recourse_at(approval).to_s("%Y-%m-%d %H:%M UTC"),
            hours: Config.recourse_delay.total_hours.to_i.to_s) << "\n"
          io << Config.base_url << "/approvals\n"
        end
        {I18n.t("admin.emails.held.subject", reference: approval.reference.to_s), body}
      end
    end

    # Changement de la clé publique de sauvegarde d'un cabinet.
    record KeyChange, firm : Firm, author : User, previous : String, current : String, at : Time,
      super_admins : Array(String)

    # Objet et texte de l'annonce d'une nouvelle clé dans une langue.
    def self.backup_key_text(change : KeyChange, locale : String) : {String, String}
      I18n.with_locale(Config::LOCALES.includes?(locale) ? locale : "fr") do
        author = change.author.email.to_s
        previous = change.previous.empty? ? I18n.t("admin.emails.backup_key.none") : BackupCrypto.display_fingerprint(change.previous)
        body = String.build do |io|
          io << I18n.t("admin.emails.backup_key.intro", structure: change.firm.name.to_s, person: author,
            time: change.at.to_s("%Y-%m-%d %H:%M UTC")) << "\n\n"
          io << I18n.t("admin.emails.backup_key.previous", fingerprint: previous) << "\n"
          io << I18n.t("admin.emails.backup_key.current", fingerprint: BackupCrypto.display_fingerprint(change.current)) << "\n\n"
          io << I18n.t("admin.emails.backup_key.illegitimate", person: author,
            super_admins: change.super_admins.join(", ").presence || "—") << "\n"
          io << Config.base_url << "/firms/" << change.firm.pk << "/backups\n\n"
          io << I18n.t("admin.emails.backup_key.audit") << "\n"
        end
        {I18n.t("admin.emails.backup_key.subject", structure: change.firm.name.to_s), body}
      end
    end

    # Objet et texte de l'avis de recours dans une langue.
    def self.recourse_text(approval : Approval, decider : User, locale : String) : {String, String}
      I18n.with_locale(Config::LOCALES.includes?(locale) ? locale : "fr") do
        target = approval.dossier.try(&.slug.to_s) || approval.target_firm.try(&.name.to_s) || ""
        body = String.build do |io|
          io << I18n.t("admin.emails.recourse.intro", reference: approval.reference.to_s, kind: I18n.t(approval.kind_key),
            target: target, structure: approval.target_firm.try(&.name.to_s) || "") << "\n\n"
          io << I18n.t("admin.emails.recourse.requested_by", person: approval.requested_by.try(&.email.to_s) || "") << "\n"
          io << I18n.t("admin.emails.recourse.decided_by", person: decider.email.to_s,
            hours: Config.recourse_delay.total_hours.to_i.to_s) << "\n\n"
          io << I18n.t("admin.emails.recourse.audit") << "\n" << Config.base_url << "/approvals\n"
        end
        {I18n.t("admin.emails.recourse.subject", reference: approval.reference.to_s), body}
      end
    end

    def self.alert(alert : Alert) : Nil
      recipients = Config.alert_recipients
      return if recipients.empty?
      subject = I18n.t("admin.emails.alert.subject", kind: I18n.t(alert.kind_key), subject: alert.subject)
      body = "#{I18n.t(alert.kind_key)} — #{alert.subject}\n#{alert.detail}\n\n#{Config.base_url}/alerts\n"
      recipients.each { |address| TextEmail.new(address, subject, body).deliver }
    rescue ex
      Log.warn { "alerte non envoyée : #{ex.message}" }
    end
  end
end

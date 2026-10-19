# SPDX-License-Identifier: AGPL-3.0-or-later

require "log"
require "marten-mail"

module PartiduoConnect
  # Envoi des courriels par le compte SMTP de Partiduo :
  # `PARTIDUO_CONNECT_SMTP_URL` (marten-mail), posé par la recette beryl
  # depuis le coffre. Jamais par le relais SMTP du serveur (monit).
  module MailBackend
    def self.build(url : String? = ENV["PARTIDUO_CONNECT_SMTP_URL"]?) : Marten::Emailing::Backend::Base
      if smtp = url.presence
        MartenMail::Backend.new(smtp)
      else
        Missing.new
      end
    end

    class Missing < Marten::Emailing::Backend::Base
      def deliver(email : Marten::Emailing::Email) : Nil
        raise MartenMail::DeliveryError.new("PARTIDUO_CONNECT_SMTP_URL non réglée : aucun courriel envoyé (#{email.subject})")
      end
    end
  end

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

  # Avis à la personne à chaque événement sensible (ADR-012 D7) et lien de
  # changement d'adresse (D8). Un avis qui ne part pas n'annule pas
  # l'action : il est journalisé.
  module Mailer
    Log = ::Log.for("connect.mailer")

    EVENTS = %w[passkey_added passkey_removed recovery_regenerated recovery_used password_changed totp_enabled
      email_changed]

    def self.notify(account : Account, event : String, ip : String = "", address : String? = nil) : Nil
      I18n.with_locale(account.locale.presence || "fr") do
        body = String.build do |io|
          io << I18n.t("connect.emails.notice.intro", name: account.name) << "\n\n"
          io << I18n.t("connect.emails.events.#{event}") << "\n"
          io << I18n.t("connect.emails.notice.when", at: Config.now.to_s("%Y-%m-%d %H:%M UTC")) << "\n"
          io << I18n.t("connect.emails.notice.ip", ip: ip) << "\n" unless ip.empty?
          io << "\n" << I18n.t("connect.emails.notice.not_you", url: "#{Config.base_url}/account") << "\n"
        end
        deliver(address || account.email.to_s, I18n.t("connect.emails.notice.subject"), body)
      end
    end

    def self.email_change(account : Account, new_email : String, url : String) : Nil
      I18n.with_locale(account.locale.presence || "fr") do
        body = String.build do |io|
          io << I18n.t("connect.emails.email_change.intro", name: account.name) << "\n\n" << url << "\n\n"
          io << I18n.t("connect.emails.email_change.expires", hours: Config::EMAIL_CHANGE_TTL.total_hours.to_i.to_s) << "\n"
          io << I18n.t("connect.emails.ignore") << "\n"
        end
        deliver(new_email, I18n.t("connect.emails.email_change.subject"), body)
      end
    end

    private def self.deliver(address : String, subject : String, body : String) : Nil
      TextEmail.new(address, subject, body).deliver
    rescue ex
      Log.warn { "Courriel « #{subject} » non envoyé à #{address} : #{ex.message}" }
    end
  end
end

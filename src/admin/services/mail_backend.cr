# SPDX-License-Identifier: AGPL-3.0-or-later

require "marten-mail"

module PartiduoAdmin
  # Envoi des courriels de l'administration (invitations des utilisateurs,
  # alertes) par le compte SMTP de Partiduo : `PARTIDUO_ADMIN_SMTP_URL`
  # (`smtp://notifications%40partiduo.app:secret@hôte:587`, marten-mail), posé
  # dans admin.env par la recette beryl depuis le coffre. Jamais par le relais
  # SMTP du serveur, réservé aux alertes du système (monit).
  #
  # Sans ce réglage, Marten garderait son envoi de développement, qui n'envoie
  # rien et ne dit rien (constaté sur loulou, 17 octobre 2026) : l'envoi est
  # alors refusé avec la cause.
  module MailBackend
    def self.build(url : String? = ENV["PARTIDUO_ADMIN_SMTP_URL"]?) : Marten::Emailing::Backend::Base
      if smtp = url.presence
        MartenMail::Backend.new(smtp)
      else
        Missing.new
      end
    end

    class Missing < Marten::Emailing::Backend::Base
      def deliver(email : Marten::Emailing::Email) : Nil
        raise MartenMail::DeliveryError.new("PARTIDUO_ADMIN_SMTP_URL non réglée : aucun courriel envoyé (#{email.subject})")
      end
    end
  end
end

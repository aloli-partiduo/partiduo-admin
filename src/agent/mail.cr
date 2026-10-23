# SPDX-License-Identifier: AGPL-3.0-or-later

require "marten-mail/client"

module PartiduoAgent
  # Courriel d'invitation de l'administrateur d'un dossier, remis par le
  # serveur lui-même (D-CRA-003) : le lien d'invitation ne quitte jamais le
  # serveur d'hébergement, l'administration n'en voit que la trace
  # (`invitation_delivered`). Une faille de l'administration ne donne donc
  # pas le lien qui ouvre un compte d'administrateur de dossier (ADR-008 D3,
  # « Conséquences positives »).
  #
  # Envoi par le compte SMTP de Partiduo (`--smtp-url-file`, marten-mail),
  # jamais par le relais du serveur.
  module InvitationMail
    # Adresse sûre : ni espace, ni retour à la ligne, ni séparateur d'en-tête,
    # jamais prise pour une option.
    ADDRESS = /\A[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\z/

    # Mêmes textes que `admin.emails.dossier_invitation` de l'administration.
    TEXTS = {
      "fr" => {
        "subject" => "Invitation à administrer le dossier %{host}",
        "intro"   => "Vous êtes invité à administrer le dossier Partiduo %{host}. Ouvrez ce lien pour créer votre accès :",
        "ignore"  => "Si vous n'attendiez pas ce message, ignorez-le.",
      },
      "en" => {
        "subject" => "Invitation to administer the company file %{host}",
        "intro"   => "You are invited to administer the Partiduo company file %{host}. Open this link to create your access:",
        "ignore"  => "If you were not expecting this message, ignore it.",
      },
      "nl" => {
        "subject" => "Uitnodiging om het dossier %{host} te beheren",
        "intro"   => "U bent uitgenodigd om het Partiduo-dossier %{host} te beheren. Open deze link om uw toegang aan te maken:",
        "ignore"  => "Als u dit bericht niet verwachtte, negeer het dan.",
      },
      "de" => {
        "subject" => "Einladung zur Verwaltung des Mandanten %{host}",
        "intro"   => "Sie wurden eingeladen, den Partiduo-Mandanten %{host} zu verwalten. Öffnen Sie diesen Link, um Ihren Zugang einzurichten:",
        "ignore"  => "Wenn Sie diese Nachricht nicht erwartet haben, ignorieren Sie sie.",
      },
      "es" => {
        "subject" => "Invitación para administrar el expediente %{host}",
        "intro"   => "Se le invita a administrar el expediente Partiduo %{host}. Abra este enlace para crear su acceso:",
        "ignore"  => "Si no esperaba este mensaje, ignórelo.",
      },
      "it" => {
        "subject" => "Invito ad amministrare il dossier %{host}",
        "intro"   => "È invitato ad amministrare il dossier Partiduo %{host}. Apra questo link per creare il Suo accesso:",
        "ignore"  => "Se non si aspettava questo messaggio, lo ignori.",
      },
      "pt" => {
        "subject" => "Convite para administrar o dossier %{host}",
        "intro"   => "Recebeu um convite para administrar o dossier Partiduo %{host}. Abra esta ligação para criar o seu acesso:",
        "ignore"  => "Se não esperava esta mensagem, ignore-a.",
      },
    }

    def self.valid_address?(address : String) : Bool
      ADDRESS.matches?(address) && !address.starts_with?('-')
    end

    def self.text(locale : String, key : String, host : String) : String
      (TEXTS[locale]? || TEXTS["fr"])[key].gsub("%{host}", host)
    end

    # Message de l'invitation, texte seul, dans la langue du dossier.
    def self.build(from : String, to : String, host : String, url : String, locale : String,
                   date : Time = Time.utc) : MartenMail::Message
      body = "#{text(locale, "intro", host)}\n\n#{url}\n\n#{text(locale, "ignore", host)}\n"
      MartenMail::Message.new(from: from, to: [to], subject: text(locale, "subject", host), text: body, date: date)
    end
  end
end

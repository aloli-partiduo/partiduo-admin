# SPDX-License-Identifier: AGPL-3.0-or-later

require "password-policy"
require "uri"

module PartiduoConnect
  # Paramètres de `connect`, lus dans l'environnement (ADR-012).
  module Config
    ISSUER_NAME = "Partiduo"

    LOCALES = %w[fr en nl]

    # Niveaux d'authentification (ADR-002 D2), publiés comme `acr` : 0
    # enrôlement, 1 mot de passe, 2 mot de passe + TOTP (ou code de
    # récupération), 3 passkey.
    ACR_VALUES = %w[1 2 3]
    # Niveau par défaut d'une connexion pour un client : un compte complet a
    # toujours au moins deux facteurs (ADR-002 D7).
    DEFAULT_ACR = 2

    # Limitation des tentatives (ADR-002, CNIL 2022-100) : mêmes paliers que
    # les dossiers et l'administration.
    THROTTLE_AFTER    =  3
    LOCK_AFTER        = 10
    THROTTLE_BASE     = 5.seconds
    THROTTLE_MAXIMUM  = 15.minutes
    PENDING_LIFETIME  = 5.minutes
    CHALLENGE_TIMEOUT = 5.minutes
    IDLE_TIMEOUT      = 30.minutes
    SESSION_LIFETIME  = 12.hours
    RECOVERY_CODES    = 10
    REAUTH_WINDOW     = 5.minutes

    # Création d'un compte (ADR-012 D6) : lien et code transmis par un autre
    # canal ; quelques essais faux annulent l'invitation.
    SIGNUP_TTL      = 7.days
    SIGNUP_ATTEMPTS = 5

    # Changement d'adresse (ADR-012 D8) : lien envoyé à la nouvelle adresse.
    EMAIL_CHANGE_TTL = 24.hours

    # OpenID Connect : code d'autorisation, jeton d'accès (lecture de
    # `userinfo`), jeton d'identité, jeton de déconnexion.
    CODE_LIFETIME         = 1.minute
    ACCESS_TOKEN_LIFETIME = 10.minutes
    ID_TOKEN_LIFETIME     = 5.minutes
    LOGOUT_TOKEN_LIFETIME = 2.minutes
    BACKCHANNEL_TIMEOUT   = 5.seconds

    # Journal : conservation proposée d'un an (ADR-012, questions ouvertes).
    AUDIT_PAGE = 50

    def self.password_policy : PasswordPolicy::Policy
      PasswordPolicy::Policy.long(use_case: PasswordPolicy::UseCase::WithAccessRestriction)
    end

    def self.bcrypt_cost : Int32
      if value = ENV["PARTIDUO_BCRYPT_COST"]?.try(&.to_i?)
        return value.clamp(4, 31)
      end
      ENV["MARTEN_ENV"]? == "test" ? 4 : 12
    end

    # Domaine du parc (ADR-001 D2) : `partiduo.app` en production,
    # `partiduo.dev` sur le serveur de test, `partiduo.localhost` sur un poste.
    def self.domain : String
      ENV["PARTIDUO_DOMAIN"]?.presence || "partiduo.localhost"
    end

    # Nom d'hôte de `connect` (ADR-012 D1 : `connect.<domaine>`).
    def self.host : String
      ENV["PARTIDUO_CONNECT_HOST"]?.presence || "connect.#{domain}"
    end

    def self.port : Int32
      (ENV["PORT"]? || "8300").to_i
    end

    # Adresse publique, qui est aussi l'émetteur (`iss`) des jetons.
    def self.base_url : String
      ENV["PARTIDUO_CONNECT_URL"]?.presence || (domain.ends_with?(".localhost") ? "http://#{host}:#{port}" : "https://#{host}")
    end

    def self.issuer : String
      base_url
    end

    def self.database_url : String
      ENV["DATABASE_URL"]?.presence ||
        (ENV["MARTEN_ENV"]? == "test" ? "postgres:///partiduo_connect_test?host=/tmp" : "postgres:///partiduo_connect?host=/tmp")
    end

    # Partie de confiance WebAuthn : le domaine commun (ADR-002 D5), pour que
    # les passkeys restent présentables quel que soit le serveur `connect`.
    def self.rp_id : String
      ENV["PARTIDUO_CONNECT_RP_ID"]?.presence || domain
    end

    # Origines admises pour WebAuthn : `connect.<domaine>` seulement (les
    # dossiers ne présentent plus de passkey eux-mêmes).
    def self.origin_allowed?(origin : String) : Bool
      if list = ENV["PARTIDUO_CONNECT_WEBAUTHN_ORIGINS"]?.presence
        return list.split(',').map(&.strip).includes?(origin)
      end
      uri = URI.parse(origin)
      origin_host = uri.host.to_s.downcase
      return false if origin_host.empty? || !uri.path.empty? || uri.query || uri.user
      return false unless origin_host == host.downcase
      case uri.scheme
      when "https" then true
      when "http"  then origin_host == "localhost" || origin_host.ends_with?(".localhost")
      else              false
      end
    rescue URI::Error
      false
    end

    # Adresse d'expédition des avis (D7) et des liens de changement
    # d'adresse.
    def self.mail_from : String
      ENV["PARTIDUO_CONNECT_MAIL_FROM"]?.presence || "no-reply@#{domain}"
    end

    # Fichier des clés de signature (JWK privées, ES256), posé par beryl
    # depuis le coffre (ADR-012 D5) : la première signe, toutes sont
    # publiées.
    def self.signing_keys_path : String?
      ENV["PARTIDUO_CONNECT_SIGNING_KEYS"]?.presence
    end

    # Horloge remplaçable dans les specs.
    class_property clock : Proc(Time) = -> { Time.utc }

    def self.now : Time
      clock.call
    end
  end

  # Identifiant d'une clé étrangère Marten ramené à `Int64?`.
  def self.id?(value) : Int64?
    case value
    when Int64 then value
    when Int32 then value.to_i64
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoConnect
  # Compte d'une personne (ADR-012 D1) : une adresse vérifiée, un
  # identifiant stable `sub` (opaque, jamais réattribué) et ses moyens
  # d'authentification. Aucune donnée de dossier, aucun droit.
  class Account < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :sub, :string, max_size: 64, unique: true
    field :email, :email, unique: true
    field :display_name, :string, max_size: 200, blank: true, default: ""
    # Langue d'affichage du compte, pour connect et chaque client (claim
    # `locale`) ; vide : celle du navigateur.
    field :locale, :string, max_size: 8, blank: true, default: "fr"
    field :password_digest, :string, max_size: 128, null: true, blank: true
    field :password_changed_at, :date_time, null: true, blank: true
    field :totp_secret, :string, max_size: 64, null: true, blank: true
    field :totp_pending_secret, :string, max_size: 64, null: true, blank: true
    field :totp_enabled_at, :date_time, null: true, blank: true
    field :last_otp_counter, :big_int, null: true, blank: true
    field :failed_attempts, :int, default: 0
    field :last_failed_at, :date_time, null: true, blank: true
    field :locked_at, :date_time, null: true, blank: true
    # Suspendu par l'exploitation : aucune connexion, sessions fermées.
    field :active, :bool, default: true
    field :last_login_at, :date_time, null: true, blank: true
    # Fournisseur du cabinet qui authentifie cette personne (ADR-012 D9) et
    # son identifiant chez lui ; vides pour un compte à facteurs connect.
    field :upstream, :string, max_size: 64, blank: true, default: ""
    field :upstream_subject, :string, max_size: 255, blank: true, default: ""
    field :created_at, :date_time, auto_now_add: true
    field :updated_at, :date_time, auto_now: true

    def upstream? : Bool
      !upstream.to_s.empty?
    end

    def totp_enabled? : Bool
      !totp_secret.nil? && !totp_enabled_at.nil?
    end

    def usable_password? : Bool
      !password_digest.nil?
    end

    def locked? : Bool
      !locked_at.nil?
    end

    def can_sign_in? : Bool
      active == true && !locked?
    end

    def name : String
      display_name.presence || email.to_s
    end
  end

  # Session du navigateur chez `connect`. Jeton conservé en empreinte ;
  # `level` (ADR-002 D2) ; `sid` : identifiant de session publié aux
  # clients, repris par la déconnexion par canal arrière (ADR-012 D8).
  class Session < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account, :many_to_one, to: PartiduoConnect::Account, on_delete: :cascade
    field :token_digest, :string, max_size: 64, unique: true
    field :sid, :string, max_size: 64, unique: true
    field :level, :int, default: 0
    field :method, :string, max_size: 16
    field :ip, :string, max_size: 64, blank: true, default: ""
    field :user_agent, :string, max_size: 255, blank: true, default: ""
    # Adresse où revenir une fois l'enrôlement fini (création d'un compte
    # depuis un dossier).
    field :return_to, :string, max_size: 1000, blank: true, default: ""
    field :created_at, :date_time, auto_now_add: true
    # Dernière authentification (OpenID Connect `auth_time`, `max_age`).
    field :auth_time, :date_time
    field :last_seen_at, :date_time
    field :expires_at, :date_time
    field :revoked_at, :date_time, null: true, blank: true
    field :strong_auth_at, :date_time, null: true, blank: true
  end

  # Défi à usage unique (WebAuthn, second facteur en attente).
  class Challenge < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :purpose, :string, max_size: 32
    field :handle_digest, :string, max_size: 64, unique: true
    field :value, :string, max_size: 255, blank: true, default: ""
    field :account, :many_to_one, to: PartiduoConnect::Account, null: true, blank: true, on_delete: :cascade
    field :created_at, :date_time, auto_now_add: true
    field :expires_at, :date_time
    field :used_at, :date_time, null: true, blank: true
  end

  # Passkey enrôlée : clé publique COSE, aucun secret.
  class Passkey < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account, :many_to_one, to: PartiduoConnect::Account, on_delete: :cascade
    field :credential_id, :string, max_size: 1400, unique: true
    field :public_key, :text
    field :cose_algorithm, :int
    field :sign_count, :big_int, default: 0
    field :backup_eligible, :bool, default: false
    field :backup_state, :bool, default: false
    field :name, :string, max_size: 100, blank: true, default: ""
    field :created_at, :date_time, auto_now_add: true
    field :last_used_at, :date_time, null: true, blank: true
  end

  # Code de récupération à usage unique (ADR-002 D7).
  class RecoveryCode < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account, :many_to_one, to: PartiduoConnect::Account, on_delete: :cascade
    field :code_digest, :string, max_size: 64
    field :created_at, :date_time, auto_now_add: true
    field :used_at, :date_time, null: true, blank: true
  end

  # Invitation à créer un compte (ADR-012 D6) : un lien (jeton) remis par
  # courriel et un code court transmis par un autre canal. Les deux sont
  # nécessaires ; `SIGNUP_ATTEMPTS` codes faux l'annulent.
  class SignupTicket < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :token_digest, :string, max_size: 64, unique: true
    field :code_digest, :string, max_size: 64
    field :email, :email
    field :display_name, :string, max_size: 200, blank: true, default: ""
    field :locale, :string, max_size: 8, default: "fr"
    field :client, :many_to_one, to: PartiduoConnect::Client, null: true, blank: true, on_delete: :cascade
    # Récupération : le compte à rouvrir (facteurs retirés), au lieu d'en
    # créer un.
    field :account, :many_to_one, to: PartiduoConnect::Account, null: true, blank: true, on_delete: :cascade
    field :return_to, :string, max_size: 1000, blank: true, default: ""
    field :created_by, :string, max_size: 255, blank: true, default: ""
    field :attempts, :int, default: 0
    field :created_at, :date_time, auto_now_add: true
    field :expires_at, :date_time
    field :used_at, :date_time, null: true, blank: true
    field :cancelled_at, :date_time, null: true, blank: true
  end

  # Changement d'adresse en attente de confirmation (ADR-012 D8).
  class EmailChange < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account, :many_to_one, to: PartiduoConnect::Account, on_delete: :cascade
    field :token_digest, :string, max_size: 64, unique: true
    field :new_email, :email
    field :created_at, :date_time, auto_now_add: true
    field :expires_at, :date_time
    field :used_at, :date_time, null: true, blank: true
  end

  # Journal d'audit en *ajout seul* (ADR-012 D7) : un déclencheur refuse
  # modification et suppression. Pas de clé étrangère : le journal survit au
  # compte ; `account_label` fige l'adresse au moment de l'action.
  class AuditEntry < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account_id, :big_int, null: true, blank: true
    field :account_label, :string, max_size: 255, blank: true, default: ""
    field :action, :string, max_size: 64
    field :client_id, :string, max_size: 64, blank: true, default: ""
    field :outcome, :string, max_size: 8, default: "ok"
    field :ip, :string, max_size: 64, blank: true, default: ""
    field :detail, :text, blank: true, default: ""
    field :created_at, :date_time, auto_now_add: true

    # Application affichée, `nil` sans application : une chaîne vide est
    # vraie dans un gabarit de Marten.
    def client_text : String?
      client_id.to_s.presence
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

# Schéma initial de `connect` (ADR-012) : comptes et facteurs, clients et
# jetons OpenID Connect, invitations, journal.
class Migration::Connect::V0001 < Marten::Migration
  def plan
    create_table :connect_client do
      column :id, :big_int, primary_key: true, auto: true
      column :client_id, :string, max_size: 64, unique: true
      column :name, :string, max_size: 200
      column :secret_digest, :string, max_size: 64
      column :redirect_uris, :text
      column :post_logout_redirect_uris, :text, default: ""
      column :backchannel_logout_uri, :string, max_size: 1000, default: ""
      column :active, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :connect_account do
      column :id, :big_int, primary_key: true, auto: true
      column :sub, :string, max_size: 64, unique: true
      column :email, :string, max_size: 254, unique: true
      column :display_name, :string, max_size: 200, default: ""
      column :locale, :string, max_size: 8, default: "fr"
      column :password_digest, :string, max_size: 128, null: true
      column :password_changed_at, :date_time, null: true
      column :totp_secret, :string, max_size: 64, null: true
      column :totp_pending_secret, :string, max_size: 64, null: true
      column :totp_enabled_at, :date_time, null: true
      column :last_otp_counter, :big_int, null: true
      column :failed_attempts, :int, default: 0
      column :last_failed_at, :date_time, null: true
      column :locked_at, :date_time, null: true
      column :active, :bool, default: true
      column :last_login_at, :date_time, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :connect_session do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :reference, to_table: :connect_account, to_column: :id
      column :token_digest, :string, max_size: 64, unique: true
      column :sid, :string, max_size: 64, unique: true
      column :level, :int, default: 0
      column :method, :string, max_size: 16
      column :ip, :string, max_size: 64, default: ""
      column :user_agent, :string, max_size: 255, default: ""
      column :return_to, :string, max_size: 1000, default: ""
      column :created_at, :date_time
      column :auth_time, :date_time
      column :last_seen_at, :date_time
      column :expires_at, :date_time
      column :revoked_at, :date_time, null: true
      column :strong_auth_at, :date_time, null: true
    end

    create_table :connect_challenge do
      column :id, :big_int, primary_key: true, auto: true
      column :purpose, :string, max_size: 32
      column :handle_digest, :string, max_size: 64, unique: true
      column :value, :string, max_size: 255, default: ""
      column :account_id, :reference, to_table: :connect_account, to_column: :id, null: true
      column :created_at, :date_time
      column :expires_at, :date_time
      column :used_at, :date_time, null: true
    end

    create_table :connect_passkey do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :reference, to_table: :connect_account, to_column: :id
      column :credential_id, :string, max_size: 1400, unique: true
      column :public_key, :text
      column :cose_algorithm, :int
      column :sign_count, :big_int, default: 0
      column :backup_eligible, :bool, default: false
      column :backup_state, :bool, default: false
      column :name, :string, max_size: 100, default: ""
      column :created_at, :date_time
      column :last_used_at, :date_time, null: true
    end

    create_table :connect_recovery_code do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :reference, to_table: :connect_account, to_column: :id
      column :code_digest, :string, max_size: 64
      column :created_at, :date_time
      column :used_at, :date_time, null: true
    end

    create_table :connect_signup_ticket do
      column :id, :big_int, primary_key: true, auto: true
      column :token_digest, :string, max_size: 64, unique: true
      column :code_digest, :string, max_size: 64
      column :email, :string, max_size: 254
      column :display_name, :string, max_size: 200, default: ""
      column :locale, :string, max_size: 8, default: "fr"
      column :client_id, :reference, to_table: :connect_client, to_column: :id, null: true
      column :return_to, :string, max_size: 1000, default: ""
      column :created_by, :string, max_size: 255, default: ""
      column :attempts, :int, default: 0
      column :created_at, :date_time
      column :expires_at, :date_time
      column :used_at, :date_time, null: true
      column :cancelled_at, :date_time, null: true
    end

    create_table :connect_email_change do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :reference, to_table: :connect_account, to_column: :id
      column :token_digest, :string, max_size: 64, unique: true
      column :new_email, :string, max_size: 254
      column :created_at, :date_time
      column :expires_at, :date_time
      column :used_at, :date_time, null: true
    end

    create_table :connect_audit_entry do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :big_int, null: true
      column :account_label, :string, max_size: 255, default: ""
      column :action, :string, max_size: 64
      column :client_id, :string, max_size: 64, default: ""
      column :outcome, :string, max_size: 8, default: "ok"
      column :ip, :string, max_size: 64, default: ""
      column :detail, :text, default: ""
      column :created_at, :date_time
    end

    create_table :connect_authorization_code do
      column :id, :big_int, primary_key: true, auto: true
      column :code_digest, :string, max_size: 64, unique: true
      column :client_id, :reference, to_table: :connect_client, to_column: :id
      column :account_id, :reference, to_table: :connect_account, to_column: :id
      column :session_id, :reference, to_table: :connect_session, to_column: :id
      column :redirect_uri, :string, max_size: 1000
      column :code_challenge, :string, max_size: 128
      column :nonce, :string, max_size: 255, default: ""
      column :scope, :string, max_size: 255, default: "openid"
      column :created_at, :date_time
      column :expires_at, :date_time
      column :used_at, :date_time, null: true
    end

    create_table :connect_access_token do
      column :id, :big_int, primary_key: true, auto: true
      column :token_digest, :string, max_size: 64, unique: true
      column :client_id, :reference, to_table: :connect_client, to_column: :id
      column :account_id, :reference, to_table: :connect_account, to_column: :id
      column :scope, :string, max_size: 255, default: "openid"
      column :created_at, :date_time
      column :expires_at, :date_time
    end

    create_table :connect_client_session do
      column :id, :big_int, primary_key: true, auto: true
      column :session_id, :reference, to_table: :connect_session, to_column: :id
      column :client_id, :reference, to_table: :connect_client, to_column: :id
      column :created_at, :date_time
      column :notified_at, :date_time, null: true
    end
  end
end

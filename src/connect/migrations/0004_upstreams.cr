# SPDX-License-Identifier: AGPL-3.0-or-later

# Relais de l'authentification d'un cabinet (ADR-012 D9) : fournisseurs
# d'identité des cabinets, lien d'un compte à l'un d'eux.
class Migration::Connect::V0004 < Marten::Migration
  depends_on :connect, "0003_registrars"

  def plan
    create_table :connect_upstream do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 64, unique: true
      column :name, :string, max_size: 200
      column :issuer, :string, max_size: 500
      column :authorization_endpoint, :string, max_size: 500
      column :token_endpoint, :string, max_size: 500
      column :jwks_uri, :string, max_size: 500
      column :client_id, :string, max_size: 255
      column :client_secret, :string, max_size: 500
      column :domains, :text
      column :ceiling, :int, default: 2
      column :active, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end
    add_column :connect_account, :upstream, :string, max_size: 64, default: ""
    add_column :connect_account, :upstream_subject, :string, max_size: 255, default: ""
    execute("CREATE UNIQUE INDEX connect_account_upstream_subject ON connect_account (upstream, upstream_subject) " \
            "WHERE upstream <> ''", "DROP INDEX connect_account_upstream_subject")
  end
end

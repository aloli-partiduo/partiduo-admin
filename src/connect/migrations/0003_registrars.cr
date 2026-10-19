# SPDX-License-Identifier: AGPL-3.0-or-later

# Registraires (ADR-012) : l'exécutant de chaque serveur d'hébergement
# déclare le client des dossiers qu'il crée.
class Migration::Connect::V0003 < Marten::Migration
  depends_on :connect, "0002_audit_append_only"

  def plan
    create_table :connect_registrar do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 64, unique: true
      column :token_digest, :string, max_size: 64, unique: true
      column :active, :bool, default: true
      column :created_at, :date_time
      column :last_used_at, :date_time, null: true
    end
    add_column :connect_client, :registrar, :string, max_size: 64, default: ""
  end
end

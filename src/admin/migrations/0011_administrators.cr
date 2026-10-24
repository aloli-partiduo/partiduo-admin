# SPDX-License-Identifier: AGPL-3.0-or-later

# Administrateurs d'un dossier (D-ADM-017) : plusieurs par dossier, ajoutés
# et retirés par l'exécutant dans l'instance. Reprise : chaque dossier garde
# son administrateur actuel (`admin_dossier.admin_email`), premier de la
# liste — actif si l'instance existe, en attente si sa création n'a pas
# abouti.
#
# Brouillons des assistants (D-ADM-018) : un par utilisateur et par
# parcours, rien n'est créé avant la validation finale.
class Migration::Admin::V0011 < Marten::Migration
  depends_on :admin, "0010_session_locale"

  def plan
    create_table :admin_dossier_admin do
      column :id, :big_int, primary_key: true, auto: true
      column :dossier_id, :reference, to_table: :admin_dossier, to_column: :id
      column :email, :string, max_size: 254
      column :state, :string, max_size: 16, default: "pending"
      column :usable, :bool, null: true
      column :checked_at, :date_time, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end
    add_unique_constraint :admin_dossier_admin, :admin_dossier_admin_unique, [:dossier_id, :email]

    create_table :admin_wizard_draft do
      column :id, :big_int, primary_key: true, auto: true
      column :user_id, :reference, to_table: :admin_user, to_column: :id
      column :kind, :string, max_size: 16
      column :step, :int, default: 1
      column :reached, :int, default: 1
      column :data, :text, default: "{}"
      column :created_at, :date_time
      column :updated_at, :date_time
    end
    add_unique_constraint :admin_wizard_draft, :admin_wizard_draft_unique, [:user_id, :kind]

    execute(<<-SQL, "SELECT 1")
      INSERT INTO admin_dossier_admin (dossier_id, email, state, created_at, updated_at)
      SELECT id, lower(admin_email),
             CASE WHEN state IN ('creating', 'error') THEN 'pending' ELSE 'active' END,
             created_at, updated_at
        FROM admin_dossier
       WHERE admin_email <> ''
      SQL
  end
end

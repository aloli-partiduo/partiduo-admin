# SPDX-License-Identifier: AGPL-3.0-or-later

# DNS des dossiers (ADR-013) : identifiant chez OVH de l'enregistrement
# posé par l'administration (le seul qu'elle modifie ou efface) et état de
# la synchronisation ; vide pour une zone qu'elle ne gère pas.
class Migration::Admin::V0008 < Marten::Migration
  depends_on :admin, "0007_connect"

  def plan
    add_column :admin_dossier, :dns_record_id, :big_int, null: true
    add_column :admin_dossier, :dns_state, :string, max_size: 16, default: ""
  end
end

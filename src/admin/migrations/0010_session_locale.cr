# SPDX-License-Identifier: AGPL-3.0-or-later

# Langue d'une session ouverte par connect : claim `locale` du jeton
# d'identité, relu à chaque connexion (D-ADM-015) ; vide sans claim et pour
# les sessions existantes.
class Migration::Admin::V0010 < Marten::Migration
  depends_on :admin, "0009_dossier_kind"

  def plan
    add_column :admin_session, :locale, :string, max_size: 8, default: ""
  end
end

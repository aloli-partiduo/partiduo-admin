# SPDX-License-Identifier: AGPL-3.0-or-later

# connect (ADR-012 D4) : un utilisateur de l'administration est lié à une
# identité connect (`sub`) ; la session garde le `sid` de connect
# (déconnexion par canal arrière) ; l'invitation garde le lien de création
# du compte connect.
class Migration::Admin::V0007 < Marten::Migration
  depends_on :admin, "0006_exploitation_key"

  def plan
    add_column :admin_user, :connect_sub, :string, max_size: 64, null: true, unique: true
    add_column :admin_session, :federated_sid, :string, max_size: 64, null: true
    add_column :admin_invitation, :signup_url, :string, max_size: 1000, default: ""
  end
end

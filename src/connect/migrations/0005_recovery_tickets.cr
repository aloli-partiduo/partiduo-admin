# SPDX-License-Identifier: AGPL-3.0-or-later

# Récupération d'un compte par l'exploitation : une invitation (lien + code
# transmis par un autre canal) qui rouvre un compte existant, dont les
# facteurs ont été retirés, au lieu d'en créer un.
class Migration::Connect::V0005 < Marten::Migration
  depends_on :connect, "0004_upstreams"

  def plan
    add_column :connect_signup_ticket, :account_id, :reference, to_table: :connect_account, to_column: :id, null: true
  end
end

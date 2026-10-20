# SPDX-License-Identifier: AGPL-3.0-or-later

# Type de dossier (ADR-011 A3, A-PER-5) : `company` pour les dossiers
# existants, qui sont tous des dossiers d'entreprise ; jamais modifié après
# la création.
class Migration::Admin::V0009 < Marten::Migration
  depends_on :admin, "0008_dns"

  def plan
    add_column :admin_dossier, :kind, :string, max_size: 16, default: "company"
  end
end

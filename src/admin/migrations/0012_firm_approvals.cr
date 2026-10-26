# SPDX-License-Identifier: AGPL-3.0-or-later

# Validation des actions propres à une structure (D-ADM-023) : une demande
# vise un dossier *ou* une structure sans dossier (changements d'admins d'un
# cabinet, désactivation d'un admin, retour à la validation à une
# personne).
#
# Les demandes existantes ne changent pas : elles gardent leur dossier, et
# leur structure reste vide (celle du dossier fait foi). Deux contraintes de
# la base :
#
# * `admin_approval_target` : exactement une cible, dossier ou structure ;
# * `admin_approval_other_person` : une demande validée nomme qui l'a
#   validée, et à deux personnes c'est une autre que le demandeur, même par
#   une écriture SQL directe. Posée `NOT VALID` : elle vaut pour toute
#   écriture nouvelle sans relire les demandes passées.
class Migration::Admin::V0012 < Marten::Migration
  depends_on :admin, "0011_administrators"

  def plan
    add_column :admin_approval, :firm_id, :reference, to_table: :admin_firm, to_column: :id, null: true
    execute("ALTER TABLE admin_approval ALTER COLUMN dossier_id DROP NOT NULL",
      "ALTER TABLE admin_approval ALTER COLUMN dossier_id SET NOT NULL")
    execute(<<-SQL, "ALTER TABLE admin_approval DROP CONSTRAINT admin_approval_target")
      ALTER TABLE admin_approval ADD CONSTRAINT admin_approval_target
        CHECK ((dossier_id IS NULL) <> (firm_id IS NULL))
      SQL
    execute(<<-SQL, "ALTER TABLE admin_approval DROP CONSTRAINT admin_approval_other_person")
      ALTER TABLE admin_approval ADD CONSTRAINT admin_approval_other_person
        CHECK (state <> 'approved'
               OR (decided_by_id IS NOT NULL AND (mode = 'single' OR decided_by_id <> requested_by_id)))
        NOT VALID
      SQL
  end
end

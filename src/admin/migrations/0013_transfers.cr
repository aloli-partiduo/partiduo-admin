# SPDX-License-Identifier: AGPL-3.0-or-later

# Transfert d'un dossier vers une autre structure (D-ADM-027) : une demande
# `transfer` vise le dossier *et* la structure d'accueil ; chaque structure
# donne son accord selon son propre réglage (une ou deux personnes), une
# ligne par accord.
#
# * `admin_approval_target` : exactement une cible, sauf un transfert, qui
#   a les deux (dossier transféré, structure d'accueil).
# * `admin_approval_consent` : un accord par personne et par demande ; la
#   base refuse l'accord du demandeur, celui d'une structure qui n'est ni
#   l'origine ni l'accueil, celui d'une demande close, et la validation d'un
#   transfert sans accord des deux structures — même par une écriture SQL
#   directe.
class Migration::Admin::V0013 < Marten::Migration
  depends_on :admin, "0012_firm_approvals"

  def plan
    execute("ALTER TABLE admin_approval DROP CONSTRAINT admin_approval_target", <<-SQL)
      ALTER TABLE admin_approval ADD CONSTRAINT admin_approval_target
        CHECK ((dossier_id IS NULL) <> (firm_id IS NULL))
      SQL
    execute(<<-SQL, "ALTER TABLE admin_approval DROP CONSTRAINT admin_approval_target")
      ALTER TABLE admin_approval ADD CONSTRAINT admin_approval_target
        CHECK ((dossier_id IS NULL) <> (firm_id IS NULL)
               OR (kind = 'transfer' AND dossier_id IS NOT NULL AND firm_id IS NOT NULL))
      SQL

    create_table :admin_approval_consent do
      column :id, :big_int, primary_key: true, auto: true
      column :approval_id, :reference, to_table: :admin_approval, to_column: :id
      column :firm_id, :reference, to_table: :admin_firm, to_column: :id
      column :side, :string, max_size: 16
      column :user_id, :reference, to_table: :admin_user, to_column: :id
      column :mode, :string, max_size: 8
      column :created_at, :date_time
    end
    add_unique_constraint :admin_approval_consent, :admin_approval_consent_unique, [:approval_id, :user_id]

    execute(<<-SQL, "DROP FUNCTION admin_approval_consent_check()")
      CREATE FUNCTION admin_approval_consent_check() RETURNS trigger AS $$
      DECLARE
        target admin_approval%ROWTYPE;
        origin BIGINT;
      BEGIN
        SELECT * INTO target FROM admin_approval WHERE id = NEW.approval_id;
        IF target.kind <> 'transfer' OR target.state <> 'pending' THEN
          RAISE EXCEPTION 'accord refusé : demande close ou qui n''est pas un transfert (D-ADM-027)'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.user_id = target.requested_by_id THEN
          RAISE EXCEPTION 'accord refusé : le demandeur ne donne pas son propre accord (D-ADM-027)'
            USING ERRCODE = 'check_violation';
        END IF;
        SELECT firm_id INTO origin FROM admin_dossier WHERE id = target.dossier_id;
        IF NOT ((NEW.side = 'origin' AND NEW.firm_id = origin)
                OR (NEW.side = 'destination' AND NEW.firm_id = target.firm_id)) THEN
          RAISE EXCEPTION 'accord refusé : structure étrangère au transfert (D-ADM-027)'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      SQL
    execute(<<-SQL, "DROP TRIGGER admin_approval_consent_check ON admin_approval_consent")
      CREATE TRIGGER admin_approval_consent_check
        BEFORE INSERT ON admin_approval_consent
        FOR EACH ROW EXECUTE FUNCTION admin_approval_consent_check()
      SQL

    execute(<<-SQL, "DROP FUNCTION admin_approval_transfer_check()")
      CREATE FUNCTION admin_approval_transfer_check() RETURNS trigger AS $$
      BEGIN
        IF NEW.kind = 'transfer' AND NEW.state = 'approved' AND OLD.state <> 'approved' AND (
             NOT EXISTS (SELECT 1 FROM admin_approval_consent c WHERE c.approval_id = NEW.id AND c.side = 'origin')
             OR NOT EXISTS (SELECT 1 FROM admin_approval_consent c WHERE c.approval_id = NEW.id AND c.side = 'destination')) THEN
          RAISE EXCEPTION 'transfert refusé : accord des deux structures exigé (D-ADM-027)'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      SQL
    execute(<<-SQL, "DROP TRIGGER admin_approval_transfer_check ON admin_approval")
      CREATE TRIGGER admin_approval_transfer_check
        BEFORE UPDATE ON admin_approval
        FOR EACH ROW EXECUTE FUNCTION admin_approval_transfer_check()
      SQL
  end
end

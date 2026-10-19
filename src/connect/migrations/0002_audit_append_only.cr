# SPDX-License-Identifier: AGPL-3.0-or-later

# Journal en ajout seul (ADR-012 D7) : un déclencheur refuse toute
# modification et toute suppression, quel que soit le chemin (application,
# psql). Index de lecture du journal d'un compte et des sessions d'un compte.
class Migration::Connect::V0002 < Marten::Migration
  depends_on :connect, "0001_initial"

  def plan
    execute(<<-SQL, "DROP FUNCTION connect_audit_entry_immutable()")
      CREATE FUNCTION connect_audit_entry_immutable() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'connect_audit_entry est en ajout seul (ADR-012 D7)'
          USING ERRCODE = 'insufficient_privilege';
      END;
      $$ LANGUAGE plpgsql
      SQL
    execute(<<-SQL, "DROP TRIGGER connect_audit_entry_immutable ON connect_audit_entry")
      CREATE TRIGGER connect_audit_entry_immutable
        BEFORE UPDATE OR DELETE ON connect_audit_entry
        FOR EACH ROW EXECUTE FUNCTION connect_audit_entry_immutable()
      SQL
    execute("CREATE INDEX connect_audit_entry_account_created ON connect_audit_entry (account_id, created_at)",
      "DROP INDEX connect_audit_entry_account_created")
    execute("CREATE INDEX connect_signup_ticket_email ON connect_signup_ticket (email)",
      "DROP INDEX connect_signup_ticket_email")
  end
end

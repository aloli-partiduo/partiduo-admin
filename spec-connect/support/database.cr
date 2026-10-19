# SPDX-License-Identifier: AGPL-3.0-or-later

module ConnectSpec
  # Schéma construit *par les migrations* (déclencheur du journal compris).
  def self.migrate_fresh! : Nil
    connection = Marten::DB::Connection.default
    name = Marten.settings.databases.first.name.to_s
    raise "Base de test refusée : « #{name} » ne contient pas « test » (voir DATABASE_URL)." unless name.includes?("test")
    connection.open do |db|
      db.exec("DROP SCHEMA public CASCADE")
      db.exec("CREATE SCHEMA public")
    end
    Marten::DB::Management::Migrations::Runner.new(connection).execute
  end

  module Backchannel
    class_getter sent = [] of {String, String}
  end
end

Spec.before_suite { ConnectSpec.migrate_fresh! }

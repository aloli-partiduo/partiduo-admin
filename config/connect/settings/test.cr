# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :test do |config|
  # Base de test : DATABASE_URL (nom contenant « test »), par défaut
  # postgres:///partiduo_connect_test?host=/tmp.
  config.database do |db|
    db.from_url(PartiduoConnect::Config.database_url)
  end
  config.cache_store = Marten::Cache::Store::Null.new
  config.emailing.backend = Marten::Emailing::Backend::Development.new(collect_emails: true, print_emails: false)
end

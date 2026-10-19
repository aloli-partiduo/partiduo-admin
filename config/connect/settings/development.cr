# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :development do |config|
  config.debug = true
  config.host = "127.0.0.1"
  config.port = PartiduoConnect::Config.port
  config.emailing.backend = Marten::Emailing::Backend::Development.new(print_emails: true)
end

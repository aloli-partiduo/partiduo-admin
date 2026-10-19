# SPDX-License-Identifier: AGPL-3.0-or-later

require "./config"
require "./models/client"
require "./models/account"
require "./models/oidc"
require "./services/secrets"
require "./services/audit"
require "./services/signing_keys"
require "./services/mailer"
require "./services/auth"
require "./services/passkeys"
require "./services/backchannel"
require "./services/oidc"
require "./services/signup"
require "./handlers/base"
require "./handlers/auth_handlers"
require "./handlers/account_handlers"
require "./handlers/oidc_handlers"

module PartiduoConnect
  # Lue à la compilation dans `shard.yml` (même numéro que l'administration,
  # même dépôt).
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  MIME.register(".ico", "image/x-icon")
  MIME.register(".webmanifest", "application/manifest+json")

  # Application Marten de `connect` (ADR-012) : modèles (tables
  # `connect_…`), gabarits (`templates/connect/`), fichiers statiques
  # (`assets/connect/`), libellés (`locales/`).
  class App < Marten::App
    label "connect"
  end
end

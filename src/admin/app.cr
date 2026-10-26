# SPDX-License-Identifier: AGPL-3.0-or-later

require "../shared/protocol"
require "../shared/backup_crypto"
require "../shared/licences"
require "../shared/qr_svg"
require "./config"
require "./models/organization"
require "./models/security"
require "./models/fleet"
require "./models/administration"
require "./services/secrets"
require "./services/audit"
require "./services/auth"
require "./services/passkeys"
require "./services/connect"
require "./services/connect_login"
require "./services/access"
require "./services/mailer"
require "./services/mail_backend"
require "./services/tasks"
require "./services/task_filter"
require "./services/effects"
require "./services/catalog"
require "./services/fleet"
require "./services/backup_encryption"
require "./services/approval_mode"
require "./services/approvals"
require "./services/supervision"
require "./services/dns"
require "./services/directory"
require "./services/administrators"
require "./services/firms"
require "./services/wizards"
require "./services/wizard_operations"
require "./handlers/concerns/pieces"
require "./handlers/concerns/base"
require "./handlers/concerns/wizard_form"
require "./handlers/concerns/wizard_operation_form"
require "./handlers/auth_handlers"
require "./handlers/connect_handlers"
require "./handlers/dossier_handlers"
require "./handlers/fleet_handlers"
require "./handlers/directory_handlers"
require "./handlers/encryption_handlers"
require "./handlers/approval_mode_handlers"
require "./handlers/administrator_handlers"
require "./handlers/wizard_handlers"
require "./handlers/agent_api"

module PartiduoAdmin
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Types des favicons et du manifeste web (`assets/admin/brand/`) : absents
  # des types par défaut de Crystal, et de la base du système sur certains
  # hôtes. Marten sert les fichiers statiques d'après `MIME.from_filename`.
  MIME.register(".ico", "image/x-icon")
  MIME.register(".webmanifest", "application/manifest+json")

  # Application Marten de l'administration du parc (ADR-008) : modèles,
  # gabarits (`templates/admin/`), fichiers statiques (`assets/admin/`),
  # libellés (`locales/`).
  class App < Marten::App
    label "admin"
  end
end

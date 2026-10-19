# SPDX-License-Identifier: AGPL-3.0-or-later

# `crystal run connect_manage.cr -- <commande>` : migrate, client, invite,
# signing-key, account.
require "./src/connect_cli"

Marten.setup
Marten::CLI.run

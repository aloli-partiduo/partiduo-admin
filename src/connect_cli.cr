# SPDX-License-Identifier: AGPL-3.0-or-later

# Ligne de commande Marten de `connect` : migrations et commandes `client`,
# `invite`, `signing-key`, `account`.
require "./connect/partiduo_connect"
require "marten/cli"
require "./connect/migrations/**"
require "./connect/commands/**"

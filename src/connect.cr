# SPDX-License-Identifier: AGPL-3.0-or-later

# Serveur HTTP de `connect` : `crystal run src/connect.cr` (ou le binaire
# `partiduo-connect` produit par `shards build`).
require "./connect/partiduo_connect"

Marten.start

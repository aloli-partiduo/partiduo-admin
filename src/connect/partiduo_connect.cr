# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée de `connect` (ADR-012) : fournisseur d'identité commun aux
# dossiers et à l'administration. Troisième programme du dépôt, déployé à
# part (`connect.<domaine>`), avec sa propre base ; il ne charge rien de
# l'administration.
require "marten"
require "pg"

require "./app"

require "../../config/connect/settings/base"
require "../../config/connect/settings/**"
require "../../config/connect/routes"

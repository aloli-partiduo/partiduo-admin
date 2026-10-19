# SPDX-License-Identifier: AGPL-3.0-or-later

# Specs de `connect` (ADR-012) : programme à part, avec sa configuration
# Marten et sa base (`partiduo_connect_test`) ; lancées à part des specs de
# l'administration : `crystal spec spec-connect`.
ENV["MARTEN_ENV"] = "test"
ENV["PARTIDUO_DOMAIN"] = "partiduo.localhost"

require "spec"

require "../src/connect_cli"
require "marten/spec"

require "./support/**"

Log.setup(:warn)

# Horloge figée : échéances des codes, des sessions et des invitations.
SPEC_NOW = Time.utc(2026, 10, 20, 10, 0, 0)
PartiduoConnect::Config.clock = -> { SPEC_NOW }

# Déconnexion par canal arrière : sans réseau, envois relevés.
PartiduoConnect::Backchannel.synchronous = true
PartiduoConnect::Backchannel.sender = ->(uri : String, token : String) do
  ConnectSpec::Backchannel.sent << {uri, token}
  true
end

Spec.before_each { ConnectSpec::Backchannel.sent.clear }

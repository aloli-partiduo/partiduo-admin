# SPDX-License-Identifier: AGPL-3.0-or-later

require "./spec_helper"

# Registraires (ADR-012) : l'exécutant d'un serveur déclare le client de
# chaque dossier qu'il crée, aux adresses fixées par connect.
describe "connect : registraires" do
  it "déclare le client d'un dossier, puis le redéclare avec un nouveau secret" do
    created = PartiduoConnect::Registrars.create("serveur-#{ConnectSpec.next_number}")
    auth = {"Authorization" => "Bearer #{created.token}"}
    first = JSON.parse(ConnectSpec::Browser.new.post("/api/v1/clients", {"host" => "pipo.partiduo.localhost"}, auth).content)
    first["client_id"].as_s.should eq("pipo.partiduo.localhost")
    client = PartiduoConnect::Client.get!(client_id: "pipo.partiduo.localhost")
    client.redirect_uri_list.should eq(["http://pipo.partiduo.localhost:8000/login/federated/connect/callback"])
    client.backchannel_logout_uri.should eq("http://pipo.partiduo.localhost:8000/login/federated/connect/backchannel-logout")

    second = JSON.parse(ConnectSpec::Browser.new.post("/api/v1/clients", {"host" => "pipo.partiduo.localhost"}, auth).content)
    second["client_secret"].as_s.should_not eq(first["client_secret"].as_s)
    PartiduoConnect::Client.filter(client_id: "pipo.partiduo.localhost").count.should eq(1)

    ConnectSpec::Browser.new.post("/api/v1/clients", {"host" => "pipo.partiduo.localhost", "action" => "disable"}, auth)
    PartiduoConnect::Client.get!(client_id: "pipo.partiduo.localhost").active.should be_false
  end

  it "refuse un jeton inconnu, un nom hors du domaine, un nom réservé, le client d'un autre" do
    created = PartiduoConnect::Registrars.create("serveur-#{ConnectSpec.next_number}")
    other = PartiduoConnect::Registrars.create("serveur-#{ConnectSpec.next_number}")
    auth = {"Authorization" => "Bearer #{created.token}"}
    ConnectSpec::Browser.new.post("/api/v1/clients", {"host" => "a.partiduo.localhost"}, {"Authorization" => "Bearer faux"})
      .status.should eq(401)
    %w[pirate.example.net connect.partiduo.localhost a.b.partiduo.localhost].each do |host|
      ConnectSpec::Browser.new.post("/api/v1/clients", {"host" => host}, auth).status.should eq(400)
    end
    ConnectSpec::Browser.new.post("/api/v1/clients", {"host" => "dossier-a.partiduo.localhost"}, auth).status.should eq(200)
    ConnectSpec::Browser.new.post("/api/v1/clients", {"host" => "dossier-a.partiduo.localhost"},
      {"Authorization" => "Bearer #{other.token}"}).status.should eq(400)
  end
end

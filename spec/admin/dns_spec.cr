# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# DNS des dossiers (ADR-013) : l'administration seule pose, bascule et
# efface le nom de chaque dossier, un CNAME vers son serveur.

private def input(firm, server, payer, slug = "nom-dns")
  PartiduoAdmin::Fleet::DossierInput.new(slug: slug, label: "Nom DNS SARL", regime: "fr", siren: "732829320",
    modules: ["accounting"], extensions: [] of String, admin_email: "patron@demo.fr",
    server_id: PartiduoAdmin.id?(server.pk), firm_id: PartiduoAdmin.id?(firm.pk), payer_id: PartiduoAdmin.id?(payer.pk))
end

private def finish(task, ok = true, result = {} of String => String)
  task.state = "running"
  task.save!
  PartiduoAdmin::Tasks.finish(task, ok, JSON.parse(result.to_json), ok ? "" : "échec", ["fait"], SPEC_NOW)
  task.reload
end

describe PartiduoAdmin::Dns do
  it "pose le CNAME avant la création et le passe à l'exécutant" do
    AdminDnsSpec.with_dns do |zone|
      firm = AdminSpec.firm
      server, _ = AdminSpec.server("srv-a")
      admin = AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)
      dossier = PartiduoAdmin::Fleet.create_dossier(admin, input(firm, server, AdminSpec.payer(firm))).value!
      dossier.dns_state.should eq("ok")
      zone.target_of("nom-dns").should eq("srv-a.example.net.")
      zone.calls.should eq(["create nom-dns srv-a.example.net. 300", "refresh partiduo.localhost"])
      task = PartiduoAdmin::Task.get!(dossier_id: dossier.pk)
      task.params_json["dns_target"].should eq("srv-a.example.net")
      PartiduoAdmin::AuditEntry.filter(action: "dns.create").count.should eq(1)
    end
  end

  it "laisse la zone à joker intacte : rien d'attendu par l'exécutant" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    admin = AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)
    dossier = PartiduoAdmin::Fleet.create_dossier(admin, input(firm, server, AdminSpec.payer(firm), "joker")).value!
    dossier.dns_state.should eq("")
    PartiduoAdmin::Task.get!(dossier_id: dossier.pk).params_json["dns_target"].should eq("")
  end

  it "n'écrase jamais un nom qu'elle n'a pas posé ; la planification reprend" do
    AdminDnsSpec.with_dns do |zone|
      firm = AdminSpec.firm
      server, _ = AdminSpec.server("srv-b")
      zone.foreign("partiduo.localhost", "pris", "A", "192.0.2.1")
      admin = AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)
      dossier = PartiduoAdmin::Fleet.create_dossier(admin, input(firm, server, AdminSpec.payer(firm), "pris")).value!
      dossier.dns_state.should eq("error")
      zone.calls.should be_empty
      zone.target_of("pris").should eq("192.0.2.1")
      PartiduoAdmin::Alert.filter(kind: "dns", dossier_id: dossier.pk, resolved_at__isnull: true).exists?.should be_true

      # Le nom libéré (retiré à la main), la planification le pose.
      zone.records.reject! { |_, record| record[1] == "pris" }
      PartiduoAdmin::Scheduler.run(SPEC_NOW).dns.should eq(1)
      dossier.reload.dns_state.should eq("ok")
      zone.target_of("pris").should eq("srv-b.example.net.")
      PartiduoAdmin::Alert.filter(kind: "dns", dossier_id: dossier.pk, resolved_at__isnull: true).exists?.should be_false
    end
  end

  it "reprend après une panne d'OVH" do
    AdminDnsSpec.with_dns do |zone|
      firm = AdminSpec.firm
      server, _ = AdminSpec.server("srv-c")
      zone.down = true
      admin = AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)
      dossier = PartiduoAdmin::Fleet.create_dossier(admin, input(firm, server, AdminSpec.payer(firm), "panne")).value!
      dossier.dns_state.should eq("error")
      zone.down = false
      PartiduoAdmin::Dns.resync(SPEC_NOW).should eq(1)
      dossier.reload.dns_state.should eq("ok")
      zone.target_of("panne").should eq("srv-c.example.net.")
    end
  end

  it "efface le nom une fois le dossier supprimé" do
    AdminDnsSpec.with_dns do |zone|
      firm = AdminSpec.firm
      server, _ = AdminSpec.server("srv-d")
      dossier = AdminSpec.dossier(firm, server, slug: "essai-dns", package: "devel")
      PartiduoAdmin::Dns.request(dossier).should be_true
      zone.target_of("essai-dns").should eq("srv-d.example.net.")
      requester = AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)
      second = AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)
      approval = PartiduoAdmin::Approvals.request_delete(requester, dossier, "dossier d'essai").value!
      finish(PartiduoAdmin::Approvals.approve(second, approval).value!)
      dossier.reload.state.should eq("deleted")
      dossier.dns_state.should eq("removed")
      dossier.dns_record_id.should be_nil
      zone.target_of("essai-dns").should be_nil
      PartiduoAdmin::AuditEntry.filter(action: "dns.delete").count.should eq(1)
    end
  end

  it "déplace un dossier suspendu : super-admin, nom basculé, restauration sur le nouveau serveur" do
    AdminDnsSpec.with_dns do |zone|
      firm = AdminSpec.firm
      origin, _ = AdminSpec.server("srv-e")
      destination, _ = AdminSpec.server("srv-f")
      dossier = AdminSpec.dossier(firm, origin, slug: "demenage")
      PartiduoAdmin::Dns.request(dossier)
      AdminSpec.backup(dossier)
      super_admin = AdminSpec.super_admin
      firm_admin = AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)

      # Actif : refusé ; restauration « déplacement » aussi.
      PartiduoAdmin::Fleet.move(super_admin, dossier, PartiduoAdmin.id?(destination.pk), "nouveau serveur").errors["base"]
        .should eq(["admin.errors.dossier.state"])
      PartiduoAdmin::Fleet.restore(super_admin, dossier, SPEC_NOW, "move").errors["base"]
        .should eq(["admin.errors.dossier.state"])

      dossier.state = "suspended"
      dossier.save!
      PartiduoAdmin::Fleet.move(firm_admin, dossier, PartiduoAdmin.id?(destination.pk), "nouveau serveur").errors["base"]
        .should eq(["admin.errors.forbidden"])
      PartiduoAdmin::Fleet.move(super_admin, dossier, PartiduoAdmin.id?(origin.pk), "nouveau serveur").errors["server_id"]
        .should eq(["admin.errors.dossier.move_server"])

      PartiduoAdmin::Fleet.move(super_admin, dossier, PartiduoAdmin.id?(destination.pk), "nouveau serveur").ok?.should be_true
      dossier.reload.server_id.should eq(destination.pk)
      dossier.dns_state.should eq("ok")
      zone.target_of("demenage").should eq("srv-f.example.net.")
      zone.calls.should contain("update demenage srv-f.example.net.")
      PartiduoAdmin::AuditEntry.filter(action: "dossier.move").count.should eq(1)

      PartiduoAdmin::Fleet.restore(firm_admin, dossier, SPEC_NOW, "move").errors["base"]
        .should eq(["admin.errors.forbidden"])
      task = PartiduoAdmin::Fleet.restore(super_admin, dossier, SPEC_NOW, "move").value!
      task.server_id.should eq(destination.pk)
      task.params_json["target"].should eq("move")
      task.params_json["dns_target"].should eq("srv-f.example.net")
      finish(task, result: {"version" => "0.1.1"})
      dossier.reload.state.should eq("active")
    end
  end

  it "réserve les noms d'infrastructure de la zone" do
    %w[admin connect mail www].each { |slug| PartiduoAdmin::Protocol.valid_slug?(slug).should be_false }
  end
end

# Transport OVH simulé : chaque requête retenue, réponses de l'API.
private class OvhTransport < OvhApi::HttpTransport
  getter requests = [] of {String, String, String}

  def request(method : String, url : String, headers : HTTP::Headers, body : String) : {Int32, String}
    requests << {method, url, body}
    path = url.sub("https://eu.api.ovh.com/1.0", "")
    case {method, path}
    when {"GET", "/auth/time"}                                        then {200, Time.utc.to_unix.to_s}
    when {"GET", "/domain/zone/partiduo.app/record?subDomain=client"} then {200, "[7]"}
    when {"GET", "/domain/zone/partiduo.app/record/7"}
      {200, {"id" => 7, "zone" => "partiduo.app", "subDomain" => "client", "fieldType" => "CNAME",
             "target" => "srv.aloli.net.", "ttl" => 300}.to_json}
    when {"POST", "/domain/zone/partiduo.app/record"}
      {200, {"id" => 8, "zone" => "partiduo.app", "subDomain" => "neuf", "fieldType" => "CNAME",
             "target" => "srv.aloli.net.", "ttl" => 300}.to_json}
    else {200, ""}
    end
  end
end

describe PartiduoAdmin::Dns::OvhProvider do
  it "parle à l'API OVH des enregistrements de la zone, requêtes signées" do
    transport = OvhTransport.new
    client = OvhApi::Client.new(application_key: "ak", application_secret: "as", consumer_key: "ck", transport: transport)
    provider = PartiduoAdmin::Dns::OvhProvider.new(client)
    provider.entries("partiduo.app", "client").should eq([PartiduoAdmin::Dns::Entry.new(7_i64, "CNAME", "srv.aloli.net.")])
    provider.create("partiduo.app", "neuf", "srv.aloli.net.", 300).should eq(8_i64)
    provider.update("partiduo.app", 7_i64, "autre.aloli.net.", 300)
    provider.delete("partiduo.app", 7_i64)
    provider.refresh("partiduo.app")
    calls = transport.requests.reject { |request| request[1].ends_with?("/auth/time") }
    calls.map { |request| "#{request[0]} #{request[1].sub("https://eu.api.ovh.com/1.0", "")}" }.should eq([
      "GET /domain/zone/partiduo.app/record?subDomain=client",
      "GET /domain/zone/partiduo.app/record/7",
      "POST /domain/zone/partiduo.app/record",
      "PUT /domain/zone/partiduo.app/record/7",
      "DELETE /domain/zone/partiduo.app/record/7",
      "POST /domain/zone/partiduo.app/refresh",
    ])
    JSON.parse(calls[2][2]).should eq(JSON.parse({"fieldType" => "CNAME", "subDomain" => "neuf", "target" => "srv.aloli.net.", "ttl" => 300}.to_json))
  end

  it "lit la clé de l'administration dans son fichier" do
    path = File.tempname("ovh", ".json")
    File.write(path, {"application_key" => "ak", "application_secret" => "as", "consumer_key" => "ck"}.to_json)
    PartiduoAdmin::Dns::OvhProvider.from_file(path).should be_a(PartiduoAdmin::Dns::OvhProvider)
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end

describe "Interface de l'administration : nom DNS et déplacement (ADR-013)" do
  it "montre l'état du nom et, à un super-admin, le déplacement d'un dossier suspendu" do
    AdminDnsSpec.with_dns do |zone|
      firm = AdminSpec.firm
      origin, _ = AdminSpec.server("srv-g")
      destination, _ = AdminSpec.server("srv-h")
      dossier = AdminSpec.dossier(firm, origin, slug: "ecran", state: "suspended")
      PartiduoAdmin::Dns.request(dossier)
      browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.super_admin))
      page = browser.get("/dossiers/#{dossier.pk}").html
      page.should contain(I18n.t("admin.dns.states.ok"))
      page.should contain(%(action="/dossiers/#{dossier.pk}/move"))
      page.should contain(%(<option value="move">))
      page.should contain("srv-h (srv-h.example.net)")

      browser.post("/dossiers/#{dossier.pk}/move", {"server_id" => destination.pk.to_s, "reason" => "nouveau serveur"})
      dossier.reload.server_id.should eq(destination.pk)
      zone.target_of("ecran").should eq("srv-h.example.net.")

      firm_admin = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)))
      firm_admin.get("/dossiers/#{dossier.pk}").html.should_not contain("/move")
    end
  end
end

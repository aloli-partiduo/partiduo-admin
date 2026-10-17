# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def task(kind : String, server : PartiduoAdmin::Server, dossier : PartiduoAdmin::Dossier? = nil,
                 state : String = "succeeded", by : String = "system") : PartiduoAdmin::Task
  PartiduoAdmin::Task.create!(kind: kind, server: server, dossier: dossier, state: state, requested_by_label: by)
end

describe PartiduoAdmin::TaskFilter do
  it "filtre chaque colonne et ignore une valeur inconnue ou mal formée" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    pipo = AdminSpec.dossier(firm, server, slug: "pipo")
    autre = AdminSpec.dossier(firm, server, slug: "autre")
    creation = task("instance.create", server, pipo, "failed", "gerant@pipo.fr")
    task("backup.run", server, autre)
    3.times { task("supervision.check", server) }
    scope = PartiduoAdmin::Task.all
    count = ->(filter : PartiduoAdmin::TaskFilter) { filter.apply(scope).count }

    count.call(PartiduoAdmin::TaskFilter.new).should eq(5)
    count.call(PartiduoAdmin::TaskFilter.new(id: "##{creation.pk}")).should eq(1)
    count.call(PartiduoAdmin::TaskFilter.new(kind: "supervision.check")).should eq(3)
    count.call(PartiduoAdmin::TaskFilter.new(kind: PartiduoAdmin::TaskFilter::WITHOUT_SUPERVISION)).should eq(2)
    count.call(PartiduoAdmin::TaskFilter.new(dossier: "PIP")).should eq(1)
    count.call(PartiduoAdmin::TaskFilter.new(state: "failed")).should eq(1)
    count.call(PartiduoAdmin::TaskFilter.new(requested_by: "gerant")).should eq(1)
    today = Time.utc.to_s("%F")
    count.call(PartiduoAdmin::TaskFilter.new(from: today, to: today)).should eq(5)
    count.call(PartiduoAdmin::TaskFilter.new(to: (Time.utc - 2.days).to_s("%F"))).should eq(0)
    # Valeurs inconnues ou mal formées : ignorées, pas d'erreur.
    count.call(PartiduoAdmin::TaskFilter.new(id: "x", kind: "shell.exec", state: "perdu", from: "hier", to: "2026-13-45")).should eq(5)
  end

  it "garde les filtres dans les liens de pagination" do
    filter = PartiduoAdmin::TaskFilter.new(kind: "-supervision", dossier: "pipo")
    filter.active.should be_true
    filter.url(1).should eq("/tasks?kind=-supervision&dossier=pipo")
    filter.url(3).should eq("/tasks?kind=-supervision&dossier=pipo&page=3")
    PartiduoAdmin::TaskFilter.new.url(2).should eq("/tasks?page=2")
    PartiduoAdmin::TaskFilter.new.active.should be_false
  end
end

describe "Interface de l'administration : file des tâches" do
  it "pagine par 50, filtre par colonne et retrouve une tâche ancienne noyée sous les supervisions" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    pipo = AdminSpec.dossier(firm, server, slug: "pipo")
    ancienne = task("instance.create", server, pipo, "failed")
    120.times { task("supervision.check", server) }
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.super_admin))

    premiere = browser.get("/tasks").html
    premiere.should contain("121 tâche(s) — page 1 sur 3")
    premiere.should contain(%(href="/tasks?page=2"))
    premiere.should_not contain(%(href="/tasks/#{ancienne.pk}"))
    browser.get("/tasks?page=3").html.should contain(%(href="/tasks/#{ancienne.pk}"))
    # Au-delà de la dernière page : la dernière.
    browser.get("/tasks?page=99").html.should contain("page 3 sur 3")

    filtree = browser.get("/tasks?kind=-supervision&state=failed").html
    filtree.should contain(%(href="/tasks/#{ancienne.pk}"))
    filtree.should contain("1 tâche(s) — page 1 sur 1")
    filtree.should contain(%(<option value="-supervision" selected>))
    filtree.should contain(%(<option value="failed" selected>))
    filtree.should contain("Réinitialiser")
    browser.get("/tasks?dossier=pipo").html.should contain(%(href="/tasks/#{ancienne.pk}"))
  end
end

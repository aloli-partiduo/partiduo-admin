# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Alertes : clôture" do
  it "se ferme à la main par un administrateur, avec une trace d'audit" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    pipo = AdminSpec.dossier(firm, server, slug: "pipo-alerte")
    alert = PartiduoAdmin::Alerts.open("test_restore_failed", "danger", dossier: pipo, detail: "backup 1")
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))

    page = browser.get("/alerts").html
    page.should contain(%(action="/alerts/#{alert.pk}/close"))
    page.should contain(%(href="/dossiers/#{pipo.pk}"))

    manager = AdminSpec.user(PartiduoAdmin::Config::FILE_MANAGER, firm)
    PartiduoAdmin::Assignment.create!(user: manager, dossier: pipo)
    AdminSpec::Browser.new(token: AdminSpec.session(manager)).post("/alerts/#{alert.pk}/close").status.should eq(403)
    alert.reload.resolved_at.should be_nil

    browser.post("/alerts/#{alert.pk}/close").status.should eq(302)
    alert.reload.resolved_at.should_not be_nil
    PartiduoAdmin::AuditEntry.filter(action: "alert.close").count.should eq(1)
    browser.get("/alerts").html.should contain("Aucune alerte ouverte.")
  end

  it "se ferme d'elle-même quand une restauration test du dossier réussit" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    pipo = AdminSpec.dossier(firm, server, slug: "pipo-reussite")
    backup = AdminSpec.backup(pipo)
    alert = PartiduoAdmin::Alerts.open("test_restore_failed", "danger", dossier: pipo, detail: "backup #{backup.pk}")
    task = PartiduoAdmin::Fleet.test_restore(AdminSpec.super_admin, backup).value!
    task.state = "running"
    task.save!
    PartiduoAdmin::Tasks.finish(task, true, JSON.parse(%({"check":"full"})))
    alert.reload.resolved_at.should_not be_nil
  end
end

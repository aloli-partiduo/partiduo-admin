# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Type de dossier choisi à la création (A-PER-5, ADR-011 A3, D-FOY-010 de
# partiduo-app) : entreprise ou foyer, retenu par le dossier, transmis à
# l'exécutant (`kind` des paramètres de `instance.create`, protocole 3.1.0)
# puis à `partiduo-provision --kind`. Un foyer n'a que la Comptabilité,
# ni SIREN ni TVA.

private def kind_input(firm, server, payer, slug : String, kind : String, modules = ["accounting"],
                       siren = "", vat = "") : PartiduoAdmin::Fleet::DossierInput
  PartiduoAdmin::Fleet::DossierInput.new(slug: slug, label: "Foyer Martin", regime: "fr", admin_email: "martin@foyer.fr",
    siren: siren, vat_number: vat, modules: modules, server_id: PartiduoAdmin.id?(server.pk),
    firm_id: PartiduoAdmin.id?(firm.pk), payer_id: PartiduoAdmin.id?(payer.pk), kind: kind)
end

describe "Type de dossier (A-PER-5)" do
  it "retient un foyer et le transmet à l'exécutant, sans SIREN ni TVA" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = PartiduoAdmin::Fleet.create_dossier(AdminSpec.super_admin,
      kind_input(firm, server, AdminSpec.payer(firm), "foyer-martin", "household", siren: "732829320", vat: "FR44732829320")).value!
    dossier.kind.should eq("household")
    dossier.siren.should eq("")
    dossier.vat_number.should eq("")
    task = PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "instance.create").first || fail("tâche absente")
    params = task.params_json
    params["kind"].as_s.should eq("household")
    params["siren"].as_s.should eq("")
    PartiduoAdmin::AuditEntry.filter(action: "dossier.create").order("-id").first.try(&.detail).to_s.should contain("household")
  end

  it "garde l'entreprise par défaut, et la transmet" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    input = PartiduoAdmin::Fleet::DossierInput.new(slug: "entreprise", label: "Entreprise SAS", regime: "fr",
      admin_email: "patron@entreprise.fr", server_id: PartiduoAdmin.id?(server.pk), firm_id: PartiduoAdmin.id?(firm.pk),
      payer_id: PartiduoAdmin.id?(AdminSpec.payer(firm).pk))
    dossier = PartiduoAdmin::Fleet.create_dossier(AdminSpec.super_admin, input).value!
    dossier.kind.should eq("company")
    PartiduoAdmin::Task.filter(dossier_id: dossier.pk).first.try(&.params_json).try(&.["kind"]?).try(&.as_s).should eq("company")
  end

  it "refuse un type inconnu et un foyer avec d'autres modules que la Comptabilité" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    payer = AdminSpec.payer(firm)
    root = AdminSpec.super_admin
    PartiduoAdmin::Fleet.create_dossier(root, kind_input(firm, server, payer, "type-x", "association")).errors["kind"]
      .should eq(["admin.errors.dossier.kind"])
    PartiduoAdmin::Fleet.create_dossier(root, kind_input(firm, server, payer, "foyer-x", "household", ["accounting", "invoicing"]))
      .errors["family.management"].should eq(["pieces:kind_excludes|piece=invoicing|others=|kind=household|regime="])
    PartiduoAdmin::Fleet.create_dossier(root, kind_input(firm, server, payer, "foyer-y", "household", [] of String))
      .errors["modules"].should_not be_empty
    PartiduoAdmin::Dossier.filter(slug__in: %w[type-x foyer-x foyer-y]).exists?.should be_false
  end

  it "refuse d'ajouter un module d'entreprise à un foyer" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    dossier.kind = "household"
    dossier.modules = "accounting"
    dossier.save!
    PartiduoAdmin::Fleet.change_modules(AdminSpec.super_admin, dossier, ["accounting", "analytic"], [] of String)
      .errors["family.management"].should eq(["pieces:kind_excludes|piece=analytic|others=|kind=household|regime="])
    PartiduoAdmin::Fleet.change_modules(AdminSpec.super_admin, dossier, ["accounting"], ["perso", "bankimport"]).ok?.should be_true
  end

  it "propose le type au formulaire, le crée et l'affiche sur la fiche, en fr, en et nl" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    payer = AdminSpec.payer(firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)))
    form = browser.get("/dossiers/new").html
    form.should contain(%(name="kind"))
    form.should contain(%(<input type="radio" name="kind" value="household" required><span><strong>Foyer</strong>))
    data = {"slug" => "foyer-form", "label" => "Foyer Durand", "regime" => "fr", "locale" => "fr", "kind" => "household",
            "modules" => ["accounting", "invoicing"], "admin_email" => "durand@foyer.fr",
            "server_id" => server.pk.to_s, "payer_id" => payer.pk.to_s, "backup_schedule" => "daily", "backup_retention_days" => "30"}
    refused = browser.post("/dossiers/new", data)
    refused.status.should eq(422)
    refused.html.should contain("«\u00a0Facturation\u00a0» n'est pas admis dans un dossier «\u00a0Foyer\u00a0».")
    created = browser.post("/dossiers/new", data.merge({"modules" => ["accounting"]}))
    created.status.should eq(302)
    dossier = PartiduoAdmin::Dossier.get!(slug: "foyer-form")
    dossier.kind.should eq("household")
    page = browser.get("/dossiers/#{dossier.pk}").html
    page.should contain("Type de dossier")
    page.should contain("<dd>Foyer</dd>")
    {"en" => "Household", "nl" => "Huishouden"}.each do |locale, label|
      I18n.with_locale(locale) { I18n.t("admin.kinds.household").should eq(label) }
    end
  end
end

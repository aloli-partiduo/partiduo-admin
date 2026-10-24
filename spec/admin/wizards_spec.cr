# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Assistants des parcours courants (D-ADM-018) : étapes numérotées,
# Précédent et Suivant, saisies gardées côté serveur, reprise d'un assistant
# interrompu, rien de créé avant la validation finale, création par les
# services des formulaires, sans JavaScript.

private alias Cfg = PartiduoAdmin::Config

private def step(browser : AdminSpec::Browser, kind : String, data : Hash(String, String | Array(String)),
                 nav : String = "next") : Marten::HTTP::Response
  page = browser.get("/wizards/#{kind}")
  number = page.html.match!(/name="step" value="(\d+)"/)[1]
  browser.post("/wizards/#{kind}", data.merge({"step" => number, "nav" => nav}))
end

describe "Assistants (D-ADM-018)" do
  it "déclare un cabinet en quatre étapes : identité, administrateurs, options, récapitulatif" do
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    browser.get("/firms").html.should contain(%(href="/wizards/firm"))
    first = browser.get("/wizards/firm")
    first.status.should eq(200)
    first.html.should contain("Étape 1 sur 4 : Identité")
    first.html.should contain(%(<title>Étape 1 sur 4 : Identité · Déclarer un cabinet))
    first.html.should contain(%(aria-current="step"))
    first.html.should contain(%(id="pd-step-title" tabindex="-1" autofocus))

    # Erreur à l'étape : elle reste, rien n'avance.
    refused = step(browser, "firm", {"kind" => "cabinet", "name" => ""} of String => String | Array(String))
    refused.status.should eq(422)
    refused.html.should contain("Étape 1 sur 4")
    step(browser, "firm", {"kind" => "cabinet", "name" => "Cabinet Assisté", "siren" => "", "email" => "contact@assiste.fr"} of String => String | Array(String))
      .status.should eq(302)
    browser.get("/wizards/firm").html.should contain("Étape 2 sur 4 : Administrateurs")

    # Une ligne de plus sans JavaScript, puis deux administrateurs.
    step(browser, "firm", {"admin_email" => ["a1@assiste.fr"], "admin_first_name" => ["Ada"], "admin_last_name" => ["Un"],
                           "admin_locale" => ["fr"]} of String => String | Array(String), "more")
    browser.get("/wizards/firm").html.should contain(%(id="pd-admin-email-2"))
    step(browser, "firm", {"admin_email" => ["a1@assiste.fr", "a1@assiste.fr"], "admin_first_name" => ["Ada", ""],
                           "admin_last_name" => ["Un", ""], "admin_locale" => ["fr", "en"]} of String => String | Array(String))
      .status.should eq(422)
    step(browser, "firm", {"admin_email" => ["a1@assiste.fr", "a2@assiste.fr"], "admin_first_name" => ["Ada", "Bob"],
                           "admin_last_name" => ["Un", "Deux"], "admin_locale" => ["fr", "en"]} of String => String | Array(String))
      .status.should eq(302)
    step(browser, "firm", {"encryption" => "none"} of String => String | Array(String)).status.should eq(302)

    summary = browser.get("/wizards/firm").html
    summary.should contain("Étape 4 sur 4 : Récapitulatif")
    summary.should contain("Cabinet Assisté")
    summary.should contain("a2@assiste.fr Bob Deux")
    summary.should contain(%(href="/wizards/firm?step=2"))
    # Rien n'est créé avant la validation.
    PartiduoAdmin::Firm.filter(name: "Cabinet Assisté").exists?.should be_false

    done = step(browser, "firm", {} of String => String | Array(String), "finish")
    done.status.should eq(302)
    firm = PartiduoAdmin::Firm.get!(name: "Cabinet Assisté")
    done.headers["Location"].should eq("/firms/#{firm.pk}/admins")
    firm.backup_encryption.should eq("none")
    PartiduoAdmin::Administrators.firm_admins(firm).map(&.email).should eq(["a1@assiste.fr", "a2@assiste.fr"])
    PartiduoAdmin::User.get!(email: "a2@assiste.fr").locale.should eq("en")
    PartiduoAdmin::WizardDraft.filter(user_id: root.pk).exists?.should be_false
    PartiduoAdmin::AuditEntry.filter(action: "wizard.finish").exists?.should be_true
  end

  it "crée un entrepreneur : activité, modules proposés, nouveau donneur d'ordre, plusieurs administrateurs" do
    firm = AdminSpec.firm("Cabinet Guide")
    server, _ = AdminSpec.server
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    browser.get("/").html.should contain(%(href="/wizards/company"))
    browser.get("/dossiers").html.should contain(%(href="/wizards/household"))
    step(browser, "company", {"label" => "Atelier Martin", "slug" => "atelier-martin", "regime" => "fr", "locale" => "fr",
                              "siren" => "", "vat_number" => ""} of String => String | Array(String)).status.should eq(302)
    step(browser, "company", {"profile" => "micro"} of String => String | Array(String)).status.should eq(302)
    modules = browser.get("/wizards/company")
    modules.html.should contain("Étape 3 sur 6 : Modules")
    modules.html.should match(/id="p-micro"[^>]*checked/)
    step(browser, "company", {"modules" => ["micro", "invoicing"], "extensions" => [] of String} of String => String | Array(String))
      .status.should eq(302)

    # Rattachement : nouveau donneur d'ordre sans adresse, refusé à l'étape.
    attachment = {"payer_mode" => "new", "payer_street" => "", "payer_postcode" => "75011", "payer_city" => "",
                  "payer_country" => "FR", "payer_contact_email" => "", "server_id" => server.pk.to_s,
                  "backup_schedule" => "daily", "backup_retention_days" => "30"} of String => String | Array(String)
    refused = step(browser, "company", attachment)
    refused.status.should eq(422)
    refused.html.should contain(%(id="f-payer-street-error"))
    step(browser, "company", attachment.merge({"payer_street" => "3 rue Oberkampf", "payer_city" => "Paris"} of String => String | Array(String)))
      .status.should eq(302)

    # Précédent garde les saisies.
    step(browser, "company", {"admin_email" => "martin@atelier.fr", "extra_admins" => ["associee@atelier.fr", ""]} of String => String | Array(String), "previous")
    browser.get("/wizards/company").html.should contain("Étape 4 sur 6 : Rattachement")
    step(browser, "company", attachment.merge({"payer_street" => "3 rue Oberkampf", "payer_city" => "Paris"} of String => String | Array(String)))
    browser.get("/wizards/company").html.should contain(%(value="associee@atelier.fr"))
    step(browser, "company", {"admin_email" => "martin@atelier.fr", "extra_admins" => ["associee@atelier.fr", ""]} of String => String | Array(String))
      .status.should eq(302)

    summary = browser.get("/wizards/company").html
    summary.should contain("Étape 6 sur 6 : Récapitulatif")
    summary.should contain("atelier-martin.partiduo.localhost")
    summary.should contain("Atelier Martin (nouveau), 3 rue Oberkampf, 75011 Paris, FR")
    PartiduoAdmin::Dossier.filter(slug: "atelier-martin").exists?.should be_false
    PartiduoAdmin::Payer.filter(name: "Atelier Martin").exists?.should be_false

    done = step(browser, "company", {} of String => String | Array(String), "finish")
    done.status.should eq(302)
    dossier = PartiduoAdmin::Dossier.get!(slug: "atelier-martin")
    done.headers["Location"].should eq("/dossiers/#{dossier.pk}")
    dossier.module_list.should eq(["micro", "invoicing"])
    dossier.kind.should eq("company")
    dossier.payer!.name.should eq("Atelier Martin")
    dossier.payer!.kind.should eq("company")
    PartiduoAdmin::Administrators.emails(dossier).should eq(["martin@atelier.fr", "associee@atelier.fr"])
    PartiduoAdmin::Task.filter(kind: "instance.create", dossier_id: dossier.pk).exists?.should be_true
  end

  it "crée un foyer avec un donneur d'ordre existant, et reprend un assistant interrompu" do
    firm = AdminSpec.firm("Cabinet Foyer")
    server, _ = AdminSpec.server
    payer = AdminSpec.payer(firm)
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    token = AdminSpec.session(admin)
    browser = AdminSpec::Browser.new(token: token)
    step(browser, "household", {"label" => "Foyer Durand", "slug" => "foyer-durand", "regime" => "fr", "locale" => "fr"} of String => String | Array(String))
      .status.should eq(302)

    # Autre navigateur, même compte : l'assistant reprend à l'étape 2.
    again = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    again.get("/wizards").html.should contain("Brouillon en cours : étape 2 sur 5.")
    modules = again.get("/wizards/household")
    modules.html.should contain("Étape 2 sur 5 : Modules")
    modules.html.should contain(%(value="accounting" checked disabled data-pd-locked))
    step(again, "household", {"modules" => ["accounting"]} of String => String | Array(String)).status.should eq(302)
    step(again, "household", {"payer_mode" => "existing", "payer_id" => payer.pk.to_s, "server_id" => server.pk.to_s,
                              "backup_schedule" => "weekly", "backup_retention_days" => "60"} of String => String | Array(String))
      .status.should eq(302)
    step(again, "household", {"admin_email" => "durand@foyer.fr"} of String => String | Array(String)).status.should eq(302)
    step(again, "household", {} of String => String | Array(String), "finish").status.should eq(302)
    dossier = PartiduoAdmin::Dossier.get!(slug: "foyer-durand")
    {dossier.kind, dossier.payer_id, dossier.backup_schedule}.should eq({"household", payer.pk, "weekly"})
  end

  it "montre au récapitulatif une saisie devenue fausse, avec son étape, et abandonne sans rien créer" do
    firm = AdminSpec.firm("Cabinet Course")
    server, _ = AdminSpec.server
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    step(browser, "household", {"label" => "Foyer Pris", "slug" => "foyer-pris", "regime" => "fr", "locale" => "fr"} of String => String | Array(String))
    step(browser, "household", {"modules" => ["accounting"]} of String => String | Array(String))
    step(browser, "household", {"payer_mode" => "new", "payer_street" => "1 rue", "payer_city" => "Lyon", "payer_country" => "FR",
                                "server_id" => server.pk.to_s, "backup_schedule" => "daily", "backup_retention_days" => "30"} of String => String | Array(String))
    step(browser, "household", {"admin_email" => "pris@foyer.fr"} of String => String | Array(String))
    # Le sous-domaine est pris entre-temps.
    AdminSpec.dossier(firm, server, slug: "foyer-pris")
    refused = step(browser, "household", {} of String => String | Array(String), "finish")
    refused.status.should eq(422)
    refused.html.should contain("Identité : Ce sous-domaine")
    PartiduoAdmin::Payer.filter(name: "Foyer Pris").exists?.should be_false

    cancelled = step(browser, "household", {} of String => String | Array(String), "cancel")
    cancelled.status.should eq(302)
    PartiduoAdmin::WizardDraft.filter(user_id: admin.pk).exists?.should be_false
  end

  it "refuse l'assistant d'un cabinet à un admin de cabinet et tout assistant à un gestionnaire" do
    firm = AdminSpec.firm
    admin = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Cfg::FIRM_ADMIN, firm)))
    admin.get("/wizards/firm").status.should eq(403)
    admin.get("/wizards/inconnu").status.should eq(403)
    manager = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Cfg::FILE_MANAGER, firm)))
    manager.get("/wizards/company").status.should eq(403)
    manager.get("/wizards").html.should contain("Aucun assistant ne vous est ouvert.")
  end

  it "répond à HTMX par l'étape suivante, et montre les erreurs d'une étape refusée" do
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    page = browser.get("/wizards/firm")
    page.html.should contain(%(hx-boost="true" hx-target="#pd-content"))
    page.html.should contain("admin/js/wizard.js")
    refused = browser.post("/wizards/firm", {"step" => "1", "nav" => "next", "kind" => "cabinet", "name" => ""}, {"HX-Request" => "true"})
    refused.status.should eq(422)
    refused.html.should contain(%(id="pd-content"))
    moved = browser.post("/wizards/firm", {"step" => "1", "nav" => "next", "kind" => "independent", "name" => "Seule HTMX"},
      {"HX-Request" => "true"})
    {moved.status, moved.headers["HX-Redirect"]?}.should eq({204, "/wizards/firm"})
  end
end

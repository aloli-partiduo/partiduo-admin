# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Listes des utilisateurs et des structures : recherche, filtres, pages de
# vingt-cinq lignes dont les liens gardent la recherche.
describe "Interface de l'administration : recherche et pages des listes" do
  it "cherche et pagine les utilisateurs" do
    firm = AdminSpec.firm
    30.times { |index| AdminSpec.user(PartiduoAdmin::Config::FILE_MANAGER, firm, email: "gestion#{index.to_s.rjust(2, '0')}@exemple.fr") }
    AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm, email: "patronne@cabinet.fr")
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.super_admin))

    first = browser.get("/users?role=file_manager").html
    first.should contain("gestion00@exemple.fr")
    first.should_not contain("gestion29@exemple.fr")
    first.should contain(%(href="/users?role=file_manager&page=2"))
    first.should contain(I18n.t("admin.pager.position", number: "1", pages: "2", total: "30"))
    second = browser.get("/users?role=file_manager&page=2").html
    second.should contain("gestion29@exemple.fr")
    second.should_not contain("gestion00@exemple.fr")

    found = browser.get("/users?q=PATRONNE").html
    found.should contain("patronne@cabinet.fr")
    found.should_not contain("gestion00@exemple.fr")
    found.should_not contain(I18n.t("admin.pager.next"))
    browser.get("/users?q=personne").html.should contain(I18n.t("admin.users.none"))
  end

  it "cherche et pagine les structures" do
    27.times { |index| PartiduoAdmin::Firm.create!(name: "Cabinet #{index.to_s.rjust(2, '0')}", kind: "cabinet", dual_approval: false) }
    PartiduoAdmin::Firm.create!(name: "Martin Expertise", siren: "732829320", kind: "independent", dual_approval: false)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.super_admin))

    first = browser.get("/firms").html
    first.should contain("Cabinet 00")
    first.should contain(%(href="/firms?page=2"))
    browser.get("/firms?q=732%20829%20320").html.should contain("Martin Expertise")
    by_kind = browser.get("/firms?kind=independent").html
    by_kind.should contain("Martin Expertise")
    by_kind.should_not contain("Cabinet 00")
  end
end

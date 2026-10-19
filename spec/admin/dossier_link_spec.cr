# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Interface de l'administration : lien vers le dossier" do
  it "ouvre un dossier actif dans un nouvel onglet, pas un dossier en création" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    actif = AdminSpec.dossier(firm, server, slug: "ouvert")
    neuf = AdminSpec.dossier(firm, server, slug: "neuf", state: "creating")
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.super_admin))
    browser.get("/dossiers/#{actif.pk}").html.should contain(%(href="https://#{actif.host}/" target="_blank" rel="noopener noreferrer"))
    browser.get("/dossiers/#{neuf.pk}").html.should_not contain(%(href="https://#{neuf.host}/" target="_blank"))
    browser.get("/dossiers").html.should contain(%(href="https://#{actif.host}/"))
  end
end

describe PartiduoAdmin::MailBackend do
  it "envoie par le compte SMTP réglé, et refuse avec la cause sans réglage" do
    PartiduoAdmin::MailBackend.build("smtps://notifications%40partiduo.dev:s@mail.example.net").should be_a(MartenMail::Backend)
    missing = PartiduoAdmin::MailBackend.build(nil)
    missing.should be_a(PartiduoAdmin::MailBackend::Missing)
    PartiduoAdmin::MailBackend.build("").should be_a(PartiduoAdmin::MailBackend::Missing)
    expect_raises(MartenMail::DeliveryError, /PARTIDUO_ADMIN_SMTP_URL/) do
      missing.deliver(PartiduoAdmin::TextEmail.new("patron@demo.fr", "Invitation", "corps"))
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions de toutes les pages de la console (fr, en, nl) : chaque route
# du routeur de Marten servie en `GET`, obtenue dans chaque langue par un
# super-administrateur puis par un administrateur de cabinet (la langue du
# compte connecté prime sur le cookie : un compte par langue), sur un parc
# de test (cabinet, serveur, donneur d'ordre, dossiers actif et archivé,
# sauvegarde, tâche, alerte, approbation), plus les pages d'accès sans
# connexion et d'erreur. Contrôle partagé avec connect
# (spec/support/translations.cr).

private alias Config = PartiduoAdmin::Config

# Routes servies en `GET` qui ne sont pas des pages à explorer.
private EXCLUSIONS = {
  "invitation_connect"     => "départ vers connect (redirection hors du site)",
  "login_connect"          => "départ vers connect (redirection hors du site)",
  "login_connect_callback" => "retour de connect : jeton externe exigé",
}

# Un compte par langue ; rend la fonction qui obtient une adresse dans une
# langue avec le compte de cette langue.
private def signed_in(role : String, firm : PartiduoAdmin::Firm? = nil) : PartiduoTranslations::Explorer::Fetch
  browsers = PartiduoTranslations::LOCALES.to_h do |locale|
    user = role == Config::SUPER_ADMIN ? AdminSpec.super_admin : AdminSpec.user(role, firm)
    user.locale = locale
    user.save!
    {locale, AdminSpec::Browser.new(locale, token: AdminSpec.session(user))}
  end
  ->(url : String, locale : String) { browsers[locale].get(url) }
end

private def anonymous : PartiduoTranslations::Explorer::Fetch
  ->(url : String, locale : String) do
    browser = AdminSpec::Browser.new(locale)
    browser.jar[PartiduoAdmin::BaseHandler::LOCALE_COOKIE] = locale
    browser.get(url)
  end
end

describe "Traductions de toutes les pages de la console (fr, en, nl)" do
  it "rend chaque page dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    explorer = PartiduoTranslations::Explorer.new(EXCLUSIONS)
    explorer.visit_placeholders("anonyme", &anonymous)

    firm = AdminSpec.firm("Cabinet Nord")
    server, _ = AdminSpec.server
    active = AdminSpec.dossier(firm, server, slug: "nord-actif")
    archived = AdminSpec.dossier(firm, server, state: "archived", slug: "nord-archive")
    archived.archived_at = SPEC_NOW - 400.days
    archived.save!
    backup = AdminSpec.backup(active)
    PartiduoAdmin::Task.create!(kind: "backup.run", dossier: active, server: server, state: "succeeded")
    PartiduoAdmin::Task.create!(kind: "backup.run", dossier: active, server: server, state: "failed")
    PartiduoAdmin::Alerts.open("test_restore_failed", "danger", dossier: active, detail: "backup #{backup.pk}")
    admin = AdminSpec.user(Config::FIRM_ADMIN, firm)
    manager = AdminSpec.user(Config::FILE_MANAGER, firm)
    PartiduoAdmin::Assignment.create!(user: manager, dossier: active)
    PartiduoAdmin::Approvals.request_admin_invite(manager, active, "gerant@demo.fr", "gérant parti").value!
    invited = AdminSpec.user(Config::FIRM_ADMIN, firm, password: false, totp: false)
    token = PartiduoAdmin::Auth::Invitations.issue(invited, admin, SPEC_NOW)

    explorer.visit("anonyme, invitation valide", ["/invitation/#{token}"], &anonymous)
    explorer.crawl("super-administrateur", &signed_in(Config::SUPER_ADMIN))
    explorer.visit_placeholders("super-administrateur, objets inconnus", &signed_in(Config::SUPER_ADMIN))
    explorer.crawl("administrateur de cabinet", &signed_in(Config::FIRM_ADMIN, firm))

    puts "\nTraductions de la console : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end

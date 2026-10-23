# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions de toutes les pages de la console (fr, en, nl, de, es, it,
# pt) : chaque route du routeur de Marten servie en `GET`, obtenue dans
# chaque langue par un
# super-administrateur puis par un administrateur de cabinet (la langue du
# compte connecté prime sur le cookie : un compte par langue), sur un parc
# de test (cabinet, serveur, donneur d'ordre, dossiers actif et archivé,
# sauvegarde, tâche, alerte, approbation), plus les pages d'accès sans
# connexion et d'erreur ; puis chaque formulaire relevé, envoyé dans chaque
# langue (vide, valeurs fausses, bouton d'action), réponse et redirection
# contrôlées. La sonde de spec/support/translations.cr relève en outre
# toute recherche de traduction de la suite. Contrôle partagé avec connect.

private alias Config = PartiduoAdmin::Config

# Routes servies en `GET` qui ne sont pas des pages à explorer.
private EXCLUSIONS = {
  "invitation_connect"     => "départ vers connect (redirection hors du site)",
  "login_connect"          => "départ vers connect (redirection hors du site)",
  "login_connect_callback" => "retour de connect : jeton externe exigé",
}

# Formulaires relevés jamais envoyés.
private UNSENT = {
  "logout"                   => "fin de la session de l'exploration",
  "login_connect_logout"     => "déconnexion par canal arrière de connect : jeton signé exigé, réponse sans page",
  "login_passkey_options"    => "options WebAuthn en JSON (script de la page)",
  "login_passkey"            => "assertion WebAuthn en JSON (script de la page)",
  "passkey_register_options" => "options WebAuthn en JSON (script de la page)",
  "passkey_register"         => "attestation WebAuthn en JSON (script de la page)",
  "elevate_options"          => "options WebAuthn en JSON (script de la page)",
  "elevate"                  => "assertion WebAuthn en JSON (script de la page)",
}

# Navigateur par langue, qui garde ses cookies ; `cookie` : langue posée
# par le cookie avant chaque requête (visiteur sans compte).
private def visitor(browsers : Hash(String, AdminSpec::Browser), cookie : Bool = false) : PartiduoTranslations::Visitor
  prepare = ->(locale : String) do
    browser = browsers[locale]
    browser.jar[PartiduoAdmin::BaseHandler::LOCALE_COOKIE] = locale if cookie
    browser
  end
  PartiduoTranslations::Visitor.new(
    ->(url : String, locale : String) { prepare.call(locale).get(url) },
    ->(url : String, body : String, locale : String, headers : Hash(String, String)) do
      prepare.call(locale).perform_raw(url, body, headers)
    end)
end

# Un compte par langue (la langue du compte connecté prime sur le cookie).
private def signed_in(role : String, firm : PartiduoAdmin::Firm? = nil) : PartiduoTranslations::Visitor
  visitor(PartiduoTranslations::LOCALES.to_h do |locale|
    user = role == Config::SUPER_ADMIN ? AdminSpec.super_admin : AdminSpec.user(role, firm)
    user.locale = locale
    user.save!
    {locale, AdminSpec::Browser.new(locale, token: AdminSpec.session(user))}
  end)
end

private def anonymous : PartiduoTranslations::Visitor
  visitor(PartiduoTranslations::LOCALES.to_h { |locale| {locale, AdminSpec::Browser.new(locale)} }, cookie: true)
end

describe "Traductions de toutes les pages de la console (fr, en, nl, de, es, it, pt)" do
  it "rend chaque page dans chaque langue, et chaque réponse à ses formulaires, sans clé absente, brute ni interpolation non résolue" do
    explorer = PartiduoTranslations::Explorer.new(EXCLUSIONS, UNSENT)
    anonymous_visitor = anonymous
    explorer.visit_placeholders(anonymous_visitor, "anonyme")

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

    explorer.visit(anonymous_visitor, "anonyme, invitation valide", ["/invitation/#{token}"])
    root = signed_in(Config::SUPER_ADMIN)
    explorer.crawl(root, "super-administrateur")
    explorer.visit_placeholders(root, "super-administrateur, objets inconnus")
    firm_admin = signed_in(Config::FIRM_ADMIN, firm)
    explorer.crawl(firm_admin, "administrateur de cabinet")

    # Envois de chaque formulaire relevé (vide, valeurs fausses, bouton
    # d'action tel quel) : refus de droits d'un gestionnaire de dossiers et
    # de l'administrateur de cabinet d'abord, puis super-administrateur ;
    # formulaires des pages d'accès par un visiteur sans compte, en dernier
    # (l'invitation y est consommée).
    signed = explorer.all_forms.reject(&.variant.starts_with?("anonyme"))
    explorer.submit_forms(signed_in(Config::FILE_MANAGER, firm), "gestionnaire de dossiers", signed)
    explorer.submit_forms(firm_admin, "administrateur de cabinet", signed)
    explorer.submit_forms(root, "super-administrateur", signed)
    explorer.submit_forms(anonymous_visitor, "anonyme", explorer.all_forms.select(&.variant.starts_with?("anonyme")))

    puts "\nTraductions de la console : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end

  it "sert la connexion dans la langue d'un navigateur régional, sans traduction absente" do
    {"de-DE" => "de", "es-ES" => "es", "it-IT" => "it", "pt-BR" => "pt", "pt-PT" => "pt",
     "de-CH,de;q=0.9,en;q=0.8" => "de", "nl-BE" => "nl", "en-US" => "en", "fr-FR" => "fr"}.each do |header, locale|
      page = AdminSpec::Browser.new(header).get("/login")
      page.status.should eq(200)
      page.content.should contain(%(<html lang="#{locale}">))
      page.headers["Content-Language"]?.should eq(locale)
      {header, PartiduoTranslations.problems(page.content)}.should eq({header, [] of String})
      # Texte de la langue elle-même, sans repli sur le français.
      page.html.should contain(PartiduoTranslations.texts[locale]["admin.login.title"].to_s)
    end
  end
end

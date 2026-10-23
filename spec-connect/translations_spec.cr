# SPDX-License-Identifier: AGPL-3.0-or-later

require "./spec_helper"
require "../spec/support/translations"

# Traductions de toutes les pages de connect (fr, en, nl, de, es, it, pt) :
# chaque route du routeur de Marten servie en `GET`, obtenue dans chaque
# langue par une personne connectée (un compte par langue : sa langue
# prime sur le cookie) ayant un client enregistré, plus les pages d'accès sans connexion
# (connexion, invitation valide ou non) et d'erreur ; puis chaque
# formulaire relevé, envoyé dans chaque langue, réponse et redirection
# contrôlées. Contrôle partagé avec la console (spec/support/translations.cr,
# dont la sonde relève aussi toute recherche de traduction de la suite).

# Routes servies en `GET` qui ne sont pas des pages à explorer.
private EXCLUSIONS = {
  "discovery"          => "document JSON de découverte OpenID",
  "jwks"               => "clés publiques au format JSON",
  "authorize"          => "point d'autorisation OAuth : paramètres d'un client exigés, redirige vers lui",
  "userinfo"           => "réponse JSON à un jeton d'accès",
  "login_sso"          => "départ vers un fournisseur d'identité externe (redirection hors du site)",
  "login_sso_callback" => "retour d'un fournisseur d'identité : jeton externe exigé",
}

# Formulaires relevés jamais envoyés.
private UNSENT = {
  "logout"                   => "fin de la session de l'exploration",
  "login_passkey_options"    => "options WebAuthn en JSON (script de la page)",
  "login_passkey"            => "assertion WebAuthn en JSON (script de la page)",
  "passkey_register_options" => "options WebAuthn en JSON (script de la page)",
  "passkey_register"         => "attestation WebAuthn en JSON (script de la page)",
  "elevate_options"          => "options WebAuthn en JSON (script de la page)",
  "elevate"                  => "assertion WebAuthn en JSON (script de la page)",
}

# Navigateur par langue, qui garde ses cookies ; `cookie` : langue posée
# par le cookie avant chaque requête (visiteur sans compte).
private def visitor(browsers : Hash(String, ConnectSpec::Browser), cookie : Bool = false) : PartiduoTranslations::Visitor
  prepare = ->(locale : String) do
    browser = browsers[locale]
    browser.jar[PartiduoConnect::BaseHandler::LOCALE_COOKIE] = locale if cookie
    browser
  end
  PartiduoTranslations::Visitor.new(
    ->(url : String, locale : String) { prepare.call(locale).get(url) },
    ->(url : String, body : String, locale : String, headers : Hash(String, String)) do
      prepare.call(locale).perform_raw(url, body, headers)
    end)
end

# Un compte par langue (sa langue prime sur le cookie).
private def signed_in : PartiduoTranslations::Visitor
  visitor(PartiduoTranslations::LOCALES.to_h do |locale|
    account = ConnectSpec.account
    account.locale = locale
    account.save!
    {locale, ConnectSpec.signed_in(account, ConnectSpec::Browser.new(locale))}
  end)
end

private def anonymous : PartiduoTranslations::Visitor
  visitor(PartiduoTranslations::LOCALES.to_h { |locale| {locale, ConnectSpec::Browser.new(locale)} }, cookie: true)
end

describe "Traductions de toutes les pages de connect (fr, en, nl, de, es, it, pt)" do
  it "a les mêmes libellés dans les sept langues, aux mêmes interpolations" do
    PartiduoTranslations.parity_failures(File.expand_path("../src/connect/locales", __DIR__)).should eq([] of String)
  end

  it "a un libellé dans chaque langue pour chaque clé citée par le code et les gabarits" do
    root = File.expand_path("..", __DIR__)
    PartiduoTranslations.unknown_keys(root, %w[src/connect/**/*.cr src/connect/**/*.html], %w[connect]).should eq([] of String)
  end

  it "rend chaque page dans chaque langue, et chaque réponse à ses formulaires, sans clé absente, brute ni interpolation non résolue" do
    explorer = PartiduoTranslations::Explorer.new(EXCLUSIONS, UNSENT)
    anonymous_visitor = anonymous
    explorer.visit_placeholders(anonymous_visitor, "anonyme")

    ConnectSpec.client("dossier")
    ticket = PartiduoConnect::Signup.issue("nouvelle@example.net", "Nouvelle Personne", now: SPEC_NOW)
    explorer.visit(anonymous_visitor, "anonyme, invitation valide", ["/signup/#{ticket.token}"])
    person = signed_in
    explorer.crawl(person, "personne connectée")
    explorer.visit_placeholders(person, "personne connectée, objets inconnus")

    # Envois de chaque formulaire relevé (vide, valeurs fausses, bouton
    # d'action tel quel) : pages du compte, puis pages d'accès sans compte.
    explorer.submit_forms(person, "personne connectée", explorer.all_forms.reject(&.variant.starts_with?("anonyme")))
    explorer.submit_forms(anonymous_visitor, "anonyme", explorer.all_forms.select(&.variant.starts_with?("anonyme")))

    puts "\nTraductions de connect : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end

  it "sert la connexion dans la langue d'un navigateur régional, sans traduction absente" do
    {"de-DE" => "de", "es-ES" => "es", "it-IT" => "it", "pt-BR" => "pt", "pt-PT" => "pt",
     "de-CH,de;q=0.9,en;q=0.8" => "de", "nl-BE" => "nl", "en-US" => "en", "fr-FR" => "fr"}.each do |header, locale|
      page = ConnectSpec::Browser.new(header).get("/login")
      page.status.should eq(200)
      page.content.should contain(%(<html lang="#{locale}">))
      page.headers["Content-Language"]?.should eq(locale)
      {header, PartiduoTranslations.problems(page.content)}.should eq({header, [] of String})
      # Texte de la langue elle-même, sans repli sur le français.
      page.html.should contain(PartiduoTranslations.texts[locale]["connect.login.title"].to_s)
    end
  end
end

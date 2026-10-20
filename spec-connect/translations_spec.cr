# SPDX-License-Identifier: AGPL-3.0-or-later

require "./spec_helper"
require "../spec/support/translations"

# Traductions de toutes les pages de connect (fr, en, nl) : chaque route du
# routeur de Marten servie en `GET`, obtenue dans chaque langue par une
# personne connectée (un compte par langue : sa langue prime sur le
# cookie) ayant un client enregistré, plus les pages d'accès sans connexion
# (connexion, invitation valide ou non) et d'erreur. Contrôle partagé avec
# la console (spec/support/translations.cr).

# Routes servies en `GET` qui ne sont pas des pages à explorer.
private EXCLUSIONS = {
  "discovery"          => "document JSON de découverte OpenID",
  "jwks"               => "clés publiques au format JSON",
  "authorize"          => "point d'autorisation OAuth : paramètres d'un client exigés, redirige vers lui",
  "userinfo"           => "réponse JSON à un jeton d'accès",
  "login_sso"          => "départ vers un fournisseur d'identité externe (redirection hors du site)",
  "login_sso_callback" => "retour d'un fournisseur d'identité : jeton externe exigé",
}

private def signed_in : PartiduoTranslations::Explorer::Fetch
  browsers = PartiduoTranslations::LOCALES.to_h do |locale|
    account = ConnectSpec.account
    account.locale = locale
    account.save!
    {locale, ConnectSpec.signed_in(account, ConnectSpec::Browser.new(locale))}
  end
  ->(url : String, locale : String) { browsers[locale].get(url) }
end

private def anonymous : PartiduoTranslations::Explorer::Fetch
  ->(url : String, locale : String) do
    browser = ConnectSpec::Browser.new(locale)
    browser.jar[PartiduoConnect::BaseHandler::LOCALE_COOKIE] = locale
    browser.get(url)
  end
end

describe "Traductions de toutes les pages de connect (fr, en, nl)" do
  it "a les mêmes libellés en fr, en et nl, aux mêmes interpolations" do
    PartiduoTranslations.parity_failures(File.expand_path("../src/connect/locales", __DIR__)).should eq([] of String)
  end

  it "a un libellé dans chaque langue pour chaque clé citée par le code et les gabarits" do
    root = File.expand_path("..", __DIR__)
    PartiduoTranslations.unknown_keys(root, %w[src/connect/**/*.cr src/connect/**/*.html], %w[connect]).should eq([] of String)
  end

  it "rend chaque page dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    explorer = PartiduoTranslations::Explorer.new(EXCLUSIONS)
    explorer.visit_placeholders("anonyme", &anonymous)

    ConnectSpec.client("dossier")
    ticket = PartiduoConnect::Signup.issue("nouvelle@example.net", "Nouvelle Personne", now: SPEC_NOW)
    explorer.visit("anonyme, invitation valide", ["/signup/#{ticket.token}"], &anonymous)
    fetch = signed_in
    explorer.crawl("personne connectée", &fetch)
    explorer.visit_placeholders("personne connectée, objets inconnus", &fetch)

    puts "\nTraductions de connect : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end

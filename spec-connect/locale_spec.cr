# SPDX-License-Identifier: AGPL-3.0-or-later

require "./spec_helper"
require "../spec/support/translations"

# Langue d'affichage tenue par connect (D-ADM-015) : réglée sur la page du
# compte, publiée aux clients par le claim `locale`, vide pour suivre le
# navigateur.
private def tokens_for(account : PartiduoConnect::Account) : {JSON::Any, JSON::Any}
  registered = ConnectSpec.client
  verifier = ConnectSpec.verifier
  browser = ConnectSpec.signed_in(account)
  answer = browser.get(ConnectSpec.authorize_path(registered.client, verifier, {"acr_values" => "2"}))
  code = ConnectSpec.query(answer.location)["code"]
  token = ConnectSpec::Browser.new.post("/token", {
    "grant_type" => "authorization_code", "code" => code,
    "redirect_uri" => registered.client.redirect_uri_list.first, "code_verifier" => verifier,
  }, ConnectSpec.basic(registered))
  tokens = JSON.parse(token.content)
  jwk = JSON.parse(ConnectSpec::Browser.new.get("/jwks.json").content)["keys"][0]
  claims = JSON.parse(String.new(Jose::JWS.verify(tokens["id_token"].as_s, Jose::JWK::ECKey.from_jwk_hash(jwk.as_h))))
  info = JSON.parse(ConnectSpec::Browser.new.get("/userinfo", {"Authorization" => "Bearer #{tokens["access_token"].as_s}"}).content)
  {claims, info}
end

describe "connect : langue d'affichage du compte (D-ADM-015)" do
  it "règle la langue sur la page du compte : sept langues et celle du navigateur" do
    account = ConnectSpec.account
    browser = ConnectSpec.signed_in(account, ConnectSpec::Browser.new("fr-FR"))
    html = browser.get("/account").html
    html.should contain(%(action="/account/language"))
    html.should contain(%(<option value="">#{PartiduoTranslations.texts["fr"]["connect.account.language_browser"]}</option>))
    PartiduoConnect::Config::LOCALES.each do |code|
      html.should contain(%(<option value="#{code}"))
      html.should contain(PartiduoTranslations.texts["fr"]["connect.languages.#{code}"].to_s)
    end
    html.should contain(%(<option value="fr" selected>))

    browser.post("/account/language", {"locale" => "de"}).location.should eq("/account")
    account.reload.locale.should eq("de")
    page = browser.get("/account")
    page.content.should contain(%(<html lang="de">))
    PartiduoTranslations.problems(page.content).should eq([] of String)
    page.html.should contain(PartiduoTranslations.texts["de"]["connect.account.language_saved"].to_s)
    page.html.should contain(%(<option value="de" selected>))

    # Langue inconnue : refusée, la langue reste.
    browser.post("/account/language", {"locale" => "ja"})
    account.reload.locale.should eq("de")

    # Langue du navigateur : valeur vide, cookie de la visite retiré.
    browser.jar[PartiduoConnect::BaseHandler::LOCALE_COOKIE] = "nl"
    browser.post("/account/language", {"locale" => ""})
    account.reload.locale.should eq("")
    browser.cookie(PartiduoConnect::BaseHandler::LOCALE_COOKIE).should be_nil
    page = browser.get("/account")
    page.content.should contain(%(<html lang="fr">))
    page.html.should contain(%(<option value="" selected>))
  end

  it "suit le cookie puis le navigateur pour un compte sans langue" do
    account = ConnectSpec.account
    account.locale = ""
    account.save!
    browser = ConnectSpec.signed_in(account, ConnectSpec::Browser.new("it-IT,it;q=0.9"))
    page = browser.get("/account")
    page.content.should contain(%(<html lang="it">))
    PartiduoTranslations.problems(page.content).should eq([] of String)
    browser.jar[PartiduoConnect::BaseHandler::LOCALE_COOKIE] = "es"
    browser.get("/account").content.should contain(%(<html lang="es">))
  end

  it "garde le sélecteur des pages d'accès : cookie de la visite et langue du compte connecté" do
    anonymous = ConnectSpec::Browser.new("fr")
    anonymous.post("/language", {"locale" => "nl", "next" => "/login"}).location.should eq("/login")
    anonymous.get("/login").content.should contain(%(<html lang="nl">))

    account = ConnectSpec.account
    browser = ConnectSpec.signed_in(account)
    browser.post("/language", {"locale" => "pt", "next" => "/account"})
    account.reload.locale.should eq("pt")
  end

  it "publie la langue du compte dans le jeton d'identité et userinfo, et rien pour un compte sans langue" do
    account = ConnectSpec.account
    account.locale = "es"
    account.save!
    claims, info = tokens_for(account)
    claims["locale"].as_s.should eq("es")
    info["locale"].as_s.should eq("es")

    account.locale = ""
    account.save!
    claims, info = tokens_for(account)
    claims.as_h.has_key?("locale").should be_false
    info.as_h.has_key?("locale").should be_false
    claims["sub"].as_s.should eq(account.sub)

    discovery = JSON.parse(ConnectSpec::Browser.new.get("/.well-known/openid-configuration").content)
    discovery["claims_supported"].as_a.map(&.as_s).should contain("locale")
  end
end

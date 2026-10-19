# SPDX-License-Identifier: AGPL-3.0-or-later

require "./spec_helper"

# Fournisseur d'identité d'un cabinet simulé (RS256).
module SsoSpec
  ISSUER = "https://login.cabinet.example"
  KEY    = Jose::JWK::RSAKey.generate(2048)

  class Transport < PartiduoConnect::Sso::Transport
    property id_token = ""

    def post_form(url : String, form : Hash(String, String)) : {Int32, String}
      {200, {"access_token" => "a", "token_type" => "Bearer", "id_token" => id_token}.to_json}
    end

    def get(url : String) : {Int32, String}
      public = SsoSpec::KEY.public_key.to_jwk_hash
      public["kid"] = "r1"
      {200, {"keys" => [public]}.to_json}
    end
  end

  def self.upstream(domains : String = "cabinet.example") : PartiduoConnect::Upstream
    PartiduoConnect::Upstream.create!(code: "cab#{ConnectSpec.next_number}", name: "Cabinet", issuer: ISSUER,
      authorization_endpoint: "#{ISSUER}/authorize", token_endpoint: "#{ISSUER}/token", jwks_uri: "#{ISSUER}/keys",
      client_id: "partiduo-connect", client_secret: "secret", domains: domains, ceiling: 2)
  end

  def self.token(nonce : String, subject : String, email : String, amr = ["pwd", "mfa"], issued : Time = SPEC_NOW) : String
    claims = {"iss" => JSON::Any.new(ISSUER), "aud" => JSON::Any.new("partiduo-connect"), "sub" => JSON::Any.new(subject),
              "nonce" => JSON::Any.new(nonce), "exp" => JSON::Any.new((issued + 5.minutes).to_unix),
              "iat" => JSON::Any.new(issued.to_unix), "email" => JSON::Any.new(email),
              "email_verified" => JSON::Any.new(true), "amr" => JSON::Any.new(amr.map { |item| JSON::Any.new(item) })}
    Jose::JWS.sign(claims.to_json, Jose::JWS::Algorithm::RS256, KEY, {"kid" => "r1"})
  end

  # Aller-retour chez le cabinet ; rend la réponse du retour.
  def self.login(browser : ConnectSpec::Browser, transport : Transport, upstream : PartiduoConnect::Upstream,
                 subject : String, email : String, amr = ["pwd", "mfa"]) : Marten::HTTP::Response
    start = browser.post("/login/sso", {"email" => email, "next" => "/account"})
    query = URI.parse(start.location).query_params
    transport.id_token = token(query["nonce"], subject, email, amr)
    browser.get("/login/sso/#{upstream.code}/callback?#{URI::Params.encode({"code" => "c", "state" => query["state"]})}")
  end
end

describe "connect : relais de l'authentification d'un cabinet (ADR-012 D9)" do
  it "crée le compte d'une adresse invitée au premier passage, puis le reconnaît par son identifiant chez le cabinet" do
    transport = SsoSpec::Transport.new
    PartiduoConnect::Sso.transport = transport
    upstream = SsoSpec.upstream("cabinet-a.example")
    PartiduoConnect::Signup.issue("claire@cabinet-a.example", "Claire", now: SPEC_NOW)
    browser = ConnectSpec::Browser.new
    start = browser.post("/login/sso", {"email" => "claire@cabinet-a.example"})
    start.location.should start_with("#{SsoSpec::ISSUER}/authorize?")
    URI.parse(start.location).query_params["login_hint"].should eq("claire@cabinet-a.example")

    SsoSpec.login(ConnectSpec::Browser.new, transport, upstream, "ext-claire", "claire@cabinet-a.example").status.should eq(302)
    account = PartiduoConnect::Account.get!(email: "claire@cabinet-a.example")
    {account.upstream, account.upstream_subject}.should eq({upstream.code, "ext-claire"})
    PartiduoConnect::Auth.complete?(account).should be_true
    PartiduoConnect::Session.filter(account_id: account.pk, level: 2, method: "sso").exists?.should be_true

    SsoSpec.login(ConnectSpec::Browser.new, transport, upstream, "ext-claire", "claire@cabinet-a.example")
    PartiduoConnect::Account.filter(email: "claire@cabinet-a.example").count.should eq(1)
  end

  it "refuse une adresse non invitée, une adresse hors des domaines du cabinet, une connexion sans MFA" do
    transport = SsoSpec::Transport.new
    PartiduoConnect::Sso.transport = transport
    upstream = SsoSpec.upstream("cabinet-b.example")
    SsoSpec.login(ConnectSpec::Browser.new, transport, upstream, "x", "inconnu@cabinet-b.example").location.should eq("/login")
    PartiduoConnect::Account.filter(email: "inconnu@cabinet-b.example").exists?.should be_false

    # Le cabinet atteste une adresse d'un autre domaine : refusée.
    browser = ConnectSpec::Browser.new
    start = browser.post("/login/sso", {"email" => "bob@cabinet-b.example"})
    query = URI.parse(start.location).query_params
    transport.id_token = SsoSpec.token(query["nonce"], "bob", "bob@ailleurs.example")
    browser.get("/login/sso/#{upstream.code}/callback?code=c&state=#{query["state"]}").location.should eq("/login")

    account = ConnectSpec.account("dan@cabinet-b.example")
    SsoSpec.login(ConnectSpec::Browser.new, transport, upstream, "dan", account.email.to_s, ["pwd"]).status.should eq(403)
  end

  it "n'accepte plus le mot de passe d'une adresse du cabinet, et lie le compte existant au cabinet" do
    transport = SsoSpec::Transport.new
    PartiduoConnect::Sso.transport = transport
    account = ConnectSpec.account("eve@cabinet-c.example")
    upstream = SsoSpec.upstream("cabinet-c.example")
    refused = ConnectSpec::Browser.new.post("/login", {"email" => account.email.to_s, "password" => ConnectSpec::PASSWORD})
    refused.html.should contain(I18n.t("connect.errors.login.use_sso"))
    SsoSpec.login(ConnectSpec::Browser.new, transport, upstream, "ext-eve", account.email.to_s)
    account.reload
    account.upstream_subject.should eq("ext-eve")
  end

  it "ferme les sessions de la personne quand le cabinet l'annonce, et avise les clients" do
    transport = SsoSpec::Transport.new
    PartiduoConnect::Sso.transport = transport
    upstream = SsoSpec.upstream("cabinet-d.example")
    account = ConnectSpec.account("fred@cabinet-d.example")
    registered = ConnectSpec.client
    browser = ConnectSpec::Browser.new
    SsoSpec.login(browser, transport, upstream, "ext-fred", account.email.to_s)
    browser.get(ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier))
    logout = Jose::JWS.sign({"iss" => SsoSpec::ISSUER, "aud" => "partiduo-connect", "sub" => "ext-fred",
                             "iat" => SPEC_NOW.to_unix, "jti" => "j",
                             "events" => {"http://schemas.openid.net/event/backchannel-logout" => {} of String => String}}.to_json,
      Jose::JWS::Algorithm::RS256, SsoSpec::KEY, {"kid" => "r1"})
    ConnectSpec::Browser.new.post("/login/sso/#{upstream.code}/backchannel-logout", {"logout_token" => "faux"}).status.should eq(400)
    ConnectSpec::Browser.new.post("/login/sso/#{upstream.code}/backchannel-logout", {"logout_token" => logout}).status.should eq(200)
    PartiduoConnect::Session.filter(account_id: account.pk, revoked_at__isnull: true).exists?.should be_false
    ConnectSpec::Backchannel.sent.size.should eq(1)
  end
end

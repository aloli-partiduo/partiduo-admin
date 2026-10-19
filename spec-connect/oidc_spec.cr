# SPDX-License-Identifier: AGPL-3.0-or-later

require "./spec_helper"

# Fournisseur OpenID Connect (ADR-012 D3, D8).
describe "connect : OpenID Connect" do
  it "garde l'origine des formulaires (Referrer-Policy same-origin, jamais no-referrer : Origin null refusé par le CSRF)" do
    html = ConnectSpec::Browser.new.get("/login").html
    html.should contain(%(<meta name="referrer" content="same-origin">))
    html.should_not contain("no-referrer")
  end

  it "publie sa découverte et ses clés" do
    browser = ConnectSpec::Browser.new
    discovery = JSON.parse(browser.get("/.well-known/openid-configuration").content)
    discovery["issuer"].as_s.should eq(PartiduoConnect::Config.issuer)
    discovery["code_challenge_methods_supported"].as_a.map(&.as_s).should eq(["S256"])
    discovery["backchannel_logout_supported"].as_bool.should be_true
    keys = JSON.parse(browser.get("/jwks.json").content)["keys"].as_a
    keys.size.should be >= 1
    keys.first["d"]?.should be_nil
    keys.first["alg"].as_s.should eq("ES256")
  end

  it "mène une connexion complète : connexion, code, jeton d'identité signé" do
    account = ConnectSpec.account
    registered = ConnectSpec.client
    verifier = ConnectSpec.verifier
    browser = ConnectSpec::Browser.new
    path = ConnectSpec.authorize_path(registered.client, verifier, {"acr_values" => "2"})

    # Sans session : vers la connexion, l'autorisation en suite.
    login = browser.get(path)
    login.status.should eq(302)
    login.location.should start_with("/login?next=")
    page = browser.get(login.location)
    page.html.should contain(registered.client.name.to_s)

    next_path = URI.decode_www_form(login.location.partition("next=")[2].partition('&')[0])
    browser.post("/login", {"email" => account.email.to_s, "password" => ConnectSpec::PASSWORD, "next" => next_path})
    back = browser.post("/login/second-factor", {"code" => ConnectSpec.totp(account), "next" => next_path})
    back.location.should eq(next_path)

    answer = browser.get(back.location)
    answer.location.should start_with(registered.client.redirect_uri_list.first)
    query = ConnectSpec.query(answer.location)
    query["state"].should eq("etat-123")
    query["iss"].should eq(PartiduoConnect::Config.issuer)

    token = ConnectSpec::Browser.new.post("/token", {
      "grant_type" => "authorization_code", "code" => query["code"],
      "redirect_uri" => registered.client.redirect_uri_list.first, "code_verifier" => verifier,
    }, ConnectSpec.basic(registered))
    token.status.should eq(200)
    token.headers["Cache-Control"].should eq("no-store")
    tokens = JSON.parse(token.content)

    jwk = JSON.parse(ConnectSpec::Browser.new.get("/jwks.json").content)["keys"][0]
    key = Jose::JWK::ECKey.from_jwk_hash(jwk.as_h)
    claims = JSON.parse(String.new(Jose::JWS.verify(tokens["id_token"].as_s, key)))
    claims["iss"].as_s.should eq(PartiduoConnect::Config.issuer)
    claims["aud"].as_s.should eq(registered.client.client_id)
    claims["sub"].as_s.should eq(account.sub)
    claims["nonce"].as_s.should eq("nonce-456")
    claims["acr"].as_s.should eq("2")
    claims["amr"].as_a.map(&.as_s).should contain("otp")
    claims["email"].as_s.should eq(account.email)
    claims["sid"].as_s.should_not be_empty

    info = ConnectSpec::Browser.new.get("/userinfo", {"Authorization" => "Bearer #{tokens["access_token"].as_s}"})
    JSON.parse(info.content)["sub"].as_s.should eq(account.sub)
  end

  it "refuse un code rejoué, un vérificateur PKCE faux, une autre adresse de retour, un autre client" do
    account = ConnectSpec.account
    registered = ConnectSpec.client
    other = ConnectSpec.client("autre")
    verifier = ConnectSpec.verifier
    browser = ConnectSpec.signed_in(account)
    redirect_uri = registered.client.redirect_uri_list.first

    code = ConnectSpec.query(browser.get(ConnectSpec.authorize_path(registered.client, verifier)).location)["code"]
    bad = ConnectSpec::Browser.new.post("/token", {"grant_type" => "authorization_code", "code" => code,
                                                   "redirect_uri" => redirect_uri, "code_verifier" => ConnectSpec.verifier}, ConnectSpec.basic(registered))
    bad.status.should eq(400)
    JSON.parse(bad.content)["error"].as_s.should eq("invalid_grant")
    # Le code est consommé par le premier essai, même raté.
    replay = ConnectSpec::Browser.new.post("/token", {"grant_type" => "authorization_code", "code" => code,
                                                      "redirect_uri" => redirect_uri, "code_verifier" => verifier}, ConnectSpec.basic(registered))
    replay.status.should eq(400)

    code = ConnectSpec.query(browser.get(ConnectSpec.authorize_path(registered.client, verifier)).location)["code"]
    ConnectSpec::Browser.new.post("/token", {"grant_type" => "authorization_code", "code" => code,
                                             "redirect_uri" => "#{redirect_uri}x", "code_verifier" => verifier}, ConnectSpec.basic(registered)).status.should eq(400)

    code = ConnectSpec.query(browser.get(ConnectSpec.authorize_path(registered.client, verifier)).location)["code"]
    ConnectSpec::Browser.new.post("/token", {"grant_type" => "authorization_code", "code" => code,
                                             "redirect_uri" => redirect_uri, "code_verifier" => verifier}, ConnectSpec.basic(other)).status.should eq(400)

    wrong_secret = {"Authorization" => "Basic #{Base64.strict_encode("#{registered.client.client_id}:faux")}"}
    ConnectSpec::Browser.new.post("/token", {"grant_type" => "authorization_code", "code" => code,
                                             "redirect_uri" => redirect_uri, "code_verifier" => verifier}, wrong_secret).status.should eq(401)
  end

  it "n'envoie jamais d'erreur vers une adresse de retour non déclarée, et exige PKCE" do
    registered = ConnectSpec.client
    browser = ConnectSpec::Browser.new
    path = ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier, {"redirect_uri" => "https://pirate.example.net/cb"})
    response = browser.get(path)
    response.status.should eq(400)
    response.location.should be_empty

    no_pkce = ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier, {"code_challenge_method" => "plain"})
    refused = browser.get(no_pkce)
    refused.status.should eq(302)
    ConnectSpec.query(refused.location)["error"].should eq("invalid_request")
  end

  it "répond login_required à prompt=none sans session, et redemande la connexion pour prompt=login" do
    account = ConnectSpec.account
    registered = ConnectSpec.client
    none = ConnectSpec::Browser.new.get(ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier, {"prompt" => "none"}))
    ConnectSpec.query(none.location)["error"].should eq("login_required")

    browser = ConnectSpec.signed_in(account)
    again = browser.get(ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier, {"prompt" => "login"}))
    again.location.should start_with("/login?next=")
    URI.decode_www_form(again.location).should_not contain("prompt=login")
  end

  it "fait monter au niveau 3 (passkey) quand le client l'exige" do
    account = ConnectSpec.account
    registered = ConnectSpec.client
    browser = ConnectSpec.signed_in(account)
    response = browser.get(ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier, {"acr_values" => "3"}))
    response.location.should start_with("/step-up?acr=3")
    # Sans passkey : la page invite à en ajouter une.
    browser.get(response.location).html.should contain(I18n.t("connect.step_up.no_passkey"))
  end

  it "déconnecte partout : la session fermée avise les clients qu'elle avait ouverts (D8)" do
    account = ConnectSpec.account
    first = ConnectSpec.client
    second = ConnectSpec.client("deuxieme")
    silent = ConnectSpec.client("muet", backchannel: false)
    browser = ConnectSpec.signed_in(account)
    [first, second, silent].each { |registered| browser.get(ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier)) }

    target = first.client.post_logout_redirect_uri_list.first
    confirm = browser.get("/logout?client_id=#{first.client.client_id}&post_logout_redirect_uri=#{URI.encode_www_form(target)}&state=s1")
    confirm.status.should eq(200)
    done = browser.post("/logout", {"client_id" => first.client.client_id.to_s, "post_logout_redirect_uri" => target, "state" => "s1"})
    done.location.should eq("#{target}?state=s1")

    sent = ConnectSpec::Backchannel.sent
    sent.map(&.[0]).sort!.should eq([first.client.backchannel_logout_uri.to_s, second.client.backchannel_logout_uri.to_s].sort)
    jwk = JSON.parse(SigningKeysSpec.jwks)["keys"][0]
    claims = JSON.parse(String.new(Jose::JWS.verify(sent.first[1], Jose::JWK::ECKey.from_jwk_hash(jwk.as_h))))
    claims["sub"].as_s.should eq(account.sub)
    claims["events"].as_h.has_key?("http://schemas.openid.net/event/backchannel-logout").should be_true
    claims["nonce"]?.should be_nil

    # La session est fermée : une nouvelle demande repasse par la connexion.
    browser.get(ConnectSpec.authorize_path(first.client, ConnectSpec.verifier)).location.should start_with("/login")
  end

  it "ferme les sessions et avise les clients à la suspension d'un compte" do
    account = ConnectSpec.account
    registered = ConnectSpec.client
    browser = ConnectSpec.signed_in(account)
    browser.get(ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier))
    PartiduoConnect::Auth.suspend(account, SPEC_NOW)
    ConnectSpec::Backchannel.sent.size.should eq(1)
    browser.get("/account").location.should start_with("/login")
  end

  it "accepte une adresse de retour de déconnexion déclarée par l'indice id_token_hint" do
    account = ConnectSpec.account
    registered = ConnectSpec.client
    verifier = ConnectSpec.verifier
    browser = ConnectSpec.signed_in(account)
    code = ConnectSpec.query(browser.get(ConnectSpec.authorize_path(registered.client, verifier)).location)["code"]
    tokens = JSON.parse(ConnectSpec::Browser.new.post("/token", {"grant_type" => "authorization_code", "code" => code,
                                                                 "redirect_uri" => registered.client.redirect_uri_list.first, "code_verifier" => verifier}, ConnectSpec.basic(registered)).content)
    target = registered.client.post_logout_redirect_uri_list.first
    done = browser.post("/logout", {"id_token_hint" => tokens["id_token"].as_s, "post_logout_redirect_uri" => target})
    done.location.should eq(target)
    # Adresse non déclarée : page de fin, pas de redirection.
    other = ConnectSpec.signed_in(account)
    other.post("/logout", {"client_id"                => registered.client.client_id.to_s,
                           "post_logout_redirect_uri" => "https://pirate.example.net/"}).status.should eq(200)
  end
end

module SigningKeysSpec
  def self.jwks : String
    PartiduoConnect::SigningKeys.jwks
  end
end

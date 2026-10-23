# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# L'administration cliente de connect (ADR-012 D4, D6, D8).
describe "Administration : connexion par connect (ADR-012 D4)" do
  it "lie l'invitation à l'identité connect de l'adresse invitée, puis connecte au niveau attesté" do
    AdminConnectSpec.with_connect do |transport|
      firm = AdminSpec.firm
      outcome = PartiduoAdmin::Directory.invite_user(AdminSpec.super_admin, PartiduoAdmin::Directory::UserInput.new(
        email: "gestion@example.com", role: PartiduoAdmin::Config::FIRM_ADMIN, firm_id: firm.pk.as(Int64)))
      outcome.signup_code.should eq("WXYZ-2345")
      user = outcome.value!
      raw = PartiduoAdmin::Auth::Invitations.issue(user, now: SPEC_NOW)
      PartiduoAdmin::Auth::Invitations.attach_connect(user, raw)
      ticket = transport.posts.reverse_each.find! { |(url, _)| url.ends_with?("/api/v1/signup-tickets") }[1]
      ticket["return_to"].should end_with("/invitation/#{raw}/connect")

      browser = AdminSpec::Browser.new
      page = browser.get("/invitation/#{raw}").html
      page.should contain("#{AdminConnectSpec::URL}/signup/jeton")
      browser.get("/invitation/#{raw}/connect").headers["Location"].should start_with("/login/connect?login_hint=gestion%40example.com")

      # Un autre compte connect : refusé, invitation intacte.
      AdminConnectSpec.login(browser, transport, "pirate", "pirate@example.net")
      PartiduoAdmin::User.get!(id: user.pk).connect_sub.should be_nil

      response = AdminConnectSpec.login(browser, transport, "sub-gestion", "gestion@example.com")
      response.headers["Location"].should eq("/")
      PartiduoAdmin::User.get!(id: user.pk).connect_sub.should eq("sub-gestion")
      PartiduoAdmin::Session.filter(user_id: user.pk, federated_sid: "sid-a", level: 2).exists?.should be_true
    end
  end

  it "redemande la passkey (acr 3) au super-admin connecté au niveau 2" do
    AdminConnectSpec.with_connect do |transport|
      root = AdminSpec.super_admin
      root.connect_sub = "sub-root"
      root.save!
      browser = AdminSpec::Browser.new
      AdminConnectSpec.login(browser, transport, "sub-root", root.email.to_s, acr: "2").headers["Location"]
        .should start_with("/login/connect?acr=3")
      AdminConnectSpec.login(browser, transport, "sub-root", root.email.to_s, acr: "3", start: "/login/connect?acr=3")
        .headers["Location"].should eq("/")
    end
  end

  it "refuse la connexion locale et ferme les sessions annoncées par connect" do
    AdminConnectSpec.with_connect do |transport|
      user = AdminSpec.user
      browser = AdminSpec::Browser.new
      browser.post("/login", {"email" => user.email.to_s, "password" => AdminSpec::PASSWORD}).headers["Location"].should eq("/login")
      PartiduoAdmin::Session.filter(user_id: user.pk).exists?.should be_false

      user.connect_sub = "sub-x"
      user.save!
      AdminConnectSpec.login(browser, transport, "sub-x", user.email.to_s)
      logout = AdminConnectSpec.sign({"iss" => JSON::Any.new(AdminConnectSpec::URL), "aud" => JSON::Any.new("admin"),
                                      "sub" => JSON::Any.new("sub-x"), "sid" => JSON::Any.new("sid-a"),
                                      "iat" => JSON::Any.new(SPEC_NOW.to_unix),
                                      "events" => JSON::Any.new({"http://schemas.openid.net/event/backchannel-logout" => JSON::Any.new({} of String => JSON::Any)})})
      AdminSpec::Browser.new.post("/login/connect/backchannel-logout", {"logout_token" => "faux"}).status.should eq(400)
      AdminSpec::Browser.new.post("/login/connect/backchannel-logout", {"logout_token" => logout}).status.should eq(200)
      PartiduoAdmin::Session.filter(user_id: user.pk, revoked_at__isnull: true).exists?.should be_false
    end
  end
end

describe "Administration : liaison d'un utilisateur existant à connect (ADR-012 D4)" do
  it "lie une fois, refuse de relier à une autre identité ou de partager une identité" do
    user = AdminSpec.user
    other = AdminSpec.user
    run = ->(email : String, sub : String) do
      stdout, stderr = IO::Memory.new, IO::Memory.new
      PartiduoAdmin::Commands::ConnectLink.new(["--email=#{email}", "--sub=#{sub}"], stdout: stdout, stderr: stderr,
        exit_raises: true).handle
      stdout.to_s + stderr.to_s
    end
    run.call(user.email.to_s, "sub-1").should contain("lié")
    PartiduoAdmin::User.get!(id: user.pk).connect_sub.should eq("sub-1")
    run.call(user.email.to_s, "sub-2").should contain("déjà lié")
    run.call(other.email.to_s, "sub-1").should contain("déjà liée")
  end
end

# Langue tenue par connect (D-ADM-015) : claim `locale` du jeton d'identité,
# relu à chaque connexion, avant le cookie et le navigateur.
describe "Administration : langue tenue par connect (D-ADM-015)" do
  it "ouvre la console dans la langue du compte connect, sans traduction absente, et renvoie vers connect pour la changer" do
    AdminConnectSpec.with_connect do |transport|
      user = AdminSpec.user
      user.connect_sub = "sub-de"
      user.save!
      browser = AdminSpec::Browser.new("fr-FR,fr;q=0.9")
      browser.jar[PartiduoAdmin::BaseHandler::LOCALE_COOKIE] = "nl"
      AdminConnectSpec.login(browser, transport, "sub-de", user.email.to_s, locale: "de-DE").headers["Location"].should eq("/")
      PartiduoAdmin::Session.filter(user_id: user.pk, revoked_at__isnull: true).first!.locale.should eq("de")

      page = browser.get("/account")
      page.status.should eq(200)
      page.content.should contain(%(<html lang="de">))
      PartiduoTranslations.problems(page.content).should eq([] of String)
      html = page.html
      html.should contain(%(href="#{AdminConnectSpec::URL}/account"))
      html.should contain(PartiduoTranslations.texts["de"]["admin.shell.language_connect"].to_s)
      html.should_not contain(%(id="pd-lang"))
    end
  end

  it "reprend à la connexion suivante un changement de langue fait dans connect" do
    AdminConnectSpec.with_connect do |transport|
      user = AdminSpec.user
      user.connect_sub = "sub-change"
      user.save!
      browser = AdminSpec::Browser.new("fr")
      AdminConnectSpec.login(browser, transport, "sub-change", user.email.to_s, locale: "it")
      browser.get("/account").content.should contain(%(<html lang="it">))

      # Changement dans connect : la connexion suivante prend la nouvelle
      # langue.
      browser.get("/account").content.should contain(%(<html lang="it">))
      again = AdminSpec::Browser.new("fr")
      AdminConnectSpec.login(again, transport, "sub-change", user.email.to_s, locale: "pt")
      again.get("/account").content.should contain(%(<html lang="pt">))
    end
  end

  it "suit le navigateur pour un compte connect sans langue, puis fr pour une langue non servie" do
    AdminConnectSpec.with_connect do |transport|
      user = AdminSpec.user
      user.connect_sub = "sub-nav"
      user.save!
      es = AdminSpec::Browser.new("es-ES,es;q=0.9")
      AdminConnectSpec.login(es, transport, "sub-nav", user.email.to_s)
      PartiduoAdmin::Session.filter(user_id: user.pk, revoked_at__isnull: true).first!.locale.should eq("")
      page = es.get("/account")
      page.content.should contain(%(<html lang="es">))
      PartiduoTranslations.problems(page.content).should eq([] of String)

      # Langue de l'utilisateur de la console (« fr ») ignorée : seule celle
      # de connect compte ; une langue non servie (ja) vaut absence.
      ja = AdminSpec::Browser.new("ja")
      AdminConnectSpec.login(ja, transport, "sub-nav", user.email.to_s, locale: "ja-JP")
      ja.get("/account").content.should contain(%(<html lang="fr">))
    end
  end

  it "ramène une étiquette régionale à la langue de base" do
    {"de-DE" => "de", "pt_BR" => "pt", "NL-be" => "nl", "en" => "en", "ja" => "", "" => "", nil => ""}.each do |value, base|
      PartiduoAdmin::Connect.base_locale(value).should eq(base)
    end
  end

  it "garde le sélecteur de langue pour une session sans connect" do
    user = AdminSpec.user
    browser = AdminSpec::Browser.new("fr", AdminSpec.session(user))
    html = browser.get("/account").html
    html.should contain(%(id="pd-lang"))
    html.should_not contain("language_connect")
    html.should_not contain(PartiduoTranslations.texts["fr"]["admin.shell.language_connect"].to_s)
  end
end

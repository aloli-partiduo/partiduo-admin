# SPDX-License-Identifier: AGPL-3.0-or-later

require "./spec_helper"

# Création d'un compte (ADR-012 D6), enrôlement, compte (D1, D7, D8).
describe "connect : comptes" do
  it "crée un compte par le lien et le code, enrôle une passkey, montre les codes une fois, puis revient au dossier" do
    registered = ConnectSpec.client
    return_to = "#{registered.client.redirect_uri_list.first.sub("/auth/callback", "")}/invitation/abc"
    api = ConnectSpec::Browser.new.post("/api/v1/signup-tickets",
      {"email" => "Nouvelle@Example.net", "name" => "Nouvelle Personne", "return_to" => return_to},
      ConnectSpec.basic(registered))
    api.status.should eq(200)
    ticket = JSON.parse(api.content)
    ticket["account"].as_bool.should be_false
    code = ticket["code"].as_s
    code.should match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/)
    path = URI.parse(ticket["url"].as_s).path

    browser = ConnectSpec::Browser.new
    browser.get(path).html.should contain("nouvelle@example.net")
    created = browser.post(path, {"code" => code.downcase.delete('-'), "name" => ""})
    created.location.should eq("/account")
    account = PartiduoConnect::Account.get!(email: "nouvelle@example.net")
    account.display_name.should eq("Nouvelle Personne")

    authenticator = ConnectSpec::Authenticator.new
    options = browser.post("/account/passkey/options").content
    answer = JSON.parse(browser.post("/account/passkey", authenticator.register(options)).content)
    answer["ok"].as_bool.should be_true
    answer["html"].as_s.should contain(I18n.t("connect.account.continue"))
    # Jeton CSRF dans le formulaire « Continuer » (rendu hors de la page).
    answer["html"].as_s.should match(/name="csrftoken" value="[^"]+"/)
    PartiduoConnect::Auth::RecoveryCodes.remaining(account).should eq(PartiduoConnect::Config::RECOVERY_CODES)

    back = browser.post("/account/continue")
    back.location.should eq(return_to)

    # Le même lien ne sert plus.
    ConnectSpec::Browser.new.get(path).status.should eq(404)

    # Connexion par la passkey depuis un autre navigateur : niveau 3.
    fresh = ConnectSpec::Browser.new
    login_options = fresh.post("/login/passkey/options").content
    logged = JSON.parse(fresh.post("/login/passkey", authenticator.assert(login_options).merge({"next" => "/account"})).content)
    logged["ok"].as_bool.should be_true
    PartiduoConnect::Session.filter(account_id: account.pk, level: 3).count.should be >= 1
  end

  it "répond « compte existant » à une invitation pour une adresse déjà connue" do
    account = ConnectSpec.account
    registered = ConnectSpec.client
    api = ConnectSpec::Browser.new.post("/api/v1/signup-tickets", {"email" => account.email.to_s}, ConnectSpec.basic(registered))
    JSON.parse(api.content)["account"].as_bool.should be_true
  end

  it "refuse une invitation demandée sans secret de client, ou avec un retour vers un autre site" do
    registered = ConnectSpec.client
    ConnectSpec::Browser.new.post("/api/v1/signup-tickets", {"email" => "x@example.net"}).status.should eq(401)
    refused = ConnectSpec::Browser.new.post("/api/v1/signup-tickets",
      {"email" => "x@example.net", "return_to" => "https://pirate.example.net/"}, ConnectSpec.basic(registered))
    refused.status.should eq(400)
  end

  it "annule l'invitation après cinq codes faux : le lien seul ne suffit pas (D6)" do
    issued = PartiduoConnect::Signup.issue("intercepte@example.net", now: SPEC_NOW)
    path = URI.parse(issued.url).path
    browser = ConnectSpec::Browser.new
    4.times { browser.post(path, {"code" => "AAAA-AAAA"}).html.should contain(I18n.t("connect.errors.signup.code")) }
    browser.post(path, {"code" => "AAAA-AAAA"}).html.should contain(I18n.t("connect.errors.signup.cancelled"))
    browser.post(path, {"code" => issued.code}).status.should eq(422)
    PartiduoConnect::Account.filter(email: "intercepte@example.net").exists?.should be_false
  end

  it "remplace l'invitation précédente pour la même adresse" do
    first = PartiduoConnect::Signup.issue("deux@example.net", now: SPEC_NOW)
    second = PartiduoConnect::Signup.issue("deux@example.net", now: SPEC_NOW)
    PartiduoConnect::Signup.find(first.token, SPEC_NOW).should be_nil
    PartiduoConnect::Signup.find(second.token, SPEC_NOW).should_not be_nil
  end

  it "enrôle mot de passe puis TOTP, et une session d'enrôlement ne gère pas un compte déjà complet" do
    issued = PartiduoConnect::Signup.issue("totp@example.net", now: SPEC_NOW)
    browser = ConnectSpec::Browser.new
    browser.post(URI.parse(issued.url).path, {"code" => issued.code})
    browser.post("/account/password", {"password" => ConnectSpec::PASSWORD, "confirmation" => ConnectSpec::PASSWORD})
    browser.post("/account/totp", {"command" => "begin"})
    account = PartiduoConnect::Account.get!(email: "totp@example.net")
    code = TOTP::Authenticator.from_base32(account.totp_pending_secret.to_s).at(SPEC_NOW)
    codes = browser.post("/account/totp", {"code" => code})
    codes.html.should contain(I18n.t("connect.account.recovery_title"))
    account.reload
    PartiduoConnect::Auth.complete?(account).should be_true

    # Compte complet ouvert par son seul mot de passe (TOTP non saisi) :
    # impossible, le second facteur est exigé avant toute session.
    other = ConnectSpec::Browser.new
    pending = other.post("/login", {"email" => "totp@example.net", "password" => ConnectSpec::PASSWORD})
    pending.location.should start_with("/login/second-factor")
    other.get("/account").location.should start_with("/login")
  end

  it "montre à l'enrôlement le QR code de l'URI otpauth://, puis le secret groupé" do
    issued = PartiduoConnect::Signup.issue("qr@example.net", now: SPEC_NOW)
    browser = ConnectSpec::Browser.new
    browser.post(URI.parse(issued.url).path, {"code" => issued.code})
    browser.post("/account/password", {"password" => ConnectSpec::PASSWORD, "confirmation" => ConnectSpec::PASSWORD})
    browser.post("/account/totp", {"command" => "begin"})
    account = PartiduoConnect::Account.get!(email: "qr@example.net")
    secret = account.totp_pending_secret.to_s
    response = browser.get("/account")
    html = response.html

    label = I18n.t("connect.account.totp_qr_label")
    qr = html.index!(%(<figure class="pd-qr-box"><svg class="pd-qr" ))
    html.should contain(%(aria-label="#{label}"))
    html.index!(%(<code>#{PartiduoAdmin::Qr::Svg.group(secret)}</code>)).should be > qr
    html.should_not contain("otpauth://")
    uri = PartiduoConnect::Auth::Totp.provisioning_uri(account, secret)
    # Contenu brut : `html` décode les entités, l'apostrophe du libellé comprise.
    response.content.should contain(PartiduoAdmin::Qr::Svg.render(PartiduoAdmin::Qr::QrCode.encode(uri), label))
  end

  it "ferme les autres sessions et prévient la personne quand un code de récupération sert (D7, D8)" do
    account = ConnectSpec.account
    codes = PartiduoConnect::Auth::RecoveryCodes.generate(account)
    registered = ConnectSpec.client
    first = ConnectSpec.signed_in(account)
    first.get(ConnectSpec.authorize_path(registered.client, ConnectSpec.verifier))

    second = ConnectSpec::Browser.new
    second.post("/login", {"email" => account.email.to_s, "password" => ConnectSpec::PASSWORD})
    second.post("/login/second-factor", {"code" => codes.first})
    second.get("/account").status.should eq(200)
    first.get("/account").location.should start_with("/login")
    ConnectSpec::Backchannel.sent.size.should eq(1)
    Marten::Spec.delivered_emails.map(&.subject).should contain(I18n.t("connect.emails.notice.subject"))
  end

  it "change l'adresse par un lien envoyé à la nouvelle, garde le sub, prévient l'ancienne (D8)" do
    account = ConnectSpec.account
    old_email = account.email.to_s
    browser = ConnectSpec.signed_in(account)
    browser.post("/account/email", {"email" => "nouvelle-adresse@example.net"})
    mail = Marten::Spec.delivered_emails.last
    mail.to.map(&.address).should eq(["nouvelle-adresse@example.net"])
    link = mail.text_body.to_s[/\/account\/email\/[A-Za-z0-9_-]+/]
    browser.post(link)
    account.reload
    account.email.should eq("nouvelle-adresse@example.net")
    Marten::Spec.delivered_emails.last.to.map(&.address).should eq([old_email])
    browser.post(link).status.should eq(302)
    account.reload
    account.email.should eq("nouvelle-adresse@example.net")
  end

  it "refuse de retirer la dernière passkey d'un compte sans mot de passe ni TOTP" do
    issued = PartiduoConnect::Signup.issue("cle@example.net", now: SPEC_NOW)
    browser = ConnectSpec::Browser.new
    browser.post(URI.parse(issued.url).path, {"code" => issued.code})
    authenticator = ConnectSpec::Authenticator.new
    browser.post("/account/passkey", authenticator.register(browser.post("/account/passkey/options").content))
    passkey = PartiduoConnect::Passkey.filter(account__email: "cle@example.net").first!
    browser.post("/account/passkeys/#{passkey.pk}/delete")
    PartiduoConnect::Passkey.filter(id: passkey.pk).exists?.should be_true
  end

  it "garde un journal en ajout seul, lisible par la personne" do
    account = ConnectSpec.account
    browser = ConnectSpec.signed_in(account)
    page = browser.get("/account")
    page.html.should contain("auth.login")
    expect_raises(Exception) do
      PartiduoConnect::AuditEntry.filter(account_id: account.pk).update(action: "falsifie")
    end
  end

  it "bloque un compte au dixième échec" do
    account = ConnectSpec.account
    browser = ConnectSpec::Browser.new
    clock = SPEC_NOW
    10.times do |index|
      PartiduoConnect::Config.clock = -> { clock + (index * 20).minutes }
      browser.post("/login", {"email" => account.email.to_s, "password" => "faux-mot-de-passe-de-specs"})
    end
    PartiduoConnect::Config.clock = -> { SPEC_NOW }
    account.reload
    account.locked?.should be_true
  end
end

describe "connect : clé d'accès perdue (ADR-002 D7)" do
  it "rouvre un compte à passkey seule par adresse et code de récupération, puis permet une nouvelle passkey" do
    issued = PartiduoConnect::Signup.issue("perdu@example.net", now: SPEC_NOW)
    browser = ConnectSpec::Browser.new
    browser.post(URI.parse(issued.url).path, {"code" => issued.code})
    first = ConnectSpec::Authenticator.new
    html = JSON.parse(browser.post("/account/passkey", first.register(browser.post("/account/passkey/options").content)).content)["html"].as_s
    code = html.match!(/<li>([A-Z2-9-]{19})<\/li>/)[1]
    account = PartiduoConnect::Account.get!(email: "perdu@example.net")
    account.usable_password?.should be_false

    other = ConnectSpec::Browser.new
    other.post("/login/recover", {"email" => "perdu@example.net", "code" => "AAAA-AAAA-AAAA-AAAA"}).status.should eq(422)
    other.post("/login/recover", {"email" => "perdu@example.net", "code" => code}).location.should start_with("/account")
    browser.get("/account").location.should start_with("/login")
    second = ConnectSpec::Authenticator.new
    answer = JSON.parse(other.post("/account/passkey", second.register(other.post("/account/passkey/options").content)).content)
    answer["ok"].as_bool.should be_true
    PartiduoConnect::Passkey.filter(account_id: account.pk).count.should eq(2)
    # Un code ne sert qu'une fois.
    ConnectSpec::Browser.new.post("/login/recover", {"email" => "perdu@example.net", "code" => code}).status.should eq(422)
  end

  it "rouvre le même compte par l'exploitation : facteurs retirés, lien et code, même sub" do
    account = ConnectSpec.account("support@example.net")
    PartiduoConnect::Auth::RecoveryCodes.generate(account)
    sub = account.sub
    issued = PartiduoConnect::Signup.recover(account, "spec", SPEC_NOW)
    account.reload
    {account.usable_password?, account.totp_enabled?, PartiduoConnect::Auth::RecoveryCodes.remaining(account)}.should eq({false, false, 0})
    browser = ConnectSpec::Browser.new
    browser.get(URI.parse(issued.url).path).html.should contain("Récupération de votre compte")
    browser.post(URI.parse(issued.url).path, {"code" => issued.code}).location.should eq("/account")
    PartiduoConnect::Account.filter(email: "support@example.net").count.should eq(1)
    PartiduoConnect::Account.get!(email: "support@example.net").sub.should eq(sub)
    authenticator = ConnectSpec::Authenticator.new
    JSON.parse(browser.post("/account/passkey", authenticator.register(browser.post("/account/passkey/options").content)).content)["ok"]
      .as_bool.should be_true
  end
end

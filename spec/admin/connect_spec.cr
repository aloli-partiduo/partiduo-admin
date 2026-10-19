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

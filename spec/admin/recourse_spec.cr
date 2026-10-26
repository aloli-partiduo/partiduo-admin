# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Dernier recours du super-admin après un délai (D-ADM-024) : il ne valide
# la demande d'un cabinet qu'après `Config.recourse_delay` (48 heures par
# défaut, réglable par l'instance) sans décision d'un admin de la
# structure ; l'écran donne l'heure du recours ; le recours est tracé comme
# tel ; les admins de la structure en sont avisés par courriel. Le parc sans
# cabinet n'a pas de délai.

private alias Cfg = PartiduoAdmin::Config
private alias Mode = PartiduoAdmin::ApprovalMode
private alias Admins = PartiduoAdmin::Administrators
private alias Approvals = PartiduoAdmin::Approvals

private def dual_cabinet(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User, PartiduoAdmin::User}
  firm = AdminSpec.firm(name)
  first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  Mode.set(first, firm, true).ok?.should be_true
  {firm, first, second}
end

# Horloge de la console avancée le temps d'un bloc.
private def at_time(time : Time, &)
  previous = Cfg.clock
  Cfg.clock = -> { time }
  yield
ensure
  Cfg.clock = previous if previous
end

describe "Dernier recours du super-admin après un délai (D-ADM-024)" do
  it "refuse le recours avant l'échéance, puis le trace comme tel et avise les admins du cabinet" do
    firm, first, second = dual_cabinet("Cabinet Délai")
    second.locale = "en"
    second.save!
    approval = Admins.request_active(first, second, false, "a quitté le cabinet").value!
    root = AdminSpec.super_admin
    Approvals.recourse?(root, approval).should be_true
    Approvals.recourse?(first, approval).should be_false
    Approvals.recourse_at(approval).should eq(SPEC_NOW + 48.hours)
    before = Marten::Spec.delivered_emails.size

    # Attaque : recours avant le délai, à la dernière minute comprise.
    Approvals.approve(root, approval).errors["base"].should eq(["admin.errors.approval.recourse_wait"])
    Approvals.approve(root, approval, SPEC_NOW + 48.hours - 1.minute).errors["base"]
      .should eq(["admin.errors.approval.recourse_wait"])
    second.reload.active.should be_true
    approval.reload.state.should eq("pending")
    Marten::Spec.delivered_emails.size.should eq(before)

    Approvals.approve(root, approval, SPEC_NOW + 48.hours).ok?.should be_true
    second.reload.active.should be_false
    approval.reload.decided_by_id.should eq(root.pk)
    PartiduoAdmin::AuditEntry.filter(action: "approval.approve", target_id: approval.pk).exists?.should be_false
    entry = PartiduoAdmin::AuditEntry.filter(action: "approval.recourse", target_id: approval.pk).first!
    entry.firm_id.should eq(firm.pk)
    detail = JSON.parse(entry.detail.to_s)
    detail["recourse_after_hours"].should eq("48")
    detail["notified"].as_s.split(',').sort!.should eq([first.email.to_s, second.email.to_s].sort!)

    # Avis par courriel, dans la langue de chacun.
    sent = Marten::Spec.delivered_emails[before..]
    sent.flat_map(&.to.map(&.address)).sort!.should eq([first.email.to_s, second.email.to_s].sort!)
    french = sent.find!(&.to.map(&.address).includes?(first.email.to_s))
    french.subject.to_s.should contain("validée en dernier recours")
    french.text_body.to_s.should contain(approval.reference.to_s)
    french.text_body.to_s.should contain(root.email.to_s)
    english = sent.find!(&.to.map(&.address).includes?(second.email.to_s))
    english.subject.to_s.should contain("approved as a last resort")
  end

  it "vaut aussi pour les demandes d'un dossier, et jamais pour un admin du cabinet" do
    firm, first, second = dual_cabinet("Cabinet Délai Dossier")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    approval = Approvals.request_admin_invite(first, dossier, "gerant@demo.fr", "gérant parti").value!
    Approvals.approve(AdminSpec.super_admin, approval).errors["base"].should eq(["admin.errors.approval.recourse_wait"])
    # L'autre admin du cabinet décide sans délai.
    Approvals.approve(second, approval).ok?.should be_true
    PartiduoAdmin::AuditEntry.filter(action: "approval.approve", target_id: approval.pk).count.should eq(1)
  end

  it "ne s'applique pas au parc sans cabinet, où les super-admins valident" do
    root = AdminSpec.super_admin
    other = AdminSpec.super_admin
    fleet = PartiduoAdmin::Directory.create_firm(root, "Parc Délai", kind: "fleet").value!
    Mode.set(root, fleet, true).ok?.should be_true
    approval = Admins.request_active(root, AdminSpec.super_admin, false, "départ").value!
    Approvals.recourse?(other, approval).should be_false
    Approvals.approve(other, approval).ok?.should be_true
  end

  it "se règle par l'instance, dans ses bornes" do
    Cfg.recourse_delay_from(nil).should eq(48.hours)
    Cfg.recourse_delay_from("12").should eq(12.hours)
    Cfg.recourse_delay_from(" 72 ").should eq(72.hours)
    {"0", "-3", "145", "deux jours", ""}.each { |value| Cfg.recourse_delay_from(value).should eq(48.hours) }
    firm, first, second = dual_cabinet("Cabinet Délai Réglé")
    approval = Admins.request_active(first, second, false).value!
    previous = Cfg.recourse_delay
    begin
      Cfg.recourse_delay = 12.hours
      Approvals.recourse_at(approval).should eq(SPEC_NOW + 12.hours)
      Approvals.approve(AdminSpec.super_admin, approval, SPEC_NOW + 12.hours).ok?.should be_true
    ensure
      Cfg.recourse_delay = previous
    end
    firm.reload.dual_approval.should be_false
  end

  it "montre l'heure du recours à la place du bouton, puis le bouton « Valider en dernier recours »" do
    firm, first, second = dual_cabinet("Cabinet Délai Écran")
    approval = Admins.request_active(first, second, false, "injoignable").value!
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    page = browser.get("/approvals").html
    page.should contain("Dernier recours possible à partir du")
    page.should contain((SPEC_NOW + 48.hours).to_s("%Y-%m-%d %H:%M UTC"))
    page.should_not contain("/approvals/#{approval.pk}/approve")
    page.should contain("/approvals/#{approval.pk}/reject")
    # Attaque : envoi direct du formulaire avant l'heure.
    browser.post("/approvals/#{approval.pk}/approve").headers["Location"].should eq("/approvals")
    second.reload.active.should be_true
    approval.reload.state.should eq("pending")

    later = SPEC_NOW + 49.hours
    at_time(later) do
      token = PartiduoAdmin::Auth::Sessions.open(root, PartiduoAdmin::Auth.required_level(root), "spec", now: later).token
      late = AdminSpec::Browser.new(token: token)
      late.get("/approvals").html.should contain("Valider en dernier recours")
      late.post("/approvals/#{approval.pk}/approve").headers["Location"].should eq("/approvals")
    end
    second.reload.active.should be_false
    firm.reload.dual_approval.should be_false
  end
end

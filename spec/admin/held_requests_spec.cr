# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Demande du super-admin sur un cabinet ou un gestionnaire indépendant réglé
# sur une personne (D-ADM-028) : elle attend le délai du dernier recours
# (D-ADM-024). Pendant ce délai, un admin actif de la structure la valide ou
# la refuse ; ensuite seulement, le super-admin la confirme seul. Les admins
# de la structure sont prévenus par courriel, dans leur langue, dès la
# demande ; l'écran donne l'échéance. Le parc sans cabinet n'est pas
# concerné. Aucun envoi réel : les courriels restent dans la file capturée
# de Marten.

private alias Cfg = PartiduoAdmin::Config
private alias Mode = PartiduoAdmin::ApprovalMode
private alias Admins = PartiduoAdmin::Administrators
private alias Approvals = PartiduoAdmin::Approvals

# Cabinet réglé sur une personne, avec deux admins actifs (l'un en anglais).
private def single_cabinet(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User, PartiduoAdmin::User}
  firm = AdminSpec.firm(name)
  first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  second.locale = "en"
  second.save!
  Mode.mode(firm).should eq(Mode::SINGLE)
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

private def sent_since(before : Int32)
  Marten::Spec.delivered_emails[before..]
end

describe "Demande du super-admin retenue jusqu'à l'échéance (D-ADM-028)" do
  it "prévient les admins dès la demande et refuse la confirmation seule avant l'échéance" do
    firm, first, second = single_cabinet("Cabinet Retenue")
    root = AdminSpec.super_admin
    before = Marten::Spec.delivered_emails.size
    approval = Admins.request_active(root, second, false, "compte compromis").value!
    approval.mode.should eq(Mode::SINGLE)
    Approvals.held?(approval).should be_true
    Approvals.recourse_at(approval).should eq(SPEC_NOW + 48.hours)

    # Avis aux admins actifs du cabinet, chacun dans sa langue ; jamais au
    # super-admin demandeur.
    sent = sent_since(before)
    sent.flat_map(&.to.map(&.address)).sort!.should eq([first.email.to_s, second.email.to_s].sort!)
    sent.none?(&.to.map(&.address).includes?(root.email.to_s)).should be_true
    french = sent.find!(&.to.map(&.address).includes?(first.email.to_s))
    french.subject.to_s.should contain("à valider ou refuser")
    body = french.text_body.to_s
    body.should contain(approval.reference.to_s)
    body.should contain("Demandée par : un super-administrateur")
    body.should_not contain(root.email.to_s)
    body.should contain("Pour toute question, écrivez au support Partiduo : #{Cfg.support_email}")
    body.should contain("Motif : compte compromis")
    body.should contain((SPEC_NOW + 48.hours).to_s("%Y-%m-%d %H:%M UTC"))
    english = sent.find!(&.to.map(&.address).includes?(second.email.to_s))
    english.subject.to_s.should contain("to approve or reject")
    request = PartiduoAdmin::AuditEntry.filter(action: "approval.request", target_id: approval.pk).first!
    detail = JSON.parse(request.detail.to_s)
    detail["notified"].as_s.split(',').sort!.should eq([first.email.to_s, second.email.to_s].sort!)
    detail["held_until"].should eq((SPEC_NOW + 48.hours).to_s("%Y-%m-%d %H:%M"))

    # Attaque : le super-admin confirme seul avant l'échéance, ré-authentifié
    # et case cochée, à la dernière minute comprise.
    Approvals.can_confirm_alone?(root, approval).should be_false
    Approvals.confirm_alone(root, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.confirm_wait"])
    Approvals.confirm_alone(root, approval, true, "yes", SPEC_NOW + 48.hours - 1.minute).errors["base"]
      .should eq(["admin.errors.approval.confirm_wait"])
    second.reload.active.should be_true
    approval.reload.state.should eq("pending")

    # À l'échéance, sans décision d'un admin : confirmation seule, tracée et
    # annoncée comme un dernier recours.
    at_echeance = SPEC_NOW + 48.hours
    Approvals.can_confirm_alone?(root, approval, at_echeance).should be_true
    Approvals.confirm_alone(root, approval, false, "yes", at_echeance).errors["reauth"].should eq(["admin.errors.approval.reauth"])
    middle = Marten::Spec.delivered_emails.size
    Approvals.confirm_alone(root, approval, true, "yes", at_echeance).ok?.should be_true
    second.reload.active.should be_false
    approval.reload.mode.should eq(Mode::SINGLE)
    approval.decided_by_id.should eq(root.pk)
    PartiduoAdmin::AuditEntry.filter(action: "approval.confirm_alone", target_id: approval.pk).exists?.should be_false
    entry = PartiduoAdmin::AuditEntry.filter(action: "approval.recourse", target_id: approval.pk).first!
    entry.firm_id.should eq(firm.pk)
    recourse = JSON.parse(entry.detail.to_s)
    recourse["mode"].should eq(Mode::SINGLE)
    recourse["recourse_after_hours"].should eq("48")
    recourse["notified"].as_s.split(',').sort!.should eq([first.email.to_s, second.email.to_s].sort!)
    sent_since(middle).flat_map(&.to.map(&.address)).sort!.should eq([first.email.to_s, second.email.to_s].sort!)
  end

  it "laisse un admin du cabinet valider ou refuser pendant le délai" do
    _, first, second = single_cabinet("Cabinet Retenue Décision")
    root = AdminSpec.super_admin
    approval = Admins.request_active(root, second, false, "départ").value!
    Approvals.approve(first, approval).ok?.should be_true
    second.reload.active.should be_false
    approval.reload.decided_by_id.should eq(first.pk)
    PartiduoAdmin::AuditEntry.filter(action: "approval.approve", target_id: approval.pk).count.should eq(1)

    third = AdminSpec.user(Cfg::FIRM_ADMIN, first.firm)
    refused = Admins.request_active(root, third, false, "doute").value!
    Approvals.reject(first, refused).should be_true
    refused.reload.state.should eq("rejected")
    third.reload.active.should be_true
    # Une demande refusée ne se confirme plus, même après l'échéance.
    Approvals.confirm_alone(root, refused, true, "yes", AdminSpec.recourse_time).errors["base"]
      .should eq(["admin.errors.approval.state"])
  end

  it "vaut pour les demandes d'un dossier, et pas pour un cabinet sans admin" do
    firm, _, _ = single_cabinet("Cabinet Retenue Dossier")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    root = AdminSpec.super_admin
    approval = Approvals.request_admin_invite(root, dossier, "gerant@demo.fr", "gérant parti").value!
    Approvals.confirm_alone(root, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.confirm_wait"])
    Approvals.confirm_alone(root, approval, true, "yes", AdminSpec.recourse_time).ok?.should be_true
    approval.reload.task.should_not be_nil

    # Personne à prévenir ni pour décider : la confirmation reste immédiate.
    empty = AdminSpec.firm("Cabinet Sans Admin")
    alone = AdminSpec.dossier(empty, server)
    before = Marten::Spec.delivered_emails.size
    direct = Approvals.request_admin_invite(root, alone, "gerant@demo.fr", "gérant parti").value!
    Approvals.held?(direct).should be_false
    Approvals.confirm_alone(root, direct, true, "yes").ok?.should be_true
    Marten::Spec.delivered_emails.size.should eq(before)
  end

  it "ne retient pas les demandes d'un admin du cabinet ni celles du parc sans cabinet" do
    _, first, second = single_cabinet("Cabinet Retenue Admin")
    own = Admins.request_active(first, second, false, "départ").value!
    Approvals.held?(own).should be_false
    Approvals.confirm_alone(first, own, true, "yes").ok?.should be_true

    root = AdminSpec.super_admin
    other = AdminSpec.super_admin
    fleet = PartiduoAdmin::Directory.create_firm(root, "Parc Retenue", kind: "fleet").value!
    Mode.mode(fleet).should eq(Mode::SINGLE)
    approval = Admins.request_active(root, other, false, "départ").value!
    Approvals.held?(approval).should be_false
    Approvals.confirm_alone(root, approval, true, "yes").ok?.should be_true
  end

  it "montre l'échéance à la place du lien « Confirmer », puis le lien" do
    _, _, second = single_cabinet("Cabinet Retenue Écran")
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    response = browser.post("/users/#{second.pk}/disable", {"reason" => "injoignable"})
    approval = PartiduoAdmin::Approval.filter(requested_by_id: root.pk, kind: "admin_disable").order("-id").first!
    response.headers["Location"].should_not eq("/approvals/#{approval.pk}/confirm")
    page = browser.get("/approvals").html
    page.should contain("Confirmation seule possible à partir du")
    page.should contain((SPEC_NOW + 48.hours).to_s("%Y-%m-%d %H:%M UTC"))
    page.should_not contain("/approvals/#{approval.pk}/confirm\"")
    confirm = browser.get("/approvals/#{approval.pk}/confirm").html
    confirm.should contain("Les admins de la structure ont été prévenus par courriel")
    confirm.should_not contain("name=\"confirm\"")
    # Attaque : envoi direct du formulaire avant l'heure.
    browser.post("/approvals/#{approval.pk}/confirm", {"confirm" => "yes"})
    second.reload.active.should be_true
    approval.reload.state.should eq("pending")

    later = AdminSpec.recourse_time
    at_time(later) do
      token = PartiduoAdmin::Auth::Sessions.open(root, PartiduoAdmin::Auth.required_level(root), "spec", now: later).token
      late = AdminSpec::Browser.new(token: token)
      late.get("/approvals").html.should contain("/approvals/#{approval.pk}/confirm")
    end
  end
end

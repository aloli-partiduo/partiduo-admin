# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Autres actions sensibles soumises à validation (D-ADM-026) : réinvitation
# d'un admin (sessions et moyens d'authentification révoqués),
# désactivation et réactivation d'une structure, changement de sa nature.
# Mêmes règles que D-ADM-023 : relecture en base à la décision, personne
# ne valide sa propre demande, expiration au bout de sept jours, mode
# simple avec ré-authentification forte.

private alias Cfg = PartiduoAdmin::Config
private alias Mode = PartiduoAdmin::ApprovalMode
private alias Admins = PartiduoAdmin::Administrators
private alias Approvals = PartiduoAdmin::Approvals
private alias Firms = PartiduoAdmin::Firms

private def duo(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User, PartiduoAdmin::User}
  firm = AdminSpec.firm(name)
  first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  Mode.set(first, firm, true).ok?.should be_true
  {firm, first, second}
end

describe "Réinvitation d'un admin soumise à validation (D-ADM-026)" do
  it "passe par une demande : rien n'est révoqué avant la décision, puis tout l'est" do
    _, first, second = duo("Cabinet Réinvitation")
    AdminSpec.session(second)
    approval = Admins.request_reinvite(first, second, "téléphone perdu").value!
    approval.kind.should eq("admin_reinvite")
    second.reload.usable_password?.should be_true
    PartiduoAdmin::Session.filter(user_id: second.pk, revoked_at__isnull: true).exists?.should be_true
    # Attaque : même personne, par le service et par la base.
    Approvals.approve(first, approval).errors["base"].should eq(["admin.errors.approval.same_person"])
    Marten::DB::Connection.default.open do |db|
      expect_raises(Exception) do
        db.exec("UPDATE admin_approval SET state = 'approved', decided_by_id = requested_by_id WHERE id = $1", approval.pk)
      end
    end
    # Attaque : recours du super-admin avant le délai.
    Approvals.approve(AdminSpec.super_admin, approval).errors["base"].should eq(["admin.errors.approval.recourse_wait"])
    second.reload.usable_password?.should be_true
    Approvals.approve(AdminSpec.super_admin, approval, AdminSpec.recourse_time).ok?.should be_true
    second.reload.usable_password?.should be_false
    second.totp_enabled?.should be_false
    PartiduoAdmin::Session.filter(user_id: second.pk, revoked_at__isnull: true).exists?.should be_false
    PartiduoAdmin::AuditEntry.filter(action: "user.reinvite", target_id: second.pk).count.should eq(1)
    # Attaque : demande rejouée.
    Approvals.approve(AdminSpec.super_admin, approval, AdminSpec.recourse_time).errors["base"]
      .should eq(["admin.errors.approval.state"])
    PartiduoAdmin::AuditEntry.filter(action: "user.reinvite", target_id: second.pk).count.should eq(1)
  end

  it "se confirme seul à une personne, clôt une demande dont le compte a changé, laisse un gestionnaire réinvité aussitôt" do
    firm = AdminSpec.firm("Cabinet Réinvitation Seul")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    other = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    approval = Admins.request_reinvite(admin, other).value!
    Approvals.confirm_alone(admin, approval, false, "yes").errors["reauth"].should eq(["admin.errors.approval.reauth"])
    # Attaque : cible modifiée entre la demande et la décision.
    PartiduoAdmin::Directory.set_active(admin, other, false).should be_true
    Approvals.confirm_alone(admin, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.target_changed"])
    other.reload.usable_password?.should be_true
    approval.reload.state.should eq("expired")
    # Un gestionnaire de dossiers : sans demande, comme D-ADM-023.
    manager = AdminSpec.user(Cfg::FILE_MANAGER, firm)
    Admins.account_gate(manager).should be_nil
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    browser.post("/users/#{manager.pk}/reinvite").headers["Location"].should eq("/users")
    manager.reload.usable_password?.should be_false
  end

  it "fait passer la réinvitation de l'écran des utilisateurs par une demande" do
    firm, first, second = duo("Cabinet Réinvitation Écran")
    browser = AdminSpec::Browser.new(token: AdminSpec.session(first))
    browser.post("/users/#{second.pk}/reinvite", {"reason" => "clé perdue"}).headers["Location"].should eq("/users")
    second.reload.usable_password?.should be_true
    approval = PartiduoAdmin::Approval.filter(firm_id: firm.pk, kind: "admin_reinvite").first!
    approval.reason.should eq("clé perdue")
    page = AdminSpec::Browser.new(token: AdminSpec.session(second)).get("/approvals").html
    page.should contain("réinvitation d'un compte d'admin")
    page.should contain("/approvals/#{approval.pk}/approve")
  end
end

describe "Désactivation, réactivation et nature d'une structure soumises à validation (D-ADM-026)" do
  it "désactive une structure par une demande confirmée seule, ses sessions fermées" do
    firm = AdminSpec.firm("Cabinet Désactivé")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    AdminSpec.session(admin)
    root = AdminSpec.super_admin
    Firms.set_active(root, firm, false).errors["base"].should eq(["admin.errors.approval.needs_request"])
    Firms.request_active(admin, firm, false).errors["base"].should eq(["admin.errors.forbidden"])
    approval = Firms.request_active(root, firm, false, "fin de contrat").value!
    approval.kind.should eq("firm_disable")
    firm.reload.active.should be_true
    Approvals.can_confirm_alone?(root, approval).should be_true
    Approvals.confirm_alone(root, approval, true, "yes").ok?.should be_true
    firm.reload.active.should be_false
    admin.reload.can_sign_in?.should be_false
    PartiduoAdmin::Session.filter(user_id: admin.pk, revoked_at__isnull: true).exists?.should be_false
    PartiduoAdmin::AuditEntry.filter(action: "firm.disable", target_id: firm.pk).last!.detail.to_s.should contain(approval.reference.to_s)
    # Réactivation : de même.
    back = Firms.request_active(root, firm, true).value!
    Approvals.confirm_alone(root, back, true, "yes").ok?.should be_true
    firm.reload.active.should be_true
    # Sans équipe : aussitôt.
    empty = AdminSpec.firm("Cabinet Sans Équipe")
    Firms.set_active(root, empty, false).ok?.should be_true
    # Parc sans cabinet : jamais.
    fleet = PartiduoAdmin::Directory.create_firm(root, "Parc Fixe", kind: "fleet").value!
    Firms.request_active(root, fleet, false).errors["base"].should eq(["admin.errors.firm.fleet_fixed"])
  end

  it "à deux personnes, fait valider par un admin de la structure, un autre super-admin seulement après le délai" do
    firm, first, _ = duo("Cabinet Désactivé Duo")
    root = AdminSpec.super_admin
    approval = Firms.request_active(root, firm, false, "impayés").value!
    approval.mode.should eq("dual")
    Approvals.confirm_alone(root, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.dual_required"])
    Approvals.approve(root, approval).errors["base"].should eq(["admin.errors.approval.same_person"])
    Approvals.approve(AdminSpec.super_admin, approval).errors["base"].should eq(["admin.errors.approval.recourse_wait"])
    Approvals.approve(AdminSpec.user(Cfg::FIRM_ADMIN, AdminSpec.firm), approval).errors["base"].should eq(["admin.errors.forbidden"])
    firm.reload.active.should be_true
    Approvals.approve(first, approval).ok?.should be_true
    firm.reload.active.should be_false
  end

  it "change la nature d'une structure, recontrôlée à la décision" do
    firm = AdminSpec.firm("Cabinet Nature")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    root = AdminSpec.super_admin
    Firms.set_kind(root, firm, "independent").errors["base"].should eq(["admin.errors.approval.needs_request"])
    Firms.request_kind(root, firm, "fleet").errors["kind"].should eq(["admin.errors.firm.fleet_fixed"])
    approval = Firms.request_kind(root, firm, "independent", "une seule personne").value!
    I18n.with_locale("fr") { approval.detail_text }.should eq("Cabinet → Gestionnaire indépendant")
    # Attaque : cible modifiée — un gestionnaire arrive entre la demande et la décision.
    manager = AdminSpec.user(Cfg::FILE_MANAGER, firm)
    Approvals.confirm_alone(root, approval, true, "yes").errors["kind"].should eq(["admin.errors.firm.independent_single"])
    approval.reload.state.should eq("expired")
    firm.reload.kind.should eq("cabinet")
    PartiduoAdmin::Directory.set_active(admin, manager, false).should be_true
    again = Firms.request_kind(root, firm, "independent").value!
    # Attaque : état de la structure changé entre-temps (désactivée).
    firm.active = false
    firm.save!
    Approvals.confirm_alone(root, again, true, "yes").errors["base"].should eq(["admin.errors.approval.target_changed"])
    firm.active = true
    firm.save!
    third = Firms.request_kind(root, firm, "independent").value!
    Approvals.confirm_alone(root, third, true, "yes").ok?.should be_true
    firm.reload.kind.should eq("independent")
    PartiduoAdmin::AuditEntry.filter(action: "firm.kind", target_id: firm.pk).count.should eq(1)
    # Expirée au bout de sept jours.
    late = Firms.request_kind(root, firm, "cabinet").value!
    Approvals.confirm_alone(root, late, true, "yes", SPEC_NOW + Cfg::APPROVAL_TTL + 1.minute).errors["base"]
      .should eq(["admin.errors.approval.expired"])
    firm.reload.kind.should eq("independent")
  end

  it "sert la fiche de la structure au seul super-admin, dans les sept langues, et mène à la confirmation" do
    firm = AdminSpec.firm("Cabinet Fiche")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    root = AdminSpec.super_admin
    AdminSpec::Browser.new(token: AdminSpec.session(admin)).get("/firms/#{firm.pk}/settings").status.should eq(403)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    browser.get("/firms").html.should contain(%(href="/firms/#{firm.pk}/settings"))
    requested = browser.post("/firms/#{firm.pk}/settings", {"command" => "disable", "reason" => "fin"})
    approval = PartiduoAdmin::Approval.filter(firm_id: firm.pk, kind: "firm_disable").first!
    requested.headers["Location"].should eq("/approvals/#{approval.pk}/confirm")
    browser.get("/approvals/#{approval.pk}/confirm").html.should contain("Je confirme la désactivation de la structure")
    Firms.request_kind(root, firm, "independent").value!
    Cfg::LOCALES.each do |locale|
      root.locale = locale
      root.save!
      response = AdminSpec::Browser.new(locale, token: AdminSpec.session(root)).get("/firms/#{firm.pk}/settings")
      response.status.should eq(200)
      response.html.should contain(%(<html lang="#{locale}">))
      PartiduoTranslations.problems(response.html).should eq([] of String)
    end
  end
end

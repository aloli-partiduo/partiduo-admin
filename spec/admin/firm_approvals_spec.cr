# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Validation des actions propres à une structure (D-ADM-023) : demande sans
# dossier, inviter, nommer, retirer, remplacer un admin, désactiver ou
# réactiver un compte d'admin, repasser à une personne ; mode « une
# personne » (confirmation seule après ré-authentification forte) et
# « deux personnes » (une autre personne valide) ; règle anti-blocage ;
# specs d'attaque ; écrans dans les sept langues.

private alias Cfg = PartiduoAdmin::Config
private alias Mode = PartiduoAdmin::ApprovalMode
private alias Admins = PartiduoAdmin::Administrators
private alias Approvals = PartiduoAdmin::Approvals

private def session_for(user : PartiduoAdmin::User, strong_ago : Time::Span? = nil) : String
  opened = PartiduoAdmin::Auth::Sessions.open(user, PartiduoAdmin::Auth.required_level(user), "spec", now: SPEC_NOW)
  if ago = strong_ago
    opened.session.strong_auth_at = SPEC_NOW - ago
    opened.session.save!
  end
  opened.token
end

# Cabinet de deux admins réglé sur « deux personnes ».
private def dual_firm(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User, PartiduoAdmin::User}
  firm = AdminSpec.firm(name)
  first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  Mode.set(first, firm, true).ok?.should be_true
  {firm, first, second}
end

private def invite_input(email : String, firm : PartiduoAdmin::Firm) : PartiduoAdmin::Directory::UserInput
  PartiduoAdmin::Directory::UserInput.new(email: email, first_name: "Ada", last_name: "Lovelace",
    role: Cfg::FIRM_ADMIN, firm_id: firm.pk!.as(Int64))
end

private def sql_refused(sql : String, *args) : Bool
  Marten::DB::Connection.default.open(&.exec(sql, *args))
  false
rescue
  true
end

describe "Demande sans dossier (D-ADM-023)" do
  it "vise une structure, jamais un dossier et une structure à la fois, et laisse intactes les demandes d'un dossier" do
    server, _ = AdminSpec.server
    firm = AdminSpec.firm
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    dossier = AdminSpec.dossier(firm, server)
    old = Approvals.request_admin_invite(admin, dossier, "gerant@demo.fr", "gérant parti").value!
    old.firm_id.should be_nil
    old.target_firm.try(&.pk).should eq(firm.pk)

    approval = Admins.request_invite(admin, invite_input("nouvelle@cabinet.fr", firm), "renfort").value!
    approval.dossier_id.should be_nil
    approval.firm_id.should eq(firm.pk)
    approval.firm_target?.should be_true
    approval.mode.should eq("single")
    approval.target_label.should eq("nouvelle@cabinet.fr")
    PartiduoAdmin::User.filter(email: "nouvelle@cabinet.fr").exists?.should be_false
    entry = PartiduoAdmin::AuditEntry.filter(action: "approval.request").last!
    entry.firm_id.should eq(firm.pk)

    # La base refuse une demande sans cible ou à deux cibles.
    sql_refused("UPDATE admin_approval SET firm_id = $1 WHERE id = $2", firm.pk, old.pk).should be_true
    sql_refused("UPDATE admin_approval SET firm_id = NULL WHERE id = $1", approval.pk).should be_true
    # Une seule demande en attente par type et par cible.
    Admins.request_invite(admin, invite_input("nouvelle@cabinet.fr", firm), "bis").errors["base"]
      .should eq(["admin.errors.approval.already_pending"])
  end

  it "laisse inviter le premier admin d'une structure sans demande, comme à sa création" do
    root = AdminSpec.super_admin
    firm = AdminSpec.firm
    Admins.invite_gate(root, invite_input("premier@cabinet.fr", firm)).should be_nil
    AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    Admins.invite_gate(root, invite_input("second@cabinet.fr", firm)).try(&.pk).should eq(firm.pk)
    # Un gestionnaire de dossiers n'est jamais soumis à validation.
    manager = invite_input("gestion@cabinet.fr", firm).copy_with(role: Cfg::FILE_MANAGER)
    Admins.invite_gate(root, manager).should be_nil
  end
end

describe "Structure à une personne : le demandeur confirme seul (D-ADM-023, D-VAL2-004)" do
  it "exige une ré-authentification forte récente et la case cochée, puis invite et trace" do
    firm = AdminSpec.firm
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    approval = Admins.request_invite(admin, invite_input("ada@cabinet.fr", firm)).value!
    Approvals.can_confirm_alone?(admin, approval).should be_true
    Approvals.confirm_alone(admin, approval, false, "yes").errors["reauth"].should eq(["admin.errors.approval.reauth"])
    Approvals.confirm_alone(admin, approval, true, "").errors["confirmation"].should eq(["admin.errors.approval.confirmation"])
    PartiduoAdmin::User.filter(email: "ada@cabinet.fr").exists?.should be_false
    outcome = Approvals.confirm_alone(admin, approval, true, "yes")
    outcome.ok?.should be_true
    outcome.value.should be_nil
    invited = PartiduoAdmin::User.get!(email: "ada@cabinet.fr")
    {invited.role, invited.firm_id}.should eq({Cfg::FIRM_ADMIN, firm.pk})
    approval.reload.state.should eq("approved")
    approval.decided_by_id.should eq(admin.pk)
    PartiduoAdmin::AuditEntry.filter(action: "approval.confirm_alone").count.should eq(1)
    PartiduoAdmin::AuditEntry.filter(action: "user.invite", actor_id: admin.pk).count.should eq(1)
  end

  it "désactive un admin, le nomme, le retire et le remplace par des demandes confirmées seules" do
    firm = AdminSpec.firm
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    other = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    manager = AdminSpec.user(Cfg::FILE_MANAGER, firm)

    demote = Admins.request_role(admin, firm, other, Cfg::FILE_MANAGER, false).value!
    demote.kind.should eq("firm_demote")
    Approvals.confirm_alone(admin, demote, true, "yes").ok?.should be_true
    other.reload.role.should eq(Cfg::FILE_MANAGER)

    promote = Admins.request_role(admin, firm, manager, Cfg::FIRM_ADMIN, false).value!
    Approvals.confirm_alone(admin, promote, true, "yes").ok?.should be_true
    manager.reload.role.should eq(Cfg::FIRM_ADMIN)

    disable = Admins.request_active(admin, manager, false).value!
    disable.kind.should eq("admin_disable")
    Approvals.confirm_alone(admin, disable, true, "yes").ok?.should be_true
    manager.reload.active.should be_false
    enable = Admins.request_active(admin, manager, true).value!
    Approvals.confirm_alone(admin, enable, true, "yes").ok?.should be_true
    manager.reload.active.should be_true

    replace = Admins.request_replace(admin, firm, manager, invite_input("releve@cabinet.fr", firm), false).value!
    replace.param_replaces.should eq(manager.email)
    Approvals.confirm_alone(admin, replace, true, "yes").ok?.should be_true
    manager.reload.role.should eq(Cfg::FILE_MANAGER)
    Admins.firm_admins(firm).map(&.email).should contain("releve@cabinet.fr")
  end

  it "garde les règles du service : jamais zéro admin, retrait de soi-même confirmé" do
    firm = AdminSpec.firm
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    Admins.request_role(admin, firm, admin, Cfg::FILE_MANAGER, true).errors["base"].should eq(["admin.errors.administrators.last"])
    other = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    Admins.request_role(admin, firm, admin, Cfg::FILE_MANAGER, false).errors["self_confirm"]
      .should eq(["admin.errors.administrators.self_confirm"])
    # Deux retraits croisés demandés ensemble : une fois le premier fait,
    # l'auteur du second n'est plus admin, et sa demande est close.
    first = Admins.request_role(admin, firm, other, Cfg::FILE_MANAGER, false).value!
    second = Admins.request_role(other, firm, admin, Cfg::FILE_MANAGER, false).value!
    Approvals.confirm_alone(admin, first, true, "yes").ok?.should be_true
    Approvals.confirm_alone(other.reload, second, true, "yes").errors["base"].should eq(["admin.errors.approval.needs_admin"])
    # Validée par un autre (le super-admin) : le demandeur n'est plus admin.
    Approvals.approve(AdminSpec.super_admin, second, AdminSpec.recourse_time).errors["base"].should eq(["admin.errors.approval.requester_gone"])
    admin.reload.role.should eq(Cfg::FIRM_ADMIN)
    second.reload.state.should eq("expired")
  end
end

describe "Structure à deux personnes : une autre personne valide (D-ADM-023)" do
  it "refuse la validation par le demandeur lui-même, par l'interface comme par la base" do
    firm, first, second = dual_firm("Cabinet Duo Admins")
    manager = AdminSpec.user(Cfg::FILE_MANAGER, firm)
    approval = Admins.request_role(first, firm, manager, Cfg::FIRM_ADMIN, false, "renfort").value!
    approval.mode.should eq("dual")
    Approvals.can_confirm_alone?(first, approval).should be_false
    Approvals.confirm_alone(first, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.dual_required"])
    Approvals.approve(first, approval).errors["base"].should eq(["admin.errors.approval.same_person"])
    # Écriture directe : la base refuse une validation à deux par le demandeur.
    sql_refused("UPDATE admin_approval SET state = 'approved', decided_by_id = requested_by_id WHERE id = $1", approval.pk)
      .should be_true
    sql_refused("UPDATE admin_approval SET state = 'approved' WHERE id = $1", approval.pk).should be_true
    manager.reload.role.should eq(Cfg::FILE_MANAGER)
    # Un gestionnaire, un admin d'une autre structure : pas habilités.
    Approvals.approve(AdminSpec.user(Cfg::FILE_MANAGER, firm), approval).errors["base"].should eq(["admin.errors.forbidden"])
    Approvals.approve(AdminSpec.user(Cfg::FIRM_ADMIN, AdminSpec.firm), approval).errors["base"].should eq(["admin.errors.forbidden"])
    Approvals.approve(second, approval).ok?.should be_true
    manager.reload.role.should eq(Cfg::FIRM_ADMIN)
    approval.reload.decided_by_id.should eq(second.pk)
    entry = PartiduoAdmin::AuditEntry.filter(action: "approval.approve").last!
    entry.firm_id.should eq(firm.pk)
    JSON.parse(entry.detail.to_s)["mode"].should eq("dual")
  end

  it "ne rejoue jamais une demande décidée, refusée ou retirée" do
    firm, first, second = dual_firm("Cabinet Rejeu")
    approval = Admins.request_invite(first, invite_input("rejeu@cabinet.fr", firm)).value!
    Approvals.approve(second, approval).ok?.should be_true
    Approvals.approve(second, approval).errors["base"].should eq(["admin.errors.approval.state"])
    Approvals.approve(AdminSpec.super_admin, approval).errors["base"].should eq(["admin.errors.approval.state"])
    PartiduoAdmin::User.filter(email: "rejeu@cabinet.fr").count.should eq(1)
    refused = Admins.request_invite(first, invite_input("refus@cabinet.fr", firm)).value!
    Approvals.reject(second, refused).should be_true
    Approvals.approve(second, refused).errors["base"].should eq(["admin.errors.approval.state"])
    PartiduoAdmin::User.filter(email: "refus@cabinet.fr").exists?.should be_false
    # Échue : expirée, jamais faite.
    late = Admins.request_invite(first, invite_input("tard@cabinet.fr", firm)).value!
    Approvals.approve(second, late, SPEC_NOW + Cfg::APPROVAL_TTL + 1.minute).errors["base"]
      .should eq(["admin.errors.approval.expired"])
    PartiduoAdmin::User.filter(email: "tard@cabinet.fr").exists?.should be_false
  end

  it "clôt une demande dont la cible a changé depuis, sans rien faire" do
    firm, first, second = dual_firm("Cabinet Cible")
    third = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    approval = Admins.request_role(first, firm, third, Cfg::FILE_MANAGER, false, "départ").value!
    # Entre-temps, le compte visé est désactivé (autre geste validé).
    PartiduoAdmin::Directory.set_active(second, third, false).should be_true
    Approvals.approve(second, approval).errors["base"].should eq(["admin.errors.approval.target_changed"])
    third.reload.role.should eq(Cfg::FIRM_ADMIN)
    approval.reload.state.should eq("expired")
    PartiduoAdmin::AuditEntry.filter(action: "approval.stale", outcome: "refused").count.should eq(1)
    # Adresse prise entre la demande et la décision : rien n'est créé.
    invite = Admins.request_invite(first, invite_input("prise@cabinet.fr", firm)).value!
    AdminSpec.user(Cfg::FILE_MANAGER, AdminSpec.firm, email: "prise@cabinet.fr")
    Approvals.approve(second, invite).errors["email"].should eq(["admin.errors.user.email_taken"])
    invite.reload.state.should eq("expired")
  end

  it "réserve au super-admin les demandes qui touchent un compte de super-admin" do
    root = AdminSpec.super_admin
    other_root = AdminSpec.super_admin
    fleet = PartiduoAdmin::Directory.create_firm(root, "Parc", kind: "fleet").value!
    fleet_admin = AdminSpec.user(Cfg::FIRM_ADMIN, fleet)
    Mode.set(root, fleet, true).ok?.should be_true
    approval = Admins.request_active(root, other_root, false, "départ").value!
    approval.super_scope?.should be_true
    Approvals.approve(fleet_admin, approval).errors["base"].should eq(["admin.errors.forbidden"])
    third = AdminSpec.super_admin
    Approvals.approve(third, approval).ok?.should be_true
    other_root.reload.active.should be_false
  end
end

describe "Retour à une personne et règle anti-blocage (D-ADM-023)" do
  it "passe aussitôt à deux personnes, mais ne revient à une personne que validé par un autre" do
    firm = AdminSpec.firm
    first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    Mode.set(first, firm, true).ok?.should be_true
    Mode.set(first, firm, false).errors["mode"].should eq(["admin.errors.dual_approval.needs_approval"])
    approval = Mode.request_single(first, firm, "équipe réduite").value!
    approval.kind.should eq("mode_single")
    Approvals.confirm_alone(first, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.dual_required"])
    Approvals.approve(first, approval).errors["base"].should eq(["admin.errors.approval.same_person"])
    firm.reload.dual_approval.should be_true
    Approvals.approve(second, approval).ok?.should be_true
    firm.reload.dual_approval.should be_false
    entry = PartiduoAdmin::AuditEntry.filter(action: "dual_approval.change").last!
    JSON.parse(entry.detail.to_s)["approval"].should eq(approval.reference)
    # Déjà à une personne : rien à demander.
    Mode.request_single(first, firm).errors["mode"].should eq(["admin.errors.invalid"])
  end

  it "clôt la demande de retour si la structure est revenue d'elle-même à une personne" do
    firm, first, second = dual_firm("Cabinet Auto")
    approval = Mode.request_single(first, firm).value!
    PartiduoAdmin::Directory.set_active(first, second, false).should be_true
    firm.reload.dual_approval.should be_false
    Approvals.confirm_alone(first, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.target_changed"])
    approval.reload.state.should eq("expired")
  end

  it "ne bloque jamais un cabinet : le super-admin valide si l'autre admin est injoignable, l'équipe réduite repasse à une personne" do
    firm, first, second = dual_firm("Cabinet Injoignable")
    approval = Admins.request_active(first, second, false, "a quitté le cabinet").value!
    approval.mode.should eq("dual")
    Approvals.approve(AdminSpec.super_admin, approval, AdminSpec.recourse_time).ok?.should be_true
    second.reload.active.should be_false
    firm.reload.dual_approval.should be_false
    PartiduoAdmin::AuditEntry.filter(action: "dual_approval.auto_off").count.should eq(1)
    # Désormais à une personne : le dernier admin confirme seul, et ne se
    # retire jamais lui-même.
    invite = Admins.request_invite(first, invite_input("successeur@cabinet.fr", firm)).value!
    Approvals.can_confirm_alone?(first, invite).should be_true
    Admins.request_active(AdminSpec.super_admin, first, false).errors["base"].should eq(["admin.errors.administrators.last"])
  end

  it "rend la main au parc sans cabinet par la ligne de commande du serveur" do
    root = AdminSpec.super_admin
    AdminSpec.super_admin
    fleet = PartiduoAdmin::Directory.create_firm(root, "Parc", kind: "fleet").value!
    Mode.set(root, fleet, true).ok?.should be_true
    command = ->(args : Array(String)) do
      PartiduoAdmin::Commands::ApprovalModeSingle.new(args, stdout: IO::Memory.new, stderr: IO::Memory.new, exit_raises: true).handle
    end
    command.call(["--firm=#{fleet.pk}"]).should eq(1)
    fleet.reload.dual_approval.should be_true
    command.call(["--firm=#{fleet.pk}", "--reason=second super-admin injoignable"]).should eq(0)
    fleet.reload.dual_approval.should be_false
    entry = PartiduoAdmin::AuditEntry.filter(action: "dual_approval.cli_off").first!
    entry.actor_label.should eq("cli")
    JSON.parse(entry.detail.to_s)["reason"].should eq("second super-admin injoignable")
  end
end

describe "Écrans des demandes de structure (D-ADM-023)" do
  it "mène de l'invitation à la confirmation seule, refuse une ré-authentification trop ancienne" do
    firm = AdminSpec.firm("Cabinet Écran Seul")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: session_for(admin, 10.minutes))
    requested = browser.post("/firms/#{firm.pk}/admins", {"email" => "ecran@cabinet.fr", "first_name" => "Ada", "locale" => "fr", "reason" => "renfort"})
    requested.status.should eq(302)
    approval = PartiduoAdmin::Approval.filter(firm_id: firm.pk).first!
    requested.headers["Location"].should eq("/approvals/#{approval.pk}/confirm")
    page = browser.get("/approvals/#{approval.pk}/confirm").html
    page.should contain("Je confirme l'invitation comme admin de la structure de")
    page.should contain("ecran@cabinet.fr")
    page.should contain(firm.name.to_s)
    # Ré-authentification trop ancienne : refus, rien n'est fait.
    browser.post("/approvals/#{approval.pk}/confirm", {"confirm" => "yes"}).status.should eq(422)
    PartiduoAdmin::User.filter(email: "ecran@cabinet.fr").exists?.should be_false
    browser.post("/reauth/totp", {"code" => AdminSpec.totp_code(admin, SPEC_NOW), "next" => "/approvals/#{approval.pk}/confirm"})
    done = browser.post("/approvals/#{approval.pk}/confirm", {"confirm" => "yes"})
    done.status.should eq(302)
    done.headers["Location"].should eq("/firms/#{firm.pk}/admins")
    PartiduoAdmin::User.filter(email: "ecran@cabinet.fr").exists?.should be_true
    # Rejeu du même formulaire : la demande est déjà traitée.
    browser.post("/approvals/#{approval.pk}/confirm", {"confirm" => "yes"}).status.should eq(422)
    PartiduoAdmin::User.filter(email: "ecran@cabinet.fr").count.should eq(1)
  end

  it "montre « en attente de validation » et la demande dans la liste, que l'autre admin valide" do
    firm, first, second = dual_firm("Cabinet Écran Deux")
    manager = AdminSpec.user(Cfg::FILE_MANAGER, firm)
    browser = AdminSpec::Browser.new(token: session_for(first))
    promoted = browser.post("/firms/#{firm.pk}/admins/#{manager.pk}/promote", {"reason" => "renfort"})
    promoted.headers["Location"].should eq("/firms/#{firm.pk}/admins")
    manager.reload.role.should eq(Cfg::FILE_MANAGER)
    disabled = browser.post("/users/#{second.pk}/disable")
    disabled.headers["Location"].should eq("/users")
    second.reload.active.should be_true
    page = browser.get("/firms/#{firm.pk}/admins").html
    page.should contain("En attente de validation")
    page.should contain("nomination d'un admin de la structure")
    page.should contain("désactivation d'un compte d'admin")
    mode = browser.post("/firms/#{firm.pk}/approval-mode", {"mode" => "single", "reason" => "équipe réduite"})
    mode.headers["Location"].should eq("/firms/#{firm.pk}/approval-mode")
    firm.reload.dual_approval.should be_true
    browser.get("/firms/#{firm.pk}/approval-mode").html.should contain("retour à la validation à une personne")

    other = AdminSpec::Browser.new(token: session_for(second))
    list = other.get("/approvals").html
    list.should contain("Structure")
    list.should contain(firm.name.to_s)
    approval = PartiduoAdmin::Approval.filter(firm_id: firm.pk, kind: "firm_promote").first!
    list.should contain("/approvals/#{approval.pk}/approve")
    other.post("/approvals/#{approval.pk}/approve").headers["Location"].should eq("/approvals")
    manager.reload.role.should eq(Cfg::FIRM_ADMIN)
    # Le demandeur ne voit pas de bouton « Valider » sur ses propres demandes.
    own = browser.get("/approvals").html
    mine = PartiduoAdmin::Approval.filter(firm_id: firm.pk, kind: "mode_single").first!
    own.should_not contain("/approvals/#{mine.pk}/approve")
    browser.post("/approvals/#{mine.pk}/approve").status.should eq(302)
    firm.reload.dual_approval.should be_true
    # Une autre structure ne voit pas ces demandes.
    stranger = AdminSpec::Browser.new(token: session_for(AdminSpec.user(Cfg::FIRM_ADMIN, AdminSpec.firm)))
    stranger.get("/approvals").html.should_not contain(firm.name.to_s)
    stranger.post("/approvals/#{mine.pk}/approve").status.should eq(403)
  end

  it "fait passer l'invitation d'un admin par l'écran des utilisateurs par une demande" do
    firm = AdminSpec.firm("Cabinet Utilisateurs")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: session_for(admin))
    browser.get("/users/new").html.should contain("Motif (facultatif)")
    requested = browser.post("/users/new", {"email" => "admin2@cabinet.fr", "role" => Cfg::FIRM_ADMIN, "locale" => "fr"})
    approval = PartiduoAdmin::Approval.filter(firm_id: firm.pk, kind: "firm_invite").first!
    requested.headers["Location"].should eq("/approvals/#{approval.pk}/confirm")
    PartiduoAdmin::User.filter(email: "admin2@cabinet.fr").exists?.should be_false
    # Un gestionnaire de dossiers reste invité aussitôt.
    browser.post("/users/new", {"email" => "gestion@cabinet.fr", "role" => Cfg::FILE_MANAGER, "locale" => "fr"})
      .headers["Location"].should eq("/users")
    PartiduoAdmin::User.filter(email: "gestion@cabinet.fr").exists?.should be_true
  end

  it "traduit les demandes de structure dans les sept langues" do
    firm, first, second = dual_firm("Cabinet Langues")
    manager = AdminSpec.user(Cfg::FILE_MANAGER, firm)
    Admins.request_role(first, firm, manager, Cfg::FIRM_ADMIN, false, "renfort").value!
    Admins.request_active(first, second, false).value!
    Mode.request_single(first, firm).value!
    solo_firm = AdminSpec.firm("Cabinet Seul Langues")
    solo = AdminSpec.user(Cfg::FIRM_ADMIN, solo_firm)
    solo_request = Admins.request_invite(solo, invite_input("langue@cabinet.fr", solo_firm)).value!
    Cfg::LOCALES.each do |locale|
      [first, second, solo].each do |user|
        user.locale = locale
        user.save!
      end
      pages = {
        "/approvals"                            => AdminSpec::Browser.new(locale, token: session_for(second)),
        "/firms/#{firm.pk}/admins"              => AdminSpec::Browser.new(locale, token: session_for(first)),
        "/firms/#{firm.pk}/approval-mode"       => AdminSpec::Browser.new(locale, token: session_for(first)),
        "/approvals/#{solo_request.pk}/confirm" => AdminSpec::Browser.new(locale, token: session_for(solo)),
      }
      pages.each do |path, browser|
        response = browser.get(path)
        response.status.should eq(200)
        response.html.should contain(%(<html lang="#{locale}">))
        PartiduoTranslations.problems(response.html).should eq([] of String)
      end
    end
  end
end

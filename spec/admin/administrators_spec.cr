# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Administrateurs multiples (D-ADM-017) : d'un dossier (comptes au profil
# administrateur dans l'instance, ajoutés et retirés par l'exécutant après
# une demande validée à une ou deux personnes) et d'un cabinet (rôle d'admin
# de cabinet). Jamais zéro administrateur, retrait de soi-même confirmé,
# journal d'audit.

private alias Cfg = PartiduoAdmin::Config
private alias Admins = PartiduoAdmin::Administrators

private def emails(dossier : PartiduoAdmin::Dossier) : Array(String)
  Admins.list(dossier).map { |row| "#{row.email}:#{row.state}" }
end

# Tâche réclamée par l'exécutant du serveur puis rendue avec `result`.
private def finish(task : PartiduoAdmin::Task, result = {} of String => JSON::Any, ok : Bool = true) : Nil
  PartiduoAdmin::Task.filter(id: task.pk).update(state: "running")
  task.reload
  PartiduoAdmin::Tasks.finish(task, ok, JSON.parse(result.to_json))
end

private def confirm_alone(user : PartiduoAdmin::User, approval : PartiduoAdmin::Approval) : PartiduoAdmin::Task
  PartiduoAdmin::Approvals.confirm_alone(user, approval, true, "yes").value!
end

private def setting
  firm = AdminSpec.firm
  server, _ = AdminSpec.server
  admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  dossier = AdminSpec.dossier(firm, server)
  Admins.declare(dossier, [dossier.admin_email.to_s])
  PartiduoAdmin::DossierAdmin.filter(dossier_id: dossier.pk).update(state: "active")
  {firm, server, admin, dossier}
end

describe "Administrateurs d'un dossier (D-ADM-017)" do
  it "déclare le premier et les autres administrateurs à la création, invite les autres une fois l'instance créée" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    payer = AdminSpec.payer(firm)
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    input = PartiduoAdmin::Fleet::DossierInput.new(slug: "multi", label: "Multi SAS", regime: "fr",
      admin_email: "Patron@Multi.fr", extra_admins: ["gerante@multi.fr", "comptable@multi.fr"],
      server_id: server.pk.as(Int64), firm_id: firm.pk.as(Int64), payer_id: payer.pk.as(Int64))
    dossier = PartiduoAdmin::Fleet.create_dossier(admin, input).value!
    emails(dossier).should eq(["patron@multi.fr:pending", "gerante@multi.fr:pending", "comptable@multi.fr:pending"])
    JSON.parse(PartiduoAdmin::AuditEntry.filter(action: "dossier.create").last!.detail.to_s)["administrators"].should eq("3")

    create = PartiduoAdmin::Task.filter(kind: "instance.create", dossier_id: dossier.pk).first!
    finish(create, {"database" => JSON::Any.new("partiduo_multi"), "version" => JSON::Any.new("0.1.50")})
    emails(dossier).first.should eq("patron@multi.fr:active")
    adds = PartiduoAdmin::Task.filter(kind: "instance.admin_add", dossier_id: dossier.pk).order("id").to_a
    adds.map(&.param("email")).should eq(["gerante@multi.fr", "comptable@multi.fr"])
    params = adds.first.params_json
    params["approval_ref"].should eq("CR-#{dossier.pk}")
    params["approval_mode"].should eq("single")
    params["approvers"].as_a.map(&.as_s).should eq([admin.email.to_s])

    # Un ajout de la création se rejoue après un échec ; pas un ajout demandé.
    finish(adds.first, ok: false)
    PartiduoAdmin::Tasks.retryable?(adds.first.reload).should be_true
    finish(adds.last, {"email" => JSON::Any.new("comptable@multi.fr"), "user_created" => JSON::Any.new(true)})
    emails(dossier).should eq(["patron@multi.fr:active", "gerante@multi.fr:pending", "comptable@multi.fr:active"])
    PartiduoAdmin::AuditEntry.filter(action: "administrators.added").count.should eq(1)
  end

  it "refuse à la création une adresse fausse ou répétée parmi les autres administrateurs" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    input = PartiduoAdmin::Fleet::DossierInput.new(slug: "doublon", label: "Doublon", regime: "fr", admin_email: "a@b.fr",
      extra_admins: ["A@b.fr", "pas-une-adresse"], server_id: server.pk.as(Int64), firm_id: firm.pk.as(Int64),
      payer_id: AdminSpec.payer(firm).pk.as(Int64))
    outcome = PartiduoAdmin::Fleet.create_dossier(AdminSpec.super_admin, input)
    outcome.errors["extra_admins"].sort.should eq(["admin.errors.administrators.duplicate", "admin.errors.email"])
    PartiduoAdmin::Dossier.filter(slug: "doublon").exists?.should be_false
  end

  it "ajoute un administrateur par une demande confirmée seule, puis par l'exécutant, et le trace" do
    _firm, _server, admin, dossier = setting
    approval = Admins.request_add(admin, dossier, "Gerante@Exemple.fr", "nouvelle gérante").value!
    approval.kind.should eq("admin_add")
    approval.mode.should eq("single")
    PartiduoAdmin::Approvals.can_confirm_alone?(admin, approval).should be_true
    task = confirm_alone(admin, approval)
    task.kind.should eq("instance.admin_add")
    task.param("email").should eq("gerante@exemple.fr")
    task.params_json["approvers"].as_a.map(&.as_s).should eq([admin.email.to_s])
    PartiduoAdmin::Tasks.retryable?(task).should be_false

    finish(task, {"email" => JSON::Any.new("gerante@exemple.fr"), "user_created" => JSON::Any.new(true)})
    emails(dossier).should eq(["#{dossier.admin_email}:active", "gerante@exemple.fr:active"])
    entry = PartiduoAdmin::AuditEntry.filter(action: "administrators.added").last!
    JSON.parse(entry.detail.to_s)["reference"].should eq(approval.reference)

    # Déjà administrateur : refusé avant toute demande.
    Admins.request_add(admin, dossier, "gerante@exemple.fr", "encore une fois").errors["email"]
      .should eq(["admin.errors.administrators.already"])
  end

  it "attend une autre personne quand la structure est réglée sur deux personnes" do
    firm, _server, admin, dossier = setting
    second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    PartiduoAdmin::ApprovalMode.set(admin, firm, true).ok?.should be_true
    approval = Admins.request_remove(admin, dossier, dossier.admin_email.to_s, "demote", "départ", false)
    # Dernier administrateur actif : refusé, même à deux.
    approval.errors["base"].should eq(["admin.errors.administrators.last"])

    approval = Admins.request_add(admin, dossier, "nouvelle@exemple.fr", "renfort de l'équipe").value!
    approval.mode.should eq("dual")
    PartiduoAdmin::Approvals.can_confirm_alone?(admin, approval).should be_false
    task = PartiduoAdmin::Approvals.approve(second, approval).value!
    task.params_json["approvers"].as_a.map(&.as_s).should eq([admin.email.to_s, second.email.to_s])
    task.params_json["approval_mode"].should eq("dual")
  end

  it "retire ou rétrograde un administrateur, jamais le dernier, et confirme le retrait de soi-même" do
    _firm, _server, admin, dossier = setting
    PartiduoAdmin::DossierAdmin.create!(dossier: dossier, email: admin.email.to_s.downcase, state: "active")
    refused = Admins.request_remove(admin, dossier, admin.email.to_s, "revoke", "je pars", false)
    refused.errors["self_confirm"].should eq(["admin.errors.administrators.self_confirm"])
    Admins.request_remove(admin, dossier, "inconnu@exemple.fr", "revoke", "personne", false).errors["email"]
      .should eq(["admin.errors.administrators.unknown"])
    Admins.request_remove(admin, dossier, admin.email.to_s, "effacer", "mode inconnu", true).errors["removal"]
      .should eq(["admin.errors.invalid"])

    approval = Admins.request_remove(admin, dossier, admin.email.to_s, "demote", "je pars", true).value!
    task = confirm_alone(admin, approval)
    task.kind.should eq("instance.admin_remove")
    task.param("removal").should eq("demote")
    finish(task, {"changed" => JSON::Any.new(true)})
    emails(dossier).should eq(["#{dossier.admin_email}:active"])
    PartiduoAdmin::AuditEntry.filter(action: "administrators.removed").count.should eq(1)
  end

  it "remplace un administrateur : ajout du nouveau puis retrait de l'ancien, premier de la liste suivi" do
    _firm, _server, admin, dossier = setting
    previous = dossier.admin_email.to_s
    approval = Admins.request_add(admin, dossier, "nouveau@exemple.fr", "changement de gérant", previous, "demote").value!
    task = confirm_alone(admin, approval)
    {task.param("replaces"), task.param("replace_removal")}.should eq({previous, "demote"})
    finish(task, {"email" => JSON::Any.new("nouveau@exemple.fr"), "removed" => JSON::Any.new(previous)})
    emails(dossier).should eq(["nouveau@exemple.fr:active"])
    dossier.reload.admin_email.should eq("nouveau@exemple.fr")
    Admins.request_add(admin, dossier, "x@exemple.fr", "remplacement", "absent@exemple.fr").errors["replaces"]
      .should eq(["admin.errors.administrators.unknown"])
  end

  it "relit la liste de l'instance : retraits et ajouts de la société repris, ajouts en attente gardés" do
    _firm, _server, admin, dossier = setting
    PartiduoAdmin::DossierAdmin.create!(dossier: dossier, email: "parti@exemple.fr", state: "active")
    PartiduoAdmin::DossierAdmin.create!(dossier: dossier, email: "attente@exemple.fr", state: "pending")
    task = Admins.refresh(admin, dossier).value!
    task.kind.should eq("instance.admins")
    finish(task, {"admins" => JSON.parse([
      {"email" => dossier.admin_email, "active" => true, "revoked" => false, "usable" => true},
      {"email" => "parti@exemple.fr", "active" => true, "revoked" => true, "usable" => true},
      {"email" => "ajoutee@exemple.fr", "active" => true, "revoked" => false, "usable" => false},
    ].to_json)})
    emails(dossier).should eq(["#{dossier.admin_email}:active", "attente@exemple.fr:pending", "ajoutee@exemple.fr:active"])
    Admins.list(dossier).first.usable.should be_true
    Admins.list(dossier).last.usable.should be_false
    JSON.parse(PartiduoAdmin::AuditEntry.filter(action: "administrators.refreshed").last!.detail.to_s)["removed"]
      .should eq("parti@exemple.fr")
  end

  it "laisse un gestionnaire relire la liste mais pas la changer" do
    firm, _server, _admin, dossier = setting
    manager = AdminSpec.user(Cfg::FILE_MANAGER, firm)
    PartiduoAdmin::Assignment.create!(user: manager, dossier: dossier)
    Admins.request_add(manager, dossier, "x@exemple.fr", "pas permis").errors["base"].should eq(["admin.errors.forbidden"])
    Admins.refresh(manager, dossier).ok?.should be_true
    browser = AdminSpec::Browser.new(token: AdminSpec.session(manager))
    page = browser.get("/dossiers/#{dossier.pk}/admins")
    page.status.should eq(200)
    page.html.should contain(dossier.admin_email.to_s)
    page.html.should_not contain(%(action="/dossiers/#{dossier.pk}/admins/remove"))
  end

  it "sert la liste, la demande d'ajout par le formulaire et le retrait, sans JavaScript" do
    _firm, _server, admin, dossier = setting
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    detail = browser.get("/dossiers/#{dossier.pk}").html
    detail.should contain(%(href="/dossiers/#{dossier.pk}/admins"))
    list = browser.get("/dossiers/#{dossier.pk}/admins")
    list.status.should eq(200)
    list.html.should contain("Dernier administrateur")

    refused = browser.post("/dossiers/#{dossier.pk}/admins", {"email" => "pas-une-adresse", "reason" => "x"})
    refused.status.should eq(422)
    refused.html.should contain(%(aria-invalid="true"))

    sent = browser.post("/dossiers/#{dossier.pk}/admins", {"email" => "ajout@exemple.fr", "reason" => "renfort de l'équipe"})
    sent.status.should eq(302)
    approval = PartiduoAdmin::Approval.filter(kind: "admin_add").last!
    sent.headers["Location"].should eq("/approvals/#{approval.pk}/confirm")
    confirm = browser.get("/approvals/#{approval.pk}/confirm").html
    confirm.should contain("Je confirme l'ajout de l'administrateur")
    confirm.should contain("ajout@exemple.fr")
  end
end

describe "Administrateurs d'un cabinet (D-ADM-017)" do
  it "liste les admins, en invite un autre, change les rôles, jamais le dernier, et trace" do
    firm = AdminSpec.firm("Cabinet Pluriel")
    first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(first))
    page = browser.get("/firms/#{firm.pk}/admins")
    page.status.should eq(200)
    page.html.should contain(first.email.to_s)
    page.html.should contain("Dernier administrateur")
    browser.get("/").html.should contain(%(href="/firms/#{firm.pk}/admins"))

    invited = browser.post("/firms/#{firm.pk}/admins", {"email" => "seconde@cabinet.fr", "first_name" => "Ada", "locale" => "fr"})
    invited.status.should eq(302)
    second = PartiduoAdmin::User.get!(email: "seconde@cabinet.fr")
    {second.role, second.firm_id}.should eq({Cfg::FIRM_ADMIN, firm.pk})
    Admins.firm_admins(firm).map(&.email).should eq([first.email, "seconde@cabinet.fr"])

    # Soi-même : confirmation exigée.
    Admins.set_role(first, firm, first, Cfg::FILE_MANAGER, false).errors["self_confirm"]
      .should eq(["admin.errors.administrators.self_confirm"])
    Admins.set_role(first, firm, second, Cfg::FILE_MANAGER, false).ok?.should be_true
    second.reload.role.should eq(Cfg::FILE_MANAGER)
    entry = PartiduoAdmin::AuditEntry.filter(action: "user.role").last!
    JSON.parse(entry.detail.to_s)["after"].should eq(Cfg::FILE_MANAGER)
    # Le dernier admin ne se rétrograde pas, ne se désactive pas.
    Admins.set_role(first, firm, first, Cfg::FILE_MANAGER, true).errors["base"].should eq(["admin.errors.administrators.last"])
    root = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.super_admin))
    disabled = root.post("/users/#{first.pk}/disable")
    disabled.status.should eq(302)
    first.reload.active.should be_true

    promoted = browser.post("/firms/#{firm.pk}/admins/#{second.pk}/promote")
    promoted.status.should eq(302)
    second.reload.role.should eq(Cfg::FIRM_ADMIN)
    # Un autre cabinet ne voit pas cette liste.
    other = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Cfg::FIRM_ADMIN, AdminSpec.firm)))
    other.get("/firms/#{firm.pk}/admins").status.should eq(403)
  end

  it "remplace un admin : le nouveau invité, l'ancien gestionnaire de dossiers" do
    firm = AdminSpec.firm("Cabinet Relève")
    first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    root = AdminSpec.super_admin
    input = PartiduoAdmin::Directory::UserInput.new(email: "releve@cabinet.fr")
    outcome = Admins.replace_firm_admin(root, firm, first, input, false)
    outcome.ok?.should be_true
    first.reload.role.should eq(Cfg::FILE_MANAGER)
    Admins.firm_admins(firm).map(&.email).should eq(["releve@cabinet.fr"])
    # Adresse déjà prise : rien n'est changé.
    taken = Admins.replace_firm_admin(root, firm, Admins.firm_admins(firm).first, input, false)
    taken.ok?.should be_false
    Admins.firm_admins(firm).size.should eq(1)
  end

  it "n'ajoute pas de second admin à un gestionnaire indépendant" do
    root = AdminSpec.super_admin
    firm = PartiduoAdmin::Directory.create_firm(root, "Martine Seule", kind: "independent").value!
    AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    outcome = Admins.invite_firm_admin(root, firm, PartiduoAdmin::Directory::UserInput.new(email: "deux@seule.fr"))
    outcome.errors["firm_id"].should eq(["admin.errors.firm.independent_single"])
    page = AdminSpec::Browser.new(token: AdminSpec.session(root)).get("/firms/#{firm.pk}/admins")
    page.html.should contain("Un gestionnaire indépendant n'a qu'une personne")
  end
end

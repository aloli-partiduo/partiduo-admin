# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Archivage et déplacement soumis à la double validation, transfert d'un
# dossier vers une autre structure (D-ADM-027) : demande au lieu du geste
# direct quand la structure est à deux personnes ; transfert demandé par le
# super-admin, accord des deux structures chacune selon son réglage,
# exécution au dernier accord avec ses conséquences (accès, donneur
# d'ordre, chiffrement jamais affaibli, sauvegarde prise aussitôt), traces
# des deux côtés ; specs d'attaque ; écrans et assistant dans les sept
# langues.

private alias Cfg = PartiduoAdmin::Config
private alias Mode = PartiduoAdmin::ApprovalMode
private alias Approvals = PartiduoAdmin::Approvals
private alias Transfers = PartiduoAdmin::Transfers
private alias Enc = PartiduoAdmin::BackupEncryption

private def duo(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User, PartiduoAdmin::User}
  firm = AdminSpec.firm(name)
  first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  Mode.set(first, firm, true).ok?.should be_true
  {firm, first, second}
end

private def solo(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User}
  firm = AdminSpec.firm(name)
  {firm, AdminSpec.user(Cfg::FIRM_ADMIN, firm)}
end

private def sql_refused(sql : String, *args) : Bool
  Marten::DB::Connection.default.open(&.exec(sql, *args))
  false
rescue
  true
end

describe "Archivage et déplacement soumis à la double validation (D-ADM-027)" do
  it "archive aussitôt à une personne, par une demande validée par un autre à deux personnes" do
    server, _ = AdminSpec.server
    single_firm, admin = solo("Cabinet Archive Seul")
    PartiduoAdmin::Fleet.lifecycle(admin, AdminSpec.dossier(single_firm, server), "archive", "fin").ok?.should be_true

    firm, first, second = duo("Cabinet Archive Duo")
    dossier = AdminSpec.dossier(firm, server)
    PartiduoAdmin::Fleet.lifecycle(first, dossier, "archive", "fin de mission").errors["base"]
      .should eq(["admin.errors.approval.needs_request"])
    PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "instance.archive").exists?.should be_false
    approval = Approvals.request_archive(first, dossier, "fin de mission").value!
    approval.kind.should eq("archive")
    # Attaques : même personne, recours du super-admin avant le délai.
    Approvals.approve(first, approval).errors["base"].should eq(["admin.errors.approval.same_person"])
    Approvals.approve(AdminSpec.super_admin, approval).errors["base"].should eq(["admin.errors.approval.recourse_wait"])
    task = Approvals.approve(second, approval).value!
    task.kind.should eq("instance.archive")
    task.params_json["approval_ref"].should eq(approval.reference)
    task.params_json["encryption"]["mode"].should eq("exploitation")
    task.params_json["reason"].should eq("fin de mission")
    PartiduoAdmin::AuditEntry.filter(action: "dossier.archive", target_id: dossier.pk).last!.detail.to_s.should contain(approval.reference.to_s)
    # Attaque : demande rejouée.
    Approvals.approve(second, approval).errors["base"].should eq(["admin.errors.approval.state"])
    PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "instance.archive").count.should eq(1)
  end

  it "recontrôle l'archivage à la décision : dossier changé entre-temps, rien n'est lancé" do
    server, _ = AdminSpec.server
    firm, first, second = duo("Cabinet Archive Cible")
    dossier = AdminSpec.dossier(firm, server)
    approval = Approvals.request_archive(first, dossier, "fin de mission").value!
    dossier.state = "archived"
    dossier.save!
    Approvals.approve(second, approval).errors["base"].should eq(["admin.errors.dossier.state"])
    PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "instance.archive").exists?.should be_false
  end

  it "déplace un dossier par une demande à deux personnes, recontrôlée, puis prépare la restauration" do
    server, _ = AdminSpec.server
    target, _ = AdminSpec.server
    firm, admin, _ = duo("Cabinet Déplacement Duo")
    dossier = AdminSpec.dossier(firm, server, state: "suspended")
    root = AdminSpec.super_admin
    PartiduoAdmin::Fleet.move(root, dossier, target.pk!.as(Int64), "nouveau serveur").errors["base"]
      .should eq(["admin.errors.approval.needs_request"])
    approval = Approvals.request_move(root, dossier, target.pk!.as(Int64), "nouveau serveur").value!
    approval.detail_text.should eq("#{server.name} → #{target.name}")
    dossier.reload.server_id.should eq(server.pk)
    Approvals.approve(AdminSpec.super_admin, approval).errors["base"].should eq(["admin.errors.approval.recourse_wait"])
    Approvals.approve(admin, approval).ok?.should be_true
    dossier.reload.server_id.should eq(target.pk)
    approval.reload.state.should eq("approved")
    PartiduoAdmin::AuditEntry.filter(action: "dossier.move", target_id: dossier.pk).last!.detail.to_s.should contain(approval.reference.to_s)
    draft = PartiduoAdmin::Wizards.draft(root, "restore")
    draft.text("target").should eq("move")
    draft.text("dossier_id").should eq(dossier.pk.to_s)

    # Attaque : cible modifiée — le dossier a déjà changé de serveur.
    other = AdminSpec.dossier(firm, server, state: "suspended")
    stale = Approvals.request_move(root, other, target.pk!.as(Int64), "nouveau serveur").value!
    other.server = target
    other.save!
    Approvals.approve(admin, stale).errors["base"].should eq(["admin.errors.approval.target_changed"])
    stale.reload.state.should eq("expired")
  end

  it "fait passer les formulaires et les assistants par une demande à deux personnes" do
    server, _ = AdminSpec.server
    firm, first, _ = duo("Cabinet Formulaires Duo")
    dossier = AdminSpec.dossier(firm, server)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(first))
    page = browser.get("/dossiers/#{dossier.pk}").html
    page.should contain("Structure à deux personnes : cette opération est une demande")
    browser.post("/dossiers/#{dossier.pk}/actions/archive", {"reason" => "fin de mission"}).headers["Location"]
      .should eq("/dossiers/#{dossier.pk}")
    PartiduoAdmin::Approval.filter(dossier_id: dossier.pk, kind: "archive").count.should eq(1)
    PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "instance.archive").exists?.should be_false

    other = AdminSpec.dossier(firm, server)
    draft = PartiduoAdmin::Wizards.draft(first, "archive")
    draft.data = {"dossier_id" => other.pk.to_s, "reason" => "cessation d'activité"}.to_json
    draft.step = 3
    draft.reached = 3
    draft.save!
    summary = browser.get("/wizards/archive?step=3").html
    summary.should contain("la validation enregistre une demande")
    summary.should_not contain("ne fait pas partie des opérations sensibles")
    browser.post("/wizards/archive", {"step" => "3", "nav" => "finish", "confirm" => "yes"}).headers["Location"].should eq("/approvals")
    PartiduoAdmin::Approval.filter(dossier_id: other.pk, kind: "archive").count.should eq(1)
  end
end

describe "Transfert d'un dossier : demande et accords (D-ADM-027)" do
  it "n'est demandé que par le super-admin, vers une autre structure et un donneur d'ordre de l'accueil" do
    server, _ = AdminSpec.server
    origin, admin = solo("Origine Demande")
    destination, _ = solo("Accueil Demande")
    dossier = AdminSpec.dossier(origin, server)
    payer = AdminSpec.payer(destination)
    root = AdminSpec.super_admin
    id = ->(model : Marten::Model) { model.pk.as(Int64) }
    Transfers.request(admin, dossier, id.call(destination), id.call(payer), "rachat du cabinet").errors["base"].should eq(["admin.errors.forbidden"])
    Transfers.request(root, dossier, id.call(origin), id.call(payer), "rachat du cabinet").errors["firm_id"].should eq(["admin.errors.transfer.same_firm"])
    Transfers.request(root, dossier, id.call(destination), id.call(dossier.payer!), "rachat du cabinet").errors["payer_id"]
      .should eq(["admin.errors.dossier.payer_scope"])
    Transfers.request(root, dossier, id.call(destination), id.call(payer), "abc").errors["reason"].should eq(["admin.errors.required"])
    approval = Transfers.request(root, dossier, id.call(destination), id.call(payer), "rachat du cabinet").value!
    approval.kind.should eq("transfer")
    {approval.dossier_id, approval.firm_id}.should eq({dossier.pk, destination.pk})
    approval.detail_text.should eq("Origine Demande → Accueil Demande")
    Transfers.request(root, dossier, id.call(destination), id.call(payer), "rachat du cabinet").errors["base"]
      .should eq(["admin.errors.approval.already_pending"])
    # Tracé des deux côtés dès la demande.
    PartiduoAdmin::AuditEntry.filter(action: "approval.request", target_id: approval.pk).map(&.firm_id.to_s).sort!
      .should eq([origin.pk.to_s, destination.pk.to_s].sort!)
  end

  it "exige l'accord des deux structures et fait le transfert au dernier, avec ses conséquences" do
    server, _ = AdminSpec.server
    origin, origin_admin = solo("Origine Accords")
    destination, destination_admin = solo("Accueil Accords")
    dossier = AdminSpec.dossier(origin, server)
    PartiduoAdmin::Administrators.declare(dossier, ["second@societe.fr"])
    manager = AdminSpec.user(Cfg::FILE_MANAGER, origin)
    PartiduoAdmin::Assignment.create!(user: manager, dossier: dossier)
    pending = Approvals.request_admin_invite(origin_admin, dossier, "gerant@demo.fr", "gérant parti").value!
    payer = AdminSpec.payer(destination)
    root = AdminSpec.super_admin
    approval = Transfers.request(root, dossier, destination.pk.as(Int64), payer.pk.as(Int64), "rachat du cabinet").value!

    # Accord sans ré-authentification forte, ou sans la case : refusé.
    Transfers.consent(origin_admin, approval, false, "yes").errors["reauth"].should eq(["admin.errors.approval.reauth"])
    Transfers.consent(origin_admin, approval, true, "").errors["confirmation"].should eq(["admin.errors.approval.confirmation"])
    Transfers.consent(origin_admin, approval, true, "yes").value.should be_false
    dossier.reload.firm_id.should eq(origin.pk)
    Transfers.consent(destination_admin, approval, true, "yes").value.should be_true

    dossier.reload
    dossier.firm_id.should eq(destination.pk)
    dossier.payer_id.should eq(payer.pk)
    approval.reload.state.should eq("approved")
    # Les gestionnaires de l'ancienne structure perdent leur accès.
    PartiduoAdmin::Assignment.filter(dossier_id: dossier.pk).exists?.should be_false
    PartiduoAdmin::Access.in_scope?(manager, dossier).should be_false
    PartiduoAdmin::Access.in_scope?(origin_admin, dossier).should be_false
    PartiduoAdmin::Access.in_scope?(destination_admin, dossier).should be_true
    # Administrateurs du dossier inchangés.
    PartiduoAdmin::Administrators.emails(dossier).should contain("second@societe.fr")
    # Demandes en attente sur le dossier : closes.
    pending.reload.state.should eq("expired")
    # Sauvegarde prise aussitôt, avec le chiffrement de l'accueil.
    PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "backup.run").count.should eq(1)
    # Tracé des deux côtés.
    entries = PartiduoAdmin::AuditEntry.filter(action: "dossier.transfer", target_id: dossier.pk).to_a
    entries.map(&.firm_id.to_s).sort!.should eq([origin.pk.to_s, destination.pk.to_s].sort!)
    detail = JSON.parse(entries.first.detail.to_s)
    detail["managers_removed"].should eq(manager.email)
    detail["consents"].as_s.should contain(origin_admin.email.to_s)
    detail["consents"].as_s.should contain(destination_admin.email.to_s)
  end

  it "fait donner deux accords distincts à une structure à deux personnes" do
    server, _ = AdminSpec.server
    origin, origin_admin = solo("Origine Deux")
    destination, first, second = duo("Accueil Deux")
    dossier = AdminSpec.dossier(origin, server)
    approval = Transfers.request(AdminSpec.super_admin, dossier, destination.pk.as(Int64),
      AdminSpec.payer(destination).pk.as(Int64), "regroupement").value!
    Transfers.consent(origin_admin, approval, true, "yes").value.should be_false
    Transfers.consent(first, approval, true, "yes").value.should be_false
    # Attaque : même personne une seconde fois.
    Transfers.consent(first, approval, true, "yes").errors["base"].should eq(["admin.errors.transfer.already_consented"])
    dossier.reload.firm_id.should eq(origin.pk)
    Transfers.consent(second, approval, true, "yes").value.should be_true
    dossier.reload.firm_id.should eq(destination.pk)
  end
end

describe "Transfert : specs d'attaque (D-ADM-027)" do
  it "n'est jamais fait sur l'accord d'une seule des deux structures, ni par le service ni par la base" do
    server, _ = AdminSpec.server
    origin, first, second = duo("Origine Seule")
    destination, _ = solo("Accueil Muet")
    dossier = AdminSpec.dossier(origin, server)
    root = AdminSpec.super_admin
    approval = Transfers.request(root, dossier, destination.pk.as(Int64), AdminSpec.payer(destination).pk.as(Int64), "rachat").value!
    Transfers.consent(first, approval, true, "yes").value.should be_false
    Transfers.consent(second, approval, true, "yes").value.should be_false
    # L'origine a tout donné : un troisième accord d'origine n'y change rien.
    third = AdminSpec.user(Cfg::FIRM_ADMIN, origin)
    Transfers.consent(third, approval, true, "yes").errors["base"].should eq(["admin.errors.transfer.side_done"])
    dossier.reload.firm_id.should eq(origin.pk)
    # Les validations ordinaires ne s'appliquent pas à un transfert.
    Approvals.approve(first, approval).errors["base"].should eq(["admin.errors.transfer.consent_only"])
    Approvals.approve(AdminSpec.super_admin, approval, AdminSpec.recourse_time).errors["base"]
      .should eq(["admin.errors.transfer.consent_only"])
    Approvals.confirm_alone(root, approval, true, "yes").errors["base"].should eq(["admin.errors.transfer.consent_only"])
    # Écriture directe : la base refuse un transfert validé sans l'accueil.
    sql_refused("UPDATE admin_approval SET state = 'approved', decided_by_id = $1, decided_at = now() WHERE id = $2",
      first.pk, approval.pk).should be_true
    approval.reload.state.should eq("pending")
    dossier.reload.firm_id.should eq(origin.pk)
  end

  it "refuse l'accord du demandeur et d'une structure étrangère, par le service et par la base" do
    server, _ = AdminSpec.server
    root = AdminSpec.super_admin
    fleet = PartiduoAdmin::Directory.create_firm(root, "Parc Transfert", kind: "fleet").value!
    destination, destination_admin = solo("Accueil Parc")
    dossier = AdminSpec.dossier(fleet, server)
    approval = Transfers.request(root, dossier, destination.pk.as(Int64), AdminSpec.payer(destination).pk.as(Int64), "cession").value!
    # Même personne : le super-admin demandeur ne donne pas l'accord du parc.
    Transfers.consent(root, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.same_person"])
    sql_refused("INSERT INTO admin_approval_consent (approval_id, firm_id, side, user_id, mode, created_at) VALUES ($1, $2, 'origin', $3, 'single', now())",
      approval.pk, fleet.pk, root.pk).should be_true
    stranger = AdminSpec.user(Cfg::FIRM_ADMIN, AdminSpec.firm("Étrangère"))
    Transfers.consent(stranger, approval, true, "yes").errors["base"].should eq(["admin.errors.forbidden"])
    sql_refused("INSERT INTO admin_approval_consent (approval_id, firm_id, side, user_id, mode, created_at) VALUES ($1, $2, 'destination', $3, 'single', now())",
      approval.pk, stranger.firm_id, stranger.pk).should be_true
    # Un autre super-admin donne l'accord du parc sans cabinet.
    Transfers.consent(AdminSpec.super_admin, approval, true, "yes").value.should be_false
    Transfers.consent(destination_admin, approval, true, "yes").value.should be_true
    dossier.reload.firm_id.should eq(destination.pk)
  end

  it "ne rejoue jamais un transfert fait, refusé ou échu" do
    server, _ = AdminSpec.server
    origin, origin_admin = solo("Origine Rejeu")
    destination, destination_admin = solo("Accueil Rejeu")
    dossier = AdminSpec.dossier(origin, server)
    root = AdminSpec.super_admin
    payer = AdminSpec.payer(destination)
    approval = Transfers.request(root, dossier, destination.pk.as(Int64), payer.pk.as(Int64), "rachat").value!
    Transfers.consent(origin_admin, approval, true, "yes").ok?.should be_true
    Transfers.consent(destination_admin, approval, true, "yes").value.should be_true
    late_admin = AdminSpec.user(Cfg::FIRM_ADMIN, destination)
    Transfers.consent(late_admin, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.state"])
    sql_refused("INSERT INTO admin_approval_consent (approval_id, firm_id, side, user_id, mode, created_at) VALUES ($1, $2, 'destination', $3, 'single', now())",
      approval.pk, destination.pk, late_admin.pk).should be_true
    PartiduoAdmin::AuditEntry.filter(action: "dossier.transfer", target_id: dossier.pk).count.should eq(2)

    back = Transfers.request(root, dossier, origin.pk.as(Int64), AdminSpec.payer(origin).pk.as(Int64), "retour").value!
    Approvals.reject(destination_admin, back).should be_true
    Transfers.consent(origin_admin, back, true, "yes").errors["base"].should eq(["admin.errors.approval.state"])
    PartiduoAdmin::AuditEntry.filter(action: "approval.reject", target_id: back.pk).count.should eq(2)

    expired = Transfers.request(root, dossier, origin.pk.as(Int64), AdminSpec.payer(origin).pk.as(Int64), "retour").value!
    Transfers.consent(origin_admin, expired, true, "yes", SPEC_NOW + Cfg::APPROVAL_TTL + 1.minute).errors["base"]
      .should eq(["admin.errors.approval.expired"])
    dossier.reload.firm_id.should eq(destination.pk)
  end

  it "clôt un transfert dont la cible a changé entre la demande et la décision" do
    server, _ = AdminSpec.server
    origin, origin_admin = solo("Origine Cible")
    destination, destination_admin = solo("Accueil Cible")
    dossier = AdminSpec.dossier(origin, server)
    approval = Transfers.request(AdminSpec.super_admin, dossier, destination.pk.as(Int64),
      AdminSpec.payer(destination).pk.as(Int64), "rachat").value!
    Transfers.consent(origin_admin, approval, true, "yes").ok?.should be_true
    # Entre-temps, le donneur d'ordre du dossier change.
    dossier.payer = AdminSpec.payer(origin)
    dossier.save!
    Transfers.consent(destination_admin, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.target_changed"])
    approval.reload.state.should eq("expired")
    dossier.reload.firm_id.should eq(origin.pk)
    PartiduoAdmin::AuditEntry.filter(action: "approval.stale", target_id: approval.pk).count.should eq(2)
    # Ou la structure d'accueil est désactivée.
    again = Transfers.request(AdminSpec.super_admin, dossier, destination.pk.as(Int64),
      AdminSpec.payer(destination).pk.as(Int64), "rachat").value!
    Transfers.consent(origin_admin, again, true, "yes").ok?.should be_true
    destination.active = false
    destination.save!
    Transfers.consent(destination_admin, again, true, "yes").errors["firm_id"].should eq(["admin.errors.required"])
    dossier.reload.firm_id.should eq(origin.pk)
  end

  it "n'affaiblit jamais le chiffrement par un transfert, et exige la clé de l'accueil pour la clé du cabinet" do
    server, _ = AdminSpec.server
    origin, origin_admin = solo("Origine Chiffre")
    destination, destination_admin = solo("Accueil Chiffre")
    dossier = AdminSpec.dossier(origin, server)
    root = AdminSpec.super_admin
    # Accueil réglé sur « aucun » : le dossier garde sa clé d'exploitation.
    Enc.set_firm_mode(root, destination, "none").errors["mode"].should eq(["admin.errors.encryption.needs_approval"])
    weaken = Enc.request_firm_weaken(destination_admin, destination, "none").value!
    Approvals.confirm_alone(destination_admin, weaken, true, "yes").ok?.should be_true
    Transfers.encryption_after(dossier, destination.reload).should eq("exploitation")
    approval = Transfers.request(root, dossier, destination.pk.as(Int64), AdminSpec.payer(destination).pk.as(Int64), "rachat").value!
    Transfers.consent(origin_admin, approval, true, "yes").ok?.should be_true
    Transfers.consent(destination_admin, approval, true, "yes").value.should be_true
    dossier.reload.backup_encryption.should eq("exploitation")
    dossier.effective_encryption.should eq("exploitation")
    PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "backup.run").first!.params_json["encryption"]["mode"].should eq("exploitation")

    # Clé du cabinet : l'accueil doit avoir déposé la sienne ; ses
    # sauvegardes suivantes sont chiffrées pour elle.
    other_origin, other_admin = solo("Origine Clé")
    Enc.deposit_key(other_admin, other_origin, AdminSpec::Keys.pair("a").public_pem).ok?.should be_true
    Enc.set_firm_mode(other_admin, other_origin, "cabinet").ok?.should be_true
    sealed = AdminSpec.dossier(other_origin.reload, server)
    keyless, keyless_admin = solo("Accueil Sans Clé")
    Transfers.request(root, sealed, keyless.pk.as(Int64), AdminSpec.payer(keyless).pk.as(Int64), "rachat").errors["firm_id"]
      .should eq(["admin.errors.transfer.no_key"])
    pair = AdminSpec::Keys.pair("b")
    Enc.deposit_key(keyless_admin, keyless, pair.public_pem).ok?.should be_true
    moved = Transfers.request(root, sealed, keyless.pk.as(Int64), AdminSpec.payer(keyless).pk.as(Int64), "rachat").value!
    Transfers.consent(other_admin, moved, true, "yes").ok?.should be_true
    Transfers.consent(keyless_admin, moved, true, "yes").value.should be_true
    sealed.reload.effective_encryption.should eq("cabinet")
    task = PartiduoAdmin::Task.filter(dossier_id: sealed.pk, kind: "backup.run").first!
    task.params_json["encryption"]["key_fingerprint"].should eq(keyless.reload.backup_key_fingerprint)
  end
end

describe "Transfert : écrans et assistant (D-ADM-027)" do
  it "mène de l'assistant à la demande, puis à l'accord de chaque structure, dans les sept langues" do
    server, _ = AdminSpec.server
    origin, origin_admin = solo("Origine Écran")
    destination, destination_admin = solo("Accueil Écran")
    dossier = AdminSpec.dossier(origin, server, slug: "transfert-ecran")
    payer = AdminSpec.payer(destination)
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    browser.get("/dossiers/#{dossier.pk}").html.should contain("/wizards/transfer?dossier=#{dossier.pk}")
    browser.get("/wizards/transfer?dossier=#{dossier.pk}").status.should eq(200)
    browser.post("/wizards/transfer", {"step" => "2", "firm_id" => destination.pk.to_s}).headers["Location"].should eq("/wizards/transfer")
    browser.post("/wizards/transfer", {"step" => "3", "payer_id" => payer.pk.to_s}).headers["Location"].should eq("/wizards/transfer")
    consequences = browser.post("/wizards/transfer", {"step" => "4", "reason" => "ab"})
    consequences.status.should eq(422)
    browser.post("/wizards/transfer", {"step" => "4", "reason" => "rachat du cabinet"}).headers["Location"].should eq("/wizards/transfer")
    summary = browser.get("/wizards/transfer?step=5").html
    summary.should contain("chaque structure donne son accord")
    browser.post("/wizards/transfer", {"step" => "5", "nav" => "finish", "confirm" => "yes"}).headers["Location"].should eq("/approvals")
    approval = PartiduoAdmin::Approval.filter(dossier_id: dossier.pk, kind: "transfer").first!

    # L'admin d'accueil voit la demande sans voir le dossier, et donne son accord.
    other = AdminSpec::Browser.new(token: AdminSpec.session(destination_admin))
    list = other.get("/approvals").html
    list.should contain("transfert vers une autre structure")
    list.should contain("/approvals/#{approval.pk}/transfer")
    list.should contain("Donner l'accord")
    other.get("/dossiers/#{dossier.pk}").status.should eq(403)
    page = other.get("/approvals/#{approval.pk}/transfer").html
    page.should contain("Origine Écran → Accueil Écran")
    page.should contain("Je donne l'accord de ma structure")
    other.post("/approvals/#{approval.pk}/transfer", {"confirm" => "yes"}).headers["Location"].should eq("/approvals/#{approval.pk}/transfer")
    # Le demandeur suit, sans pouvoir donner d'accord.
    browser.get("/approvals/#{approval.pk}/transfer").html.should contain("Votre demande attend l'accord des deux structures")
    browser.post("/approvals/#{approval.pk}/transfer", {"confirm" => "yes"}).status.should eq(422)
    # Une structure étrangère ne voit rien.
    stranger = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Cfg::FIRM_ADMIN, AdminSpec.firm)))
    stranger.get("/approvals/#{approval.pk}/transfer").status.should eq(403)

    Cfg::LOCALES.each do |locale|
      [origin_admin, destination_admin, root].each do |user|
        user.locale = locale
        user.save!
      end
      {origin_admin, destination_admin, root}.each do |user|
        response = AdminSpec::Browser.new(locale, token: AdminSpec.session(user)).get("/approvals/#{approval.pk}/transfer")
        response.status.should eq(200)
        response.html.should contain(%(<html lang="#{locale}">))
        PartiduoTranslations.problems(response.html).should eq([] of String)
      end
    end
    origin_browser = AdminSpec::Browser.new(token: AdminSpec.session(origin_admin))
    origin_browser.post("/approvals/#{approval.pk}/transfer", {"confirm" => "yes"}).status.should eq(302)
    dossier.reload.firm_id.should eq(destination.pk)
  end
end

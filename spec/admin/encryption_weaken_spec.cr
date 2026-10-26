# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Affaiblissement du chiffrement des sauvegardes soumis à validation
# (D-ADM-025) : ordre de protection des modes, demande au lieu du geste
# direct (réglage du cabinet, chiffrement effectif d'un dossier), décision
# par la structure, rotation de clé et renforcement immédiats, specs
# d'attaque (enchaînements, cible modifiée, même personne, rejeu, recours
# avant le délai).

private alias Cfg = PartiduoAdmin::Config
private alias Enc = PartiduoAdmin::BackupEncryption
private alias Mode = PartiduoAdmin::ApprovalMode
private alias Approvals = PartiduoAdmin::Approvals

# Cabinet dont l'admin a déposé une clé : {cabinet, admin}.
private def keyed(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User}
  firm = AdminSpec.firm(name)
  admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  Enc.deposit_key(admin, firm, AdminSpec::Keys.pair("a").public_pem).ok?.should be_true
  {firm.reload, admin}
end

describe "Ordre de protection des modes de chiffrement (D-ADM-025)" do
  it "range clé du cabinet, clé d'exploitation, clé du serveur (retirée), aucun" do
    order = %w[cabinet exploitation server none]
    order.each_cons_pair { |stronger, weaker| Enc.weaker?(stronger, weaker).should be_true }
    order.each_cons_pair { |stronger, weaker| Enc.weaker?(weaker, stronger).should be_false }
    Enc.weaker?("cabinet", "none").should be_true
    Enc.weaker?("exploitation", "exploitation").should be_false
    Enc::MODES.each { |mode| Enc::STRENGTH.has_key?(mode).should be_true }
  end
end

describe "Affaiblissement du chiffrement soumis à validation (D-ADM-025)" do
  it "refuse le geste direct, passe par une demande confirmée seule, et laisse la rotation et le renforcement immédiats" do
    firm, admin = keyed("Cabinet Chiffre Seul")
    Enc.set_firm_mode(admin, firm, "cabinet").ok?.should be_true
    Enc.set_firm_mode(admin, firm, "exploitation").errors["mode"].should eq(["admin.errors.encryption.needs_approval"])
    firm.reload.backup_encryption.should eq("cabinet")
    # Rotation de la clé : immédiate, sans demande.
    Enc.deposit_key(admin, firm, AdminSpec::Keys.pair("b").public_pem).ok?.should be_true
    PartiduoAdmin::Approval.filter(firm_id: firm.pk).exists?.should be_false

    approval = Enc.request_firm_weaken(admin, firm, "exploitation", "clé perdue").value!
    approval.kind.should eq("backup_weaken")
    I18n.with_locale("fr") { approval.detail_text }.should eq("Clé du cabinet → Clé d'exploitation")
    Approvals.confirm_alone(admin, approval, false, "yes").errors["reauth"].should eq(["admin.errors.approval.reauth"])
    Approvals.confirm_alone(admin, approval, true, "yes").ok?.should be_true
    firm.reload.backup_encryption.should eq("exploitation")
    entry = PartiduoAdmin::AuditEntry.filter(action: "backup_encryption.firm").last!
    JSON.parse(entry.detail.to_s)["approval"].should eq(approval.reference)
    # Renforcement : immédiat.
    Enc.set_firm_mode(admin, firm, "cabinet").ok?.should be_true
    # Structure sans équipe : rien à protéger, comme D-ADM-023.
    empty = AdminSpec.firm("Cabinet Chiffre Vide")
    Enc.set_firm_mode(AdminSpec.super_admin, empty, "none").ok?.should be_true
  end

  it "fait valider par l'autre admin à deux personnes, jamais par le demandeur, et réserve au cabinet la sortie de sa clé" do
    firm, first = keyed("Cabinet Chiffre Duo")
    second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    Mode.set(first, firm, true).ok?.should be_true
    Enc.set_firm_mode(first, firm, "cabinet").ok?.should be_true
    approval = Enc.request_firm_weaken(first, firm, "none", "plus de clé").value!
    # Attaque : même personne, par le service et par la base.
    Approvals.confirm_alone(first, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.dual_required"])
    Approvals.approve(first, approval).errors["base"].should eq(["admin.errors.approval.same_person"])
    # Le super-admin ne quitte jamais la clé d'un cabinet, même en dernier recours (D-CHF-008).
    root = AdminSpec.super_admin
    Approvals.approve(root, approval, AdminSpec.recourse_time).errors["base"].should eq(["admin.errors.forbidden"])
    firm.reload.backup_encryption.should eq("cabinet")
    Approvals.approve(second, approval).ok?.should be_true
    firm.reload.backup_encryption.should eq("none")
    # Attaque : demande rejouée.
    Approvals.approve(second, approval).errors["base"].should eq(["admin.errors.approval.state"])
  end

  it "laisse le super-admin demander un affaiblissement, jamais le confirmer seul, et ne le valider qu'en dernier recours" do
    firm = AdminSpec.firm("Cabinet Chiffre Exploitant")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    root = AdminSpec.super_admin
    Enc.set_firm_mode(root, firm, "none").errors["mode"].should eq(["admin.errors.encryption.needs_approval"])
    approval = Enc.request_firm_weaken(root, firm, "none", "migration").value!
    Approvals.can_confirm_alone?(root, approval).should be_false
    Approvals.confirm_alone(root, approval, true, "yes").errors["base"].should eq(["admin.errors.approval.needs_admin"])
    # Attaque : recours d'un autre super-admin avant le délai.
    other = AdminSpec.super_admin
    Approvals.approve(other, approval).errors["base"].should eq(["admin.errors.approval.recourse_wait"])
    firm.reload.backup_encryption.should eq("exploitation")
    # L'admin du cabinet décide (structure à une personne : il valide la demande d'un autre).
    Approvals.approve(admin, approval).ok?.should be_true
    firm.reload.backup_encryption.should eq("none")
  end

  it "compte le chiffrement effectif d'un dossier : quitter une surcharge forte se demande aussi" do
    firm, admin = keyed("Cabinet Chiffre Dossier")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    Enc.set_dossier_mode(admin, dossier, "cabinet").ok?.should be_true
    dossier.reload.effective_encryption.should eq("cabinet")
    # Retour au réglage du cabinet (clé d'exploitation) : affaiblissement.
    Enc.set_dossier_mode(admin, dossier, "").errors["mode"].should eq(["admin.errors.encryption.needs_approval"])
    Enc.set_dossier_mode(admin, dossier, "none").errors["mode"].should eq(["admin.errors.encryption.needs_approval"])
    approval = Enc.request_dossier_weaken(admin, dossier, "", "retour au réglage").value!
    I18n.with_locale("fr") { approval.detail_text }.should eq("Clé du cabinet → Clé d'exploitation · #{dossier.slug}")
    Approvals.confirm_alone(admin, approval, true, "yes").ok?.should be_true
    dossier.reload.backup_encryption.should eq("")
    dossier.effective_encryption.should eq("exploitation")
    PartiduoAdmin::AuditEntry.filter(action: "backup_encryption.dossier").last!.detail.to_s.should contain(approval.reference.to_s)
  end
end

describe "Affaiblissement : specs d'attaque (D-ADM-025)" do
  it "ne se laisse pas contourner par un enchaînement de changements" do
    firm, admin = keyed("Cabinet Chaîne")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    Enc.set_firm_mode(admin, firm, "cabinet").ok?.should be_true
    # 1. Surcharge du dossier égale au réglage (aucun affaiblissement), puis
    #    affaiblissement du cabinet : le dossier garde sa surcharge, et la
    #    quitter reste un affaiblissement soumis à validation.
    Enc.set_dossier_mode(admin, dossier, "cabinet").ok?.should be_true
    weaken = Enc.request_firm_weaken(admin, firm, "none").value!
    Approvals.confirm_alone(admin, weaken, true, "yes").ok?.should be_true
    dossier.reload.effective_encryption.should eq("cabinet")
    Enc.set_dossier_mode(admin, dossier, "").errors["mode"].should eq(["admin.errors.encryption.needs_approval"])
    Enc.set_dossier_mode(admin, dossier, "exploitation").errors["mode"].should eq(["admin.errors.encryption.needs_approval"])
    # 2. Étape intermédiaire « plus forte » : aucune suite de gestes directs
    #    ne fait baisser le chiffrement effectif (ordre total).
    Enc.set_firm_mode(admin, firm, "exploitation").ok?.should be_true
    Enc.set_firm_mode(admin, firm, "cabinet").ok?.should be_true
    Enc.set_firm_mode(admin, firm, "none").errors["mode"].should eq(["admin.errors.encryption.needs_approval"])
    dossier.reload.effective_encryption.should eq("cabinet")
    # 3. Une seule demande en attente par cible.
    Enc.request_firm_weaken(admin, firm, "exploitation").ok?.should be_true
    Enc.request_firm_weaken(admin, firm, "none").errors["base"].should eq(["admin.errors.approval.already_pending"])
  end

  it "clôt une demande dont la cible a changé entre la demande et la décision" do
    firm, first = keyed("Cabinet Chiffre Cible")
    second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    Mode.set(first, firm, true).ok?.should be_true
    # Demande « clé d'exploitation → aucun » ; entre-temps le cabinet passe
    # à sa clé : valider l'ancienne demande ferait tomber la clé du cabinet.
    approval = Enc.request_firm_weaken(first, firm, "none").value!
    Enc.set_firm_mode(second, firm, "cabinet").ok?.should be_true
    Approvals.approve(second, approval).errors["base"].should eq(["admin.errors.approval.target_changed"])
    firm.reload.backup_encryption.should eq("cabinet")
    approval.reload.state.should eq("expired")
    # Dossier : le réglage du cabinet dont il hérite a changé depuis.
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    Enc.set_dossier_mode(first, dossier, "cabinet").ok?.should be_true
    weaken = Enc.request_firm_weaken(first, firm, "exploitation").value!
    Approvals.approve(second, weaken).ok?.should be_true
    back = Enc.request_dossier_weaken(first, dossier, "", "réglage du cabinet").value!
    back.param("to").should eq("exploitation")
    rogue = Enc.request_firm_weaken(second, firm, "none").value!
    Approvals.approve(first, rogue).ok?.should be_true
    Approvals.approve(second, back).errors["base"].should eq(["admin.errors.approval.target_changed"])
    dossier.reload.effective_encryption.should eq("cabinet")
  end
end

describe "Affaiblissement : écrans (D-ADM-025)" do
  it "mène du réglage à la confirmation seule, et montre les demandes en attente" do
    firm = AdminSpec.firm("Cabinet Chiffre Écran")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    page = browser.get("/firms/#{firm.pk}/backups").html
    page.should contain("Ordre de protection")
    page.should contain("Motif (facultatif)")
    requested = browser.post("/firms/#{firm.pk}/backups", {"mode" => "none", "reason" => "essai"})
    approval = PartiduoAdmin::Approval.filter(firm_id: firm.pk, kind: "backup_weaken").first!
    requested.headers["Location"].should eq("/approvals/#{approval.pk}/confirm")
    firm.reload.backup_encryption.should eq("exploitation")
    confirm = browser.get("/approvals/#{approval.pk}/confirm").html
    confirm.should contain("Clé d'exploitation → Aucun")
    browser.get("/firms/#{firm.pk}/backups").html.should contain("Demandes d'affaiblissement en attente")
    browser.get("/approvals").html.should contain("affaiblissement du chiffrement des sauvegardes")
    # Fiche du dossier : même règle pour son chiffrement effectif.
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    browser.post("/dossiers/#{dossier.pk}/encryption", {"mode" => "none", "reason" => "essai"}).status.should eq(302)
    PartiduoAdmin::Approval.filter(firm_id: firm.pk, kind: "backup_weaken").count.should eq(2)
    dossier.reload.effective_encryption.should eq("exploitation")
  end
end

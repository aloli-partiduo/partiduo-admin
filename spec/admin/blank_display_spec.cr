# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Une chaîne vide est vraie dans un `{% if %}` de Marten : un motif vide
# s'affichait vide au lieu de « — », un champ facultatif vide laissait son
# séparateur, l'étape en cours d'un assistant devenait un lien vide.
# Corrigé à la source : méthodes `…_text` des modèles (`presence`), valeurs
# vides passées comme `nil` aux gabarits, lien d'étape `nil`.

private alias Cfg = PartiduoAdmin::Config
private alias Mode = PartiduoAdmin::ApprovalMode
private alias Admins = PartiduoAdmin::Administrators

private def dual_cabinet(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User, PartiduoAdmin::User}
  firm = AdminSpec.firm(name)
  first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  Mode.set(first, firm, true).ok?.should be_true
  {firm, first, second}
end

private def browser(user : PartiduoAdmin::User) : AdminSpec::Browser
  AdminSpec::Browser.new(token: AdminSpec.session(user))
end

describe "Champs facultatifs vides affichés comme absents" do
  it "rend le motif vide comme absent, et le motif rempli tel quel" do
    approval = PartiduoAdmin::Approval.new(reason: "")
    approval.reason_text.should be_nil
    approval.reason = "   "
    approval.reason_text.should be_nil
    approval.reason = " départ "
    approval.reason_text.should eq("départ")
  end

  it "affiche « — » pour un motif vide dans « Opérations sensibles » et sur la fiche de la structure" do
    firm, first, second = dual_cabinet("Cabinet Motif Vide")
    approval = Admins.request_active(first, second, false).value!
    approval.reason.to_s.should eq("")
    page = browser(second).get("/approvals").html
    page.should contain(%(<td class="pd-mono">#{approval.reference}</td>))
    page.should contain(%(<td><span class="pd-muted">—</span></td>))
    page.should_not contain("<td></td>")

    root = AdminSpec.super_admin
    Admins.request_active(first, AdminSpec.user(Cfg::FIRM_ADMIN, firm), false, "motif présent").ok?.should be_true
    PartiduoAdmin::Firms.request_active(root, firm, false, "").ok?.should be_true
    settings = browser(root).get("/firms/#{firm.pk}/settings").html
    settings.should_not contain(" ·  · ")
    browser(second).get("/approvals").html.should contain("motif présent")
  end

  it "affiche « — » pour un motif vide sur la page de confirmation" do
    firm = AdminSpec.firm("Cabinet Motif Confirmation")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    other = AdminSpec.user(Cfg::FILE_MANAGER, firm)
    approval = Admins.request_role(admin, firm, other, Cfg::FIRM_ADMIN, false).value!
    page = browser(admin).get("/approvals/#{approval.pk}/confirm").html
    page.should contain(%(Motif</dt><dd><span class="pd-muted">—</span></dd>))
  end

  it "n'affiche ni séparateur ni valeur vide pour les champs facultatifs des listes" do
    root = AdminSpec.super_admin
    firm = AdminSpec.firm("Cabinet Sans Adresse")
    firm.email.to_s.should eq("")
    firm.email_text.should be_nil
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    dossier.extensions_text.should be_nil
    root.firm_label.should be_nil

    session = browser(root)
    session.get("/firms").html.should_not contain(%(<br><span class="pd-muted"></span>))
    session.get("/dossiers").html.should_not contain(" + </td>")
    session.get("/account").html.should_not contain(" — </dd>")
    # Étape en cours d'un assistant : pas un lien vide.
    session.get("/wizards/server").html.should_not contain(%(href=""))
  end
end

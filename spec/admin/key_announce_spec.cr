# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Annonce de la nouvelle empreinte de la clé du cabinet (D-ADM-029, risque
# B-CRA-001 : un admin qui déposerait sa propre clé). Le dépôt reste
# immédiat ; les *autres* admins actifs du cabinet reçoivent un courriel
# dans leur langue (auteur, heure, ancienne et nouvelle empreinte, marche à
# suivre), jamais l'auteur. Aucun envoi réel : les courriels restent dans la
# file capturée de Marten.

private alias Cfg = PartiduoAdmin::Config
private alias Enc = PartiduoAdmin::BackupEncryption

private def display(fingerprint : String) : String
  PartiduoAdmin::BackupCrypto.display_fingerprint(fingerprint)
end

private def recipients(mails) : Array(String)
  mails.flat_map(&.to.map(&.address)).sort!
end

describe "Annonce de la nouvelle empreinte de la clé du cabinet (D-ADM-029)" do
  it "prévient les autres admins actifs, jamais l'auteur, et l'inscrit au journal d'audit" do
    firm = AdminSpec.firm("Cabinet Empreinte")
    author = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    other = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    other.locale = "de"
    other.save!
    gone = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    gone.active = false
    gone.save!
    manager = AdminSpec.user(Cfg::FILE_MANAGER, firm)
    stranger = AdminSpec.user(Cfg::FIRM_ADMIN, AdminSpec.firm("Cabinet Voisin"))
    root = AdminSpec.super_admin

    # Premier dépôt : pas d'ancienne empreinte.
    before = Marten::Spec.delivered_emails.size
    Enc.deposit_key(author, firm, AdminSpec::Keys.pair("a").public_pem).ok?.should be_true
    first = firm.reload.backup_key_fingerprint.to_s
    sent = Marten::Spec.delivered_emails[before..]
    recipients(sent).should eq([other.email.to_s])
    german = sent.first
    german.subject.to_s.should contain("Neuer Sicherungsschlüssel")
    german.text_body.to_s.should contain("keiner (erster hinterlegter Schlüssel)")
    german.text_body.to_s.should contain(display(first))

    # Rotation : ancienne et nouvelle empreinte, auteur, heure, recours.
    middle = Marten::Spec.delivered_emails.size
    Enc.deposit_key(author, firm, AdminSpec::Keys.pair("b").public_pem).ok?.should be_true
    second = firm.reload.backup_key_fingerprint.to_s
    second.should_not eq(first)
    rotation = Marten::Spec.delivered_emails[middle..]
    all = recipients(rotation)
    all.should eq([other.email.to_s])
    [author, gone, manager, stranger, root].each { |user| all.should_not contain(user.email.to_s) }
    body = rotation.first.text_body.to_s
    body.should contain("Bisheriger Fingerabdruck: #{display(first)}")
    body.should contain("Neuer Fingerabdruck: #{display(second)}")
    body.should contain(author.email.to_s)
    body.should contain(root.email.to_s)
    body.should contain(SPEC_NOW.to_s("%Y-%m-%d %H:%M UTC"))
    body.should contain("/firms/#{firm.pk}/backups")

    entry = PartiduoAdmin::AuditEntry.filter(action: "backup_key.deposit", target_id: firm.pk).order("-id").first!
    detail = JSON.parse(entry.detail.to_s)
    detail["previous"].should eq(first)
    detail["fingerprint"].should eq(second)
    detail["notified"].should eq(other.email.to_s)
  end

  it "écrit en français par défaut, et ne prévient personne quand la clé ne change pas" do
    firm = AdminSpec.firm("Cabinet Empreinte Française")
    author = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    other = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    Enc.deposit_key(author, firm, AdminSpec::Keys.pair("a").public_pem).ok?.should be_true
    middle = Marten::Spec.delivered_emails.size
    Enc.deposit_key(other, firm, AdminSpec::Keys.pair("b").public_pem).ok?.should be_true
    sent = Marten::Spec.delivered_emails[middle..]
    recipients(sent).should eq([author.email.to_s])
    sent.first.subject.to_s.should eq("[Partiduo] Nouvelle clé de sauvegarde du cabinet Cabinet Empreinte Française")
    sent.first.text_body.to_s.should contain("Si ce changement n'est pas légitime, contactez son auteur (#{other.email})")

    # Même clé redéposée : rien n'a changé, rien à annoncer.
    again = Marten::Spec.delivered_emails.size
    Enc.deposit_key(other, firm, AdminSpec::Keys.pair("b").public_pem).ok?.should be_true
    Marten::Spec.delivered_emails.size.should eq(again)
  end

  it "garde le dépôt quand l'envoi échoue, et consigne l'échec" do
    firm = AdminSpec.firm("Cabinet Empreinte Échec")
    author = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    other = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    previous = Marten.settings.emailing.backend
    begin
      Marten.settings.emailing.backend = PartiduoAdmin::MailBackend::Missing.new
      Enc.deposit_key(author, firm, AdminSpec::Keys.pair("a").public_pem).ok?.should be_true
    ensure
      Marten.settings.emailing.backend = previous
    end
    firm.reload.backup_key_fingerprint.to_s.should_not be_empty
    entry = PartiduoAdmin::AuditEntry.filter(action: "backup_key.deposit", target_id: firm.pk).first!
    JSON.parse(entry.detail.to_s)["notice_failed"].should eq(other.email.to_s)
  end

  it "le dit sur l'écran du dépôt" do
    firm = AdminSpec.firm("Cabinet Empreinte Écran")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    browser.get("/firms/#{firm.pk}/backups").html.should contain("reçoivent par courriel l'ancienne et la nouvelle empreinte")
  end
end

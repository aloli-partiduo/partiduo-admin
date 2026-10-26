# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Adresse de support unique dans les courriels aux admins des structures
# (D-ADM-031) : `PARTIDUO_ADMIN_SUPPORT_EMAIL`, à défaut l'adresse
# d'expédition ; jamais les destinataires des alertes, jamais l'adresse
# d'un super-admin. Aucun envoi réel : les courriels restent dans la file
# capturée de Marten.

private alias Cfg = PartiduoAdmin::Config
private alias Mailer = PartiduoAdmin::Mailer
private alias Admins = PartiduoAdmin::Administrators
private alias Enc = PartiduoAdmin::BackupEncryption

# Variables d'environnement posées le temps d'un bloc, puis rétablies.
private def with_env(values : Hash(String, String?), &)
  previous = values.keys.to_h { |name| {name, ENV[name]?} }
  values.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
  yield
ensure
  previous.try &.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
end

# Les trois avis qui donnent un contact : demande retenue (D-ADM-028),
# dernier recours (D-ADM-024), nouvelle clé du cabinet (D-ADM-029).
private def notice_bodies(name : String) : {Array(String), Array(PartiduoAdmin::User)}
  firm = AdminSpec.firm(name)
  first = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  second = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
  root = AdminSpec.super_admin
  other_root = AdminSpec.super_admin
  approval = Admins.request_active(root, second, false, "compte compromis").value!
  held = Mailer.held_text(approval, "fr")[1]
  recourse = Mailer.recourse_text(approval, other_root, "fr")[1]
  change = Mailer::KeyChange.new(firm, first, "", "a" * 64, SPEC_NOW)
  key = Mailer.backup_key_text(change, "fr")[1]
  {[held, recourse, key], [root, other_root]}
end

describe "Adresse de support des courriels de la console (D-ADM-031)" do
  it "donne l'adresse de support réglée, jamais celle d'un super-admin" do
    with_env({"PARTIDUO_ADMIN_SUPPORT_EMAIL" => " support@exploitant.test ",
              "PARTIDUO_ADMIN_MAIL_FROM"     => "notifications@exploitant.test",
              "PARTIDUO_ADMIN_ALERTS_TO"     => "astreinte@exploitant.test"}) do
      Cfg.support_email.should eq("support@exploitant.test")
      bodies, supers = notice_bodies("Cabinet Support Réglé")
      bodies.each do |body|
        body.should contain("support@exploitant.test")
        body.should_not contain("notifications@exploitant.test")
        body.should_not contain("astreinte@exploitant.test")
        supers.each { |user| body.should_not contain(user.email.to_s) }
      end
      bodies[0].should contain("Pour toute question, écrivez au support Partiduo : support@exploitant.test")
      bodies[2].should contain("et le support Partiduo (support@exploitant.test)")
    end
  end

  it "se replie sur l'adresse d'expédition, jamais sur les destinataires des alertes" do
    with_env({"PARTIDUO_ADMIN_SUPPORT_EMAIL" => "  ",
              "PARTIDUO_ADMIN_MAIL_FROM"     => "notifications@exploitant.test",
              "PARTIDUO_ADMIN_ALERTS_TO"     => "astreinte@exploitant.test"}) do
      Cfg.support_email.should eq("notifications@exploitant.test")
      bodies, supers = notice_bodies("Cabinet Support Repli")
      bodies.each do |body|
        body.should contain("notifications@exploitant.test")
        body.should_not contain("astreinte@exploitant.test")
        supers.each { |user| body.should_not contain(user.email.to_s) }
      end
    end
    with_env({"PARTIDUO_ADMIN_SUPPORT_EMAIL" => nil, "PARTIDUO_ADMIN_MAIL_FROM" => nil}) do
      Cfg.support_email.should eq("no-reply@#{Cfg.domain}")
    end
  end

  it "ne cite aucun super-admin dans les courriels envoyés, dans chaque langue" do
    with_env({"PARTIDUO_ADMIN_SUPPORT_EMAIL" => "support@exploitant.test"}) do
      firm = AdminSpec.firm("Cabinet Support Envoi")
      author = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
      readers = Cfg::LOCALES.map do |locale|
        reader = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
        reader.locale = locale
        reader.save!
        reader
      end
      root = AdminSpec.super_admin
      before = Marten::Spec.delivered_emails.size
      Admins.request_active(root, readers.first, false, "départ").ok?.should be_true
      Enc.deposit_key(author, firm, AdminSpec::Keys.pair("a").public_pem).ok?.should be_true
      sent = Marten::Spec.delivered_emails[before..]
      sent.size.should eq(readers.size * 2 + 1)
      sent.each do |mail|
        mail.text_body.to_s.should contain("support@exploitant.test")
        mail.text_body.to_s.should_not contain(root.email.to_s)
      end
    end
  end
end

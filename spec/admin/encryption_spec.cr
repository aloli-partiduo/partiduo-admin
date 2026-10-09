# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Chiffrement des sauvegardes réglé dans l'administration (D-CHF-001 à
# D-CHF-024) : réglage du cabinet et du dossier (clé d'exploitation par
# défaut), dépôt de la clé publique du cabinet, paramètres des tâches,
# sauvegardes enregistrées avec leur capsule et leur manifeste signé, clé
# de sauvegarde contrôlée puis remise une seule fois, clés de signature des
# serveurs, écrans et journal d'audit.

private alias Crypto = PartiduoAdmin::BackupCrypto
private alias Config = PartiduoAdmin::Config

# Clé d'exploitation (destinataire) et clé de signature d'un serveur, une
# fois par exécution.
private OPERATOR = begin
  directory = File.join(Dir.tempdir, "partiduo-chf-admin-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(directory)
  path = File.join(directory, "exploitation.age")
  Crypto.run!("age-keygen", ["-pq", "-o", path])
  signing = File.join(directory, "backup-signing.key")
  Crypto::Signature.generate(signing, "srv")
  {String.new(Crypto.run!("age-keygen", ["-y", path])).strip, Crypto::Signature.public_line(signing)}
end

private def api(path : String, token : String, body = {} of String => String) : JSON::Any
  headers = {"Content-Type" => "application/json", "Host" => "127.0.0.1", "Authorization" => "Bearer #{token}"}
  JSON.parse(Marten::Spec::Client.new.post(path, data: body.to_json, content_type: "application/json", headers: headers).content)
end

private def audits(action : String) : Array(PartiduoAdmin::AuditEntry)
  PartiduoAdmin::AuditEntry.filter(action: action).order("id").to_a
end

# Cabinet avec clé déposée par son admin : {cabinet, admin, clé publique}.
private def keyed_firm(name : String) : {PartiduoAdmin::Firm, PartiduoAdmin::User, Crypto::PublicKey}
  firm = AdminSpec.firm(name)
  admin = AdminSpec.user(Config::FIRM_ADMIN, firm)
  pair = AdminSpec::Keys.pair("a")
  PartiduoAdmin::BackupEncryption.deposit_key(admin, firm, pair.public_pem).ok?.should be_true
  {firm.reload, admin, Crypto::PublicKey.new(pair.public_pem)}
end

# Sauvegarde chiffrée telle que l'exécutant la rendrait : pour les clés
# d'exploitation, ou pour la clé du cabinet si `key` est donnée. Rend la
# sauvegarde enregistrée et sa clé de sauvegarde.
private def sealed_backup(dossier : PartiduoAdmin::Dossier, key : Crypto::PublicKey? = nil) : {PartiduoAdmin::Backup, String}
  backup_key = Crypto.keygen
  capsule = key ? Crypto.capsule_for_cabinet(backup_key.identity, key) : Crypto.capsule_for(backup_key.identity, [OPERATOR[0]])
  server = dossier.server!.name.to_s
  stem = "#{server}/#{dossier.slug}/backup-20260927T100000Z"
  data = JSON.parse({"path" => "#{stem}.dump.age", "media_path" => "#{stem}.media.tar.gz.age",
                     "sha256" => "a" * 64, "media_sha256" => "b" * 64, "size_bytes" => 10, "server" => server,
                     "taken_at" => (SPEC_NOW - 1.day).to_rfc3339,
                     "encryption" => {"mode" => key ? "cabinet" : "exploitation", "recipient" => backup_key.recipient,
                                      "key_fingerprint" => key.try(&.fingerprint) || "", "capsule" => Base64.strict_encode(capsule),
                                      "capsule_keys" => key ? [] of String : [Crypto.recipient_fingerprint(OPERATOR[0])]},
                     "manifest" => "partiduo-backup/2\nserver #{server}\n", "signature" => "-----BEGIN SSH SIGNATURE-----\n",
                     "signing_key" => OPERATOR[1]}.to_json)
  task = PartiduoAdmin::Task.create!(kind: "backup.run", server: dossier.server!, dossier: dossier, params: %({"kind":"manual"}))
  {PartiduoAdmin::Tasks::Effects.record_backup(task, dossier, "manual", data, SPEC_NOW), backup_key.identity}
end

describe "Chiffrement des sauvegardes : réglages (D-CHF-001, D-CHF-008, D-CHF-015)" do
  it "chiffre par défaut pour les clés d'exploitation, et le dossier peut surcharger le cabinet" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    firm.backup_encryption.should eq("exploitation")
    dossier.effective_encryption.should eq("exploitation")
    task = PartiduoAdmin::Fleet.backup_now(nil, dossier).value!
    task.params_json["encryption"].as_h.should eq({"mode" => JSON::Any.new("exploitation")})

    admin = AdminSpec.user(Config::FIRM_ADMIN, firm)
    PartiduoAdmin::BackupEncryption.set_dossier_mode(admin, dossier, "none").ok?.should be_true
    dossier.reload.effective_encryption.should eq("none")
    PartiduoAdmin::Fleet.backup_now(nil, dossier, "scheduled").value!.params_json["encryption"]["mode"].should eq("none")
    audits("backup_encryption.dossier").last.detail.to_s.should contain(%("to":"none"))
    PartiduoAdmin::BackupEncryption.set_dossier_mode(admin, dossier, "").ok?.should be_true
    dossier.reload.effective_encryption.should eq("exploitation")
    # Le mode « clé du serveur » est retiré (D-CHF-021).
    PartiduoAdmin::BackupEncryption.set_dossier_mode(admin, dossier, "server").errors["mode"].should eq(["admin.errors.invalid"])
  end

  it "exige une clé déposée pour « clé du cabinet » et la transmet avec son empreinte" do
    firm = AdminSpec.firm
    admin = AdminSpec.user(Config::FIRM_ADMIN, firm)
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    refused = PartiduoAdmin::BackupEncryption.set_firm_mode(admin, firm, "cabinet")
    refused.errors["mode"].should eq(["admin.errors.encryption.no_key"])
    PartiduoAdmin::BackupEncryption.set_dossier_mode(admin, dossier, "cabinet").ok?.should be_false

    pair = AdminSpec::Keys.pair("a")
    PartiduoAdmin::BackupEncryption.deposit_key(admin, firm, "pas une clé").errors["public_key"]
      .should eq(["admin.errors.encryption.public_key"])
    PartiduoAdmin::BackupEncryption.deposit_key(admin, firm, AdminSpec::Keys.pair("petite", 2048).public_pem).ok?.should be_false
    PartiduoAdmin::BackupEncryption.deposit_key(admin, firm, pair.public_pem).ok?.should be_true
    fingerprint = Crypto::PublicKey.new(pair.public_pem).fingerprint
    firm.reload.backup_key_fingerprint.should eq(fingerprint)
    deposit = audits("backup_key.deposit").last
    deposit.actor_label.should eq(admin.email)
    deposit.detail.to_s.should contain(fingerprint)

    PartiduoAdmin::BackupEncryption.set_firm_mode(admin, firm, "cabinet").ok?.should be_true
    audits("backup_encryption.firm").last.detail.to_s.should contain(%("to":"cabinet"))
    params = PartiduoAdmin::Fleet.backup_now(nil, dossier.reload).value!.params_json["encryption"]
    params["mode"].should eq("cabinet")
    params["key_fingerprint"].should eq(fingerprint)
    Crypto::PublicKey.new(params["public_key"].as_s).fingerprint.should eq(fingerprint)
    # Archivage : sauvegarde chiffrée de même.
    PartiduoAdmin::Fleet.lifecycle(admin, dossier, "archive", "fin").value!.params_json["encryption"]["mode"].should eq("cabinet")
  end

  it "réserve le dépôt de la clé et la sortie du mode « clé du cabinet » à l'admin du cabinet" do
    firm, admin, _ = keyed_firm("Clé réservée")
    root = AdminSpec.super_admin
    other = AdminSpec.user(Config::FIRM_ADMIN, AdminSpec.firm)
    manager = AdminSpec.user(Config::FILE_MANAGER, firm)
    PartiduoAdmin::BackupEncryption.deposit_key(root, firm, AdminSpec::Keys.pair("b").public_pem).errors.has_key?("base").should be_true
    PartiduoAdmin::BackupEncryption.set_firm_mode(other, firm, "none").errors.has_key?("base").should be_true
    PartiduoAdmin::BackupEncryption.set_firm_mode(manager, firm, "none").errors.has_key?("base").should be_true

    PartiduoAdmin::BackupEncryption.set_firm_mode(root, firm, "cabinet").ok?.should be_true
    # Le super-admin (l'exploitant) ne rend pas lisibles par lui les sauvegardes suivantes.
    PartiduoAdmin::BackupEncryption.set_firm_mode(root, firm, "exploitation").errors["mode"]
      .should eq(["admin.errors.encryption.leave_cabinet"])
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    PartiduoAdmin::BackupEncryption.set_dossier_mode(root, dossier, "none").errors["mode"]
      .should eq(["admin.errors.encryption.leave_cabinet"])
    PartiduoAdmin::BackupEncryption.set_firm_mode(admin, firm, "exploitation").ok?.should be_true
  end

  it "garde à chaque sauvegarde son mode, sa capsule et son serveur d'origine quand le réglage change" do
    firm, admin, key = keyed_firm("Modes figés")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    old = AdminSpec.backup(dossier, SPEC_NOW - 3.days)
    backup, identity = sealed_backup(dossier, key)
    PartiduoAdmin::BackupEncryption.set_firm_mode(admin, firm, "cabinet").ok?.should be_true
    PartiduoAdmin::BackupEncryption.set_firm_mode(admin, firm, "none").ok?.should be_true
    old.reload.encryption_mode.should eq("none")
    backup.reload.encryption_mode.should eq("cabinet")
    backup.key_fingerprint.should eq(key.fingerprint)
    backup.recipient.should eq(Crypto.recipient_of(identity))
    backup.capsule.to_s.should_not be_empty
    backup.capsule_name.should eq("backup-20260927T100000Z.key.rsa")
    backup.origin.should eq(server.name)
    backup.signing_key.should eq(Crypto::Signature.fingerprint(OPERATOR[1]))
    backup.media_sha256.should eq("b" * 64)
  end
end

describe "Chiffrement des sauvegardes : restauration et restauration test (D-CHF-005, D-CHF-016, D-CHF-017)" do
  it "n'accepte que la bonne clé de sauvegarde, la remet une seule fois à l'exécutant et ne la garde nulle part" do
    firm = AdminSpec.firm("Restauration")
    admin = AdminSpec.user(Config::FIRM_ADMIN, firm)
    server, token = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    backup, identity = sealed_backup(dossier)
    backup.exploitation_sealed.should be_true
    PartiduoAdmin::BackupEncryption.add_signing_key(AdminSpec.super_admin, server, OPERATOR[1]).ok?.should be_true
    date = SPEC_NOW

    missing = PartiduoAdmin::Fleet.restore(admin, dossier, date, "replace")
    missing.errors["data_key"].should eq(["admin.errors.encryption.key_required"])
    wrong = PartiduoAdmin::Fleet.restore(admin, dossier, date, "replace", "", backup.pk!.as(Int64), Crypto.keygen.identity)
    wrong.errors["data_key"].should eq(["admin.errors.encryption.wrong_key"])
    garbage = PartiduoAdmin::Fleet.restore(admin, dossier, date, "replace", "", backup.pk!.as(Int64), "AGE-SECRET-KEY-1ABC")
    garbage.errors["data_key"].should eq(["admin.errors.encryption.wrong_key"])
    PartiduoAdmin::Task.filter(kind: "backup.restore").count.should eq(0)

    task = PartiduoAdmin::Fleet.restore(admin, dossier, date, "replace", "", backup.pk!.as(Int64), " #{identity}\n").value!
    task.params.to_s.should_not contain(identity)
    task.params_json["key_provided"].as_bool.should be_true
    task.params_json["path"].should eq(backup.path)
    task.params_json["backup_encryption"]["recipient"].should eq(backup.recipient)
    task.params_json["encryption"]["mode"].should eq("exploitation")
    signers = task.params_json["signers"].as_a.map(&.as_s)
    signers.should eq([Crypto::Signature.allowed_signer(server.name.to_s, OPERATOR[1])])
    PartiduoAdmin::AuditEntry.all.to_a.none?(&.detail.to_s.includes?(identity)).should be_true
    audits("backup.restore").last.detail.to_s.should contain(%("key_provided":"true"))

    # Tâches précédentes du dossier remises d'abord ; puis la restauration.
    claimed = api("/api/agent/v1/claim", token)
    until claimed["task"]["kind"] == "backup.restore"
      claimed = api("/api/agent/v1/claim", token)
    end
    claimed["api"].should eq("3.0.0")
    claimed["task"]["secrets"]["data_keys"].as_a.map(&.as_s).should eq([identity])
    claimed["task"]["params"].to_json.should_not contain(identity)
    task.reload.data_keys.should eq("")
    # Bail échu : la tâche est reprise, sans la clé.
    task.lease_until = SPEC_NOW - 1.minute
    task.save!
    again = api("/api/agent/v1/claim", token)
    again["task"]["id"].should eq(task.pk)
    again["task"]["secrets"]["data_keys"].as_a.should be_empty
    api("/api/agent/v1/tasks/#{task.pk}/finish", token, {"ok" => false, "error" => "clé requise", "result" => {} of String => String})
    # Une tâche qui a reçu la clé ne se rejoue pas : la clé est à refournir.
    PartiduoAdmin::Tasks.retryable?(task.reload).should be_false
  end

  it "vérifie l'enveloppe seule sans la clé, en entier avec elle" do
    firm, admin, key = keyed_firm("Tests")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    backup, identity = sealed_backup(dossier, key)
    envelope = PartiduoAdmin::Fleet.test_restore(nil, backup).value!
    envelope.params_json["backup_encryption"]["mode"].should eq("cabinet")
    envelope.params_json["media_sha256"].should eq("b" * 64)
    # Aucune clé de signature déclarée : l'exécutant refusera de la lire.
    envelope.params_json["signers"].as_a.should be_empty
    envelope.data_keys.should eq("")
    envelope.state = "running"
    envelope.save!
    PartiduoAdmin::Tasks.finish(envelope, true, JSON.parse(%({"verified":false,"envelope_verified":true,"check":"envelope"})))
    backup.reload.test_check.should eq("envelope")
    backup.state.should eq("done")
    backup.test_restored_at.should_not be_nil

    PartiduoAdmin::Fleet.test_restore(admin, backup, Crypto.keygen.identity).ok?.should be_false
    full = PartiduoAdmin::Fleet.test_restore(admin, backup, identity).value!
    full.data_keys.to_s.should_not be_empty
    full.state = "running"
    full.save!
    PartiduoAdmin::Tasks.finish(full, true, JSON.parse(%({"verified":true,"check":"full"})))
    full.reload.data_keys.should eq("")
    backup.reload.test_check.should eq("full")
    backup.state.should eq("verified")
  end

  it "enregistre ce que rend l'exécutant : emplacements, destinataire, capsule, manifeste signé" do
    firm = AdminSpec.firm
    server, token = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    task = PartiduoAdmin::Fleet.backup_now(nil, dossier).value!
    api("/api/agent/v1/claim", token)
    recipient = Crypto.keygen.recipient
    stem = "#{server.name}/#{dossier.slug}/backup-20260928T090000Z"
    result = {"path" => "#{stem}.dump.age", "media_path" => "#{stem}.media.tar.gz.age", "size_bytes" => 1,
              "sha256" => "c" * 64, "media_sha256" => "d" * 64, "taken_at" => SPEC_NOW.to_rfc3339, "server" => server.name,
              "encryption" => {"mode" => "exploitation", "recipient" => recipient, "key_fingerprint" => "",
                               "capsule" => "QUJD", "capsule_keys" => ["e" * 64, "pas une empreinte"]},
              "manifest" => "partiduo-backup/2\n", "signature" => "-----BEGIN SSH SIGNATURE-----\n",
              "signing_key" => "#{OPERATOR[1]} srv"}
    api("/api/agent/v1/tasks/#{task.pk}/finish", token, {"ok" => true, "result" => result})
    backup = PartiduoAdmin::Backup.filter(dossier_id: dossier.pk).first!
    backup.encryption_mode.should eq("exploitation")
    backup.path.should eq("#{stem}.dump.age")
    backup.recipient.should eq(recipient)
    backup.capsule.should eq("QUJD")
    backup.capsule_fingerprints.should eq(["e" * 64])
    backup.capsule_name.should eq("backup-20260928T090000Z.key.age")
    backup.key_fingerprint.should eq("")
    backup.origin.should eq(server.name)
    backup.manifest.should eq("partiduo-backup/2\n")
    backup.signing_key.should eq(Crypto::Signature.fingerprint(OPERATOR[1]))
    backup.media_sha256.should eq("d" * 64)
  end

  it "n'élague pas les sauvegardes qu'un autre serveur garde" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    kept = AdminSpec.backup(dossier, SPEC_NOW - 60.days)
    gone = AdminSpec.backup(dossier, SPEC_NOW - 50.days)
    task = PartiduoAdmin::Task.create!(kind: "backup.prune", server: server, dossier: dossier, state: "running",
      params: {"backup_ids" => [kept.pk, gone.pk]}.to_json)
    PartiduoAdmin::Tasks.finish(task, true, JSON.parse({"pruned" => 1, "kept" => [kept.path, kept.media_path]}.to_json))
    kept.reload.state.should eq("done")
    gone.reload.state.should eq("pruned")
  end
end

describe "Chiffrement des sauvegardes : clés de signature des serveurs (D-CHF-018)" do
  it "déclare et révoque une clé de signature, réservée au parc ; la révocation borne les signataires" do
    server, _ = AdminSpec.server
    root = AdminSpec.super_admin
    firm_admin = AdminSpec.user(Config::FIRM_ADMIN, AdminSpec.firm)
    PartiduoAdmin::BackupEncryption.add_signing_key(firm_admin, server, OPERATOR[1]).errors.has_key?("base").should be_true
    PartiduoAdmin::BackupEncryption.add_signing_key(root, server, "ssh-rsa AAAA").errors["public_key"]
      .should eq(["admin.errors.signing_key.invalid"])
    key = PartiduoAdmin::BackupEncryption.add_signing_key(root, server, "#{OPERATOR[1]} loulou").value!
    key.public_key.should eq(OPERATOR[1])
    key.fingerprint.should eq(Crypto::Signature.fingerprint(OPERATOR[1]))
    PartiduoAdmin::BackupEncryption.add_signing_key(root, server, OPERATOR[1]).errors["public_key"]
      .should eq(["admin.errors.signing_key.taken"])
    audits("signing_key.add").last.detail.to_s.should contain(key.fingerprint.to_s)

    dossier = AdminSpec.dossier(AdminSpec.firm, server)
    backup = AdminSpec.backup(dossier)
    PartiduoAdmin::BackupEncryption.signers(backup).should eq([Crypto::Signature.allowed_signer(server.name.to_s, OPERATOR[1])])
    PartiduoAdmin::BackupEncryption.revoke_signing_key(root, key).should be_true
    PartiduoAdmin::BackupEncryption.revoke_signing_key(root, key.reload).should be_false
    PartiduoAdmin::BackupEncryption.signers(backup).first.should contain(%(valid-before="#{SPEC_NOW.to_s("%Y%m%d%H%M%SZ")}"))
    audits("signing_key.revoke").size.should eq(1)

    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    page = browser.get("/servers").html
    page.should contain("Clés de signature des sauvegardes")
    page.should contain(key.fingerprint.to_s)
    other, _ = AdminSpec.server
    browser.post("/servers/#{other.pk}/signing-keys", {"public_key" => "rien"}).status.should eq(302)
    other.signing_keys.should be_empty
  end
end

describe "Chiffrement des sauvegardes : écrans (D-CHF-002, D-CHF-005, D-CHF-016)" do
  it "règle le cabinet, dépose la clé et affiche son empreinte, en français, anglais et néerlandais" do
    firm = AdminSpec.firm("Écrans")
    admin = AdminSpec.user(Config::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    page = browser.get("/firms/#{firm.pk}/backups")
    page.status.should eq(200)
    html = page.html
    html.should contain("Chiffrement des sauvegardes")
    html.should contain("Clé d'exploitation")
    html.should_not contain("Clé du serveur")
    html.should contain(%(name="mode" value="cabinet" disabled))
    html.should contain("data-pd-keygen")
    html.should contain(%(<script src="/assets/admin/js/backup-keys.js"))
    # Champs de la phrase de passe sans attribut name : jamais envoyés.
    html.should_not match(/<input[^>]*name="[^"]*"[^>]*id="pd-keygen-pass"/)
    browser.get("/dossiers").html.should contain(%(href="/firms/#{firm.pk}/backups"))

    pair = AdminSpec::Keys.pair("a")
    browser.post("/firms/#{firm.pk}/backups/key", {"public_key" => "n'importe quoi"}).status.should eq(422)
    deposited = browser.post("/firms/#{firm.pk}/backups/key", {"public_key" => pair.public_pem})
    deposited.status.should eq(302)
    fingerprint = Crypto::PublicKey.new(pair.public_pem).fingerprint
    browser.get("/firms/#{firm.pk}/backups").html.should contain(Crypto.display_fingerprint(fingerprint))
    browser.post("/firms/#{firm.pk}/backups", {"mode" => "cabinet"}).status.should eq(302)
    firm.reload.backup_encryption.should eq("cabinet")

    {"en" => "Backup encryption", "nl" => "Versleuteling van back-ups"}.each do |locale, title|
      admin.locale = locale
      admin.save!
      browser.get("/firms/#{firm.pk}/backups").html.should contain(title)
    end
  end

  it "refuse la page d'un autre cabinet et du gestionnaire ; le super-admin voit sans pouvoir déposer" do
    firm = AdminSpec.firm
    other = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Config::FIRM_ADMIN, AdminSpec.firm)))
    other.get("/firms/#{firm.pk}/backups").status.should eq(403)
    manager = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Config::FILE_MANAGER, firm)))
    manager.get("/firms/#{firm.pk}/backups").status.should eq(403)
    root = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.super_admin))
    page = root.get("/firms/#{firm.pk}/backups").html
    page.should contain("Seul l'admin du cabinet")
    page.should_not contain("data-pd-keygen")
    root.post("/firms/#{firm.pk}/backups/key", {"public_key" => AdminSpec::Keys.pair("a").public_pem}).status.should eq(403)
    root.get("/firms").html.should contain(%(href="/firms/#{firm.pk}/backups"))
  end

  it "demande la clé du cabinet avant de restaurer : la capsule s'ouvre dans le navigateur" do
    firm, admin, key = keyed_firm("Fiche")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    AdminSpec.backup(dossier, SPEC_NOW - 5.days)
    backup, identity = sealed_backup(dossier, key)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    fiche = browser.get("/dossiers/#{dossier.pk}").html
    fiche.should contain("Clé du cabinet")
    fiche.should contain(backup.short_fingerprint)
    fiche.should contain(%(href="/backups/#{backup.pk}/unlock?purpose=test"))
    fiche.should contain(%(action="/dossiers/#{dossier.pk}/encryption"))

    redirect = browser.post("/dossiers/#{dossier.pk}/restore", {"date" => SPEC_NOW.to_s("%F"), "target" => "replace", "new_slug" => ""})
    redirect.status.should eq(302)
    location = redirect.headers["Location"]
    location.should start_with("/backups/#{backup.pk}/unlock?purpose=restore")
    unlock = browser.get(location)
    unlock.status.should eq(200)
    html = unlock.html
    html.should contain(%(data-capsule="#{backup.capsule}"))
    html.should contain(%(data-fingerprint="#{key.fingerprint}"))
    html.should contain(%(name="data_key"))
    html.should contain(%(name="backup_id" value="#{backup.pk}"))
    # Clé privée et phrase de passe : aucun champ nommé, rien n'est envoyé.
    html.scan(/<(?:input|textarea)[^>]*>/).map(&.[0]).select(&.includes?("data-pd-key")).each do |tag|
      tag.should_not contain("name=")
    end

    browser.post("/dossiers/#{dossier.pk}/restore", {"date" => SPEC_NOW.to_s("%F"), "target" => "replace", "new_slug" => "",
                                                     "backup_id" => backup.pk.to_s, "data_key" => Crypto.keygen.identity})
    PartiduoAdmin::Task.filter(kind: "backup.restore").count.should eq(0)
    done = browser.post("/dossiers/#{dossier.pk}/restore", {"date" => SPEC_NOW.to_s("%F"), "target" => "replace", "new_slug" => "",
                                                            "backup_id" => backup.pk.to_s, "data_key" => identity})
    done.status.should eq(302)
    PartiduoAdmin::Task.filter(kind: "backup.restore").count.should eq(1)

    tested = browser.post("/backups/#{backup.pk}/test", {"data_key" => identity})
    tested.status.should eq(302)
    PartiduoAdmin::Task.filter(kind: "backup.test_restore").first!.data_keys.to_s.should_not be_empty
    browser.get("/backups/#{backup.pk}/unlock?purpose=test").status.should eq(200)
  end

  it "clé d'exploitation : la page donne la capsule et la commande, puis reçoit la seule clé de la sauvegarde" do
    firm = AdminSpec.firm("Exploitation")
    admin = AdminSpec.user(Config::FIRM_ADMIN, firm)
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    backup, identity = sealed_backup(dossier)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    browser.get("/dossiers/#{dossier.pk}").html.should contain(%(href="/backups/#{backup.pk}/unlock?purpose=test"))
    location = browser.post("/dossiers/#{dossier.pk}/restore", {"date" => SPEC_NOW.to_s("%F"), "target" => "replace",
                                                                "new_slug" => ""}).headers["Location"]
    html = browser.get(location).html
    html.should contain("Clé de la sauvegarde requise")
    html.should contain(%(href="/backups/#{backup.pk}/capsule"))
    html.should contain("age -d -i exploitation.age backup-20260927T100000Z.key.age")
    html.should contain(Crypto.display_fingerprint(Crypto.recipient_fingerprint(OPERATOR[0])[0, 16]))
    html.should_not contain("backup-keys.js")

    capsule = browser.get("/backups/#{backup.pk}/capsule")
    capsule.status.should eq(200)
    capsule.headers["Content-Disposition"].should contain("backup-20260927T100000Z.key.age")
    capsule.content.to_slice.should eq(Base64.decode(backup.capsule.to_s))
    audits("backup.capsule").size.should eq(1)
    outsider = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Config::FIRM_ADMIN, AdminSpec.firm)))
    outsider.get("/backups/#{backup.pk}/capsule").status.should eq(403)

    done = browser.post("/dossiers/#{dossier.pk}/restore", {"date" => SPEC_NOW.to_s("%F"), "target" => "replace", "new_slug" => "",
                                                            "backup_id" => backup.pk.to_s, "data_key" => identity})
    done.status.should eq(302)
    PartiduoAdmin::Task.filter(kind: "backup.restore").count.should eq(1)
  end
end

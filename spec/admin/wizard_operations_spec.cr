# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Assistants des opérations du parc (D-ADM-022) : ajouter un serveur,
# restaurer, déplacer, archiver un dossier, inviter un utilisateur. Étapes
# numérotées, saisies gardées côté serveur, rien d'enregistré avant la
# validation finale, puis les services et les tâches des formulaires.

private alias Cfg = PartiduoAdmin::Config
private alias Crypto = PartiduoAdmin::BackupCrypto
private alias Data = Hash(String, String | Array(String))

# Clé d'exploitation (destinataire) et clé de signature d'un serveur.
private OPERATOR = begin
  directory = File.join(Dir.tempdir, "partiduo-wizard-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(directory)
  path = File.join(directory, "exploitation.age")
  Crypto.run!("age-keygen", ["-pq", "-o", path])
  signing = File.join(directory, "backup-signing.key")
  Crypto::Signature.generate(signing, "srv")
  {String.new(Crypto.run!("age-keygen", ["-y", path])).strip, Crypto::Signature.public_line(signing)}
end

private def step(browser : AdminSpec::Browser, kind : String, data : Data, nav : String = "next") : Marten::HTTP::Response
  page = browser.get("/wizards/#{kind}")
  number = page.html.match!(/name="step" value="(\d+)"/)[1]
  browser.post("/wizards/#{kind}", data.merge({"step" => number, "nav" => nav} of String => String | Array(String)))
end

# Sauvegarde chiffrée par les clés d'exploitation, signée par la clé du
# serveur, telle que l'exécutant la rendrait ; et sa clé de sauvegarde.
private def sealed_backup(dossier : PartiduoAdmin::Dossier) : {PartiduoAdmin::Backup, String}
  backup_key = Crypto.keygen
  capsule = Crypto.capsule_for(backup_key.identity, [OPERATOR[0]])
  server = dossier.server!.name.to_s
  stem = "#{server}/#{dossier.slug}/backup-20260927T100000Z"
  data = JSON.parse({"path" => "#{stem}.dump.age", "media_path" => "#{stem}.media.tar.gz.age",
                     "sha256" => "a" * 64, "media_sha256" => "b" * 64, "size_bytes" => 10, "server" => server,
                     "taken_at" => (SPEC_NOW - 1.day).to_rfc3339,
                     "encryption" => {"mode" => "exploitation", "recipient" => backup_key.recipient, "key_fingerprint" => "",
                                      "capsule" => Base64.strict_encode(capsule), "capsule_keys" => [Crypto.recipient_fingerprint(OPERATOR[0])]},
                     "manifest" => "partiduo-backup/2\nserver #{server}\n", "signature" => "-----BEGIN SSH SIGNATURE-----\n",
                     "signing_key" => OPERATOR[1]}.to_json)
  task = PartiduoAdmin::Task.create!(kind: "backup.run", server: dossier.server!, dossier: dossier, params: %({"kind":"manual"}))
  {PartiduoAdmin::Tasks::Effects.record_backup(task, dossier, "manual", data, SPEC_NOW), backup_key.identity}
end

describe "Assistant « Ajouter un serveur » (D-ADM-022)" do
  it "déclare le serveur au récapitulatif, montre le jeton une fois, attend l'exécutant, puis ses capacités" do
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    browser.get("/servers").html.should contain(%(href="/wizards/server"))
    browser.get("/").html.should contain(%(href="/wizards/server"))
    first = browser.get("/wizards/server")
    first.html.should contain("Étape 1 sur 5 : Identité")
    first.html.should contain(%(value="partiduo.localhost"))

    refused = step(browser, "server", Data{"name" => "Mauvais Nom", "hostname" => "h.example.net", "domain" => "partiduo.localhost"})
    refused.status.should eq(422)
    step(browser, "server", Data{"name" => "srv-assiste", "hostname" => "assiste.example.net", "domain" => "partiduo.localhost"})
      .status.should eq(302)
    summary = browser.get("/wizards/server").html
    summary.should contain("Étape 2 sur 5 : Récapitulatif")
    summary.should contain("assiste.example.net")
    summary.should contain("Valider et déclarer le serveur")
    PartiduoAdmin::Server.filter(name: "srv-assiste").exists?.should be_false

    # Validation : le serveur et son jeton, montré dans la réponse seulement.
    created = step(browser, "server", Data.new, "finish")
    created.status.should eq(200)
    created.html.should contain("Étape 3 sur 5 : Raccordement")
    token = created.html.match!(/class="pd-token[^"]*"[^>]*>([^<]+)</)[1]
    server = PartiduoAdmin::Server.get!(name: "srv-assiste")
    PartiduoAdmin::Directory.server_for_token(token).try(&.pk).should eq(server.pk)
    created.html.should contain("--server-name srv-assiste")
    again = browser.get("/wizards/server")
    again.html.should_not contain(token)
    # Identité et récapitulatif ne se rouvrent plus.
    browser.get("/wizards/server?step=1").html.should contain("Étape 3 sur 5")
    again.html.should_not contain(%(href="/wizards/server?step=1"))

    # Jeton régénéré : l'ancien cesse de valoir.
    rotated = step(browser, "server", Data.new, "rotate")
    fresh = rotated.html.match!(/class="pd-token[^"]*"[^>]*>([^<]+)</)[1]
    fresh.should_not eq(token)
    PartiduoAdmin::Directory.server_for_token(token).should be_nil
    step(browser, "server", Data.new).status.should eq(302)

    # Vérification : refusée tant que l'exécutant ne s'est pas présenté.
    check = browser.get("/wizards/server")
    check.html.should contain("Étape 4 sur 5 : Vérification")
    check.html.should contain(%(hx-trigger="every 5s"))
    waiting = step(browser, "server", Data.new)
    waiting.status.should eq(422)
    waiting.html.should contain("ne s'est pas encore présenté")
    client = Marten::Spec::Client.new
    client.post("/api/agent/v1/claim", data: "{}", content_type: "application/json",
      headers: {"Host" => "127.0.0.1", "Authorization" => "Bearer #{fresh}", "X-Partiduo-Agent" => PartiduoAdmin::VERSION,
                "X-Partiduo-Agent-Mode" => "dry-run"}).status.should eq(200)
    connected = browser.get("/wizards/server").html
    connected.should contain("la connexion fonctionne")
    connected.should_not contain(%(hx-trigger="every 5s"))
    step(browser, "server", Data.new).status.should eq(302)

    # Capacités : mode à blanc signalé, clé de signature, premier contrôle.
    capabilities = browser.get("/wizards/server").html
    capabilities.should contain("Étape 5 sur 5 : Capacités")
    capabilities.should contain("Exécutant à blanc")
    capabilities.should contain("Aucune clé de signature déclarée")
    step(browser, "server", Data{"public_key" => "pas une clé"}, "signing").status.should eq(422)
    step(browser, "server", Data{"public_key" => OPERATOR[1]}, "signing").status.should eq(302)
    browser.get("/wizards/server").html.should contain(Crypto::Signature.fingerprint(OPERATOR[1]))
    step(browser, "server", Data.new, "probe").status.should eq(302)
    PartiduoAdmin::Task.filter(kind: "supervision.check", server_id: server.pk).exists?.should be_true

    done = step(browser, "server", Data.new, "finish")
    {done.status, done.headers["Location"]}.should eq({302, "/servers"})
    PartiduoAdmin::WizardDraft.filter(user_id: root.pk).exists?.should be_false
  end

  it "est réservé au super-admin" do
    admin = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Cfg::FIRM_ADMIN)))
    admin.get("/wizards/server").status.should eq(403)
    admin.get("/wizards/move").status.should eq(403)
  end
end

describe "Assistant « Restaurer un dossier » (D-ADM-022)" do
  it "restaure une sauvegarde en clair dans une instance neuve, après confirmation, par la tâche du formulaire" do
    firm = AdminSpec.firm("Cabinet Restauré")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server, slug: "restaure-moi")
    backup = AdminSpec.backup(dossier)
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    browser.get("/dossiers").html.should contain(%(href="/wizards/restore"))
    browser.get("/dossiers/#{dossier.pk}").html.should contain(%(href="/wizards/restore?dossier=#{dossier.pk}"))

    # Ouvert depuis la fiche : le dossier est retenu, l'étape 2 s'ouvre.
    opened = browser.get("/wizards/restore?dossier=#{dossier.pk}")
    opened.html.should contain("Étape 2 sur 5 : Sauvegarde")
    step(browser, "restore", Data.new).status.should eq(422)
    step(browser, "restore", Data{"backup_id" => backup.pk.to_s}).status.should eq(302)
    step(browser, "restore", Data{"target" => "new", "new_slug" => "restaure-moi"}).status.should eq(422)
    step(browser, "restore", Data{"target" => "new", "new_slug" => "restaure-copie"}).status.should eq(302)
    check = browser.get("/wizards/restore").html
    check.should contain("Étape 4 sur 5 : Vérification")
    check.should contain("Aucune signature enregistrée")
    check.should contain("Sauvegarde en clair")
    step(browser, "restore", Data.new).status.should eq(302)

    summary = browser.get("/wizards/restore").html
    summary.should contain("Étape 5 sur 5 : Récapitulatif")
    summary.should contain("Opérations sensibles de la structure")
    summary.should contain("Valider et restaurer")
    PartiduoAdmin::Task.filter(kind: "backup.restore").exists?.should be_false

    unconfirmed = step(browser, "restore", Data.new, "finish")
    unconfirmed.status.should eq(422)
    unconfirmed.html.should contain("Cochez la confirmation")
    done = step(browser, "restore", Data{"confirm" => ["yes"]}, "finish")
    task = PartiduoAdmin::Task.get!(kind: "backup.restore", dossier_id: dossier.pk)
    {done.status, done.headers["Location"]}.should eq({302, "/tasks/#{task.pk}"})
    {task.params_json["target"].as_s, task.params_json["new_slug"].as_s, task.params_json["backup_id"].as_i64}
      .should eq({"new", "restaure-copie", backup.pk})
    PartiduoAdmin::Dossier.filter(slug: "restaure-copie", state: "creating").exists?.should be_true
    PartiduoAdmin::WizardDraft.filter(user_id: admin.pk).exists?.should be_false
  end

  it "demande la clé d'une sauvegarde chiffrée à la dernière étape, sans la garder, et refuse une mauvaise clé" do
    firm = AdminSpec.firm("Cabinet Chiffré")
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    backup, identity = sealed_backup(dossier)
    PartiduoAdmin::BackupEncryption.add_signing_key(AdminSpec.super_admin, server, OPERATOR[1]).ok?.should be_true
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    browser.get("/wizards/restore?dossier=#{dossier.pk}")
    step(browser, "restore", Data{"backup_id" => backup.pk.to_s}).status.should eq(302)
    step(browser, "restore", Data{"target" => "replace", "new_slug" => ""}).status.should eq(302)
    check = browser.get("/wizards/restore").html
    check.should contain("Étape 4 sur 6 : Vérification")
    check.should contain("Manifeste signé par une clé déclarée du serveur d'origine.")
    check.should contain("Chiffrée par la clé d'exploitation")
    step(browser, "restore", Data.new).status.should eq(302)
    summary = browser.get("/wizards/restore").html
    summary.should contain("Remplacement : l'instance actuelle sera remplacée")
    step(browser, "restore", Data.new).status.should eq(302)

    key = browser.get("/wizards/restore").html
    key.should contain("Étape 6 sur 6 : Clé et validation")
    key.should contain(%(href="/backups/#{backup.pk}/capsule"))
    key.should contain(%(name="data_key"))
    key.should_not contain(%(hx-boost="true"))
    wrong = step(browser, "restore", Data{"data_key" => Crypto.keygen.identity, "confirm" => ["yes"]}, "finish")
    wrong.status.should eq(422)
    wrong.html.should contain(%(id="pd-unlock-error"))
    PartiduoAdmin::WizardDraft.get!(user_id: admin.pk, kind: "restore").data.to_s.should_not contain("AGE-SECRET-KEY")
    done = step(browser, "restore", Data{"data_key" => identity, "confirm" => ["yes"]}, "finish")
    done.status.should eq(302)
    task = PartiduoAdmin::Task.get!(kind: "backup.restore", dossier_id: dossier.pk)
    task.params_json["key_provided"].as_bool.should be_true
    task.params.to_s.should_not contain(identity)
  end

  it "est refusé au gestionnaire de dossiers" do
    manager = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(Cfg::FILE_MANAGER)))
    {"restore", "archive", "user"}.each { |kind| manager.get("/wizards/#{kind}").status.should eq(403) }
  end
end

describe "Assistant « Déplacer un dossier » (D-ADM-022)" do
  it "bascule le dossier suspendu vers un autre serveur, puis prépare la restauration « déplacement »" do
    firm = AdminSpec.firm
    origin, _ = AdminSpec.server
    destination, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, origin, state: "suspended")
    dossier.suspended_at = SPEC_NOW - 2.hours
    dossier.save!
    AdminSpec.backup(dossier, taken_at: SPEC_NOW - 1.day)
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    browser.get("/dossiers/#{dossier.pk}").html.should contain(%(href="/wizards/move?dossier=#{dossier.pk}"))
    browser.get("/wizards/move?dossier=#{dossier.pk}").html.should contain("Étape 2 sur 4 : Serveur d'accueil")
    step(browser, "move", Data{"server_id" => origin.pk.to_s}).status.should eq(422)
    step(browser, "move", Data{"server_id" => destination.pk.to_s}).status.should eq(302)
    consequences = browser.get("/wizards/move").html
    consequences.should contain("Le nom du dossier bascule aussitôt vers le nouveau serveur.")
    consequences.should contain("Aucune sauvegarde prise depuis la suspension")
    consequences.should contain("Aucune donnée n'est effacée")
    step(browser, "move", Data{"reason" => "ok"}).status.should eq(422)
    step(browser, "move", Data{"reason" => "nouveau serveur plus grand"}).status.should eq(302)
    browser.get("/wizards/move").html.should contain("Valider et basculer le nom")
    dossier.reload.server_id.should eq(origin.pk)

    done = step(browser, "move", Data{"confirm" => ["yes"]}, "finish")
    {done.status, done.headers["Location"]}.should eq({302, "/wizards/restore"})
    dossier.reload.server_id.should eq(destination.pk)
    following = browser.get("/wizards/restore").html
    following.should contain("Étape 2 sur 5 : Sauvegarde")
    PartiduoAdmin::WizardDraft.get!(user_id: root.pk, kind: "restore").text("target").should eq("move")
  end
end

describe "Assistant « Archiver un dossier » (D-ADM-022)" do
  it "dit les conséquences, exige un motif et la confirmation, puis enregistre la tâche d'archivage" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    browser.get("/dossiers/#{dossier.pk}").html.should contain(%(href="/wizards/archive?dossier=#{dossier.pk}"))
    first = browser.get("/wizards/archive")
    first.html.should contain("Étape 1 sur 3 : Dossier")
    step(browser, "archive", Data{"dossier_id" => dossier.pk.to_s}).status.should eq(302)
    consequences = browser.get("/wizards/archive").html
    consequences.should contain("L'instance est arrêtée")
    consequences.should contain("10 ans")
    step(browser, "archive", Data{"reason" => ""}).status.should eq(422)
    step(browser, "archive", Data{"reason" => "cessation d'activité"}).status.should eq(302)
    step(browser, "archive", Data.new, "finish").status.should eq(422)
    PartiduoAdmin::Task.filter(kind: "instance.archive").exists?.should be_false
    done = step(browser, "archive", Data{"confirm" => ["yes"]}, "finish")
    {done.status, done.headers["Location"]}.should eq({302, "/dossiers/#{dossier.pk}"})
    task = PartiduoAdmin::Task.get!(kind: "instance.archive", dossier_id: dossier.pk)
    task.params_json["reason"].as_s.should eq("cessation d'activité")
    task.params_json["encryption"]["mode"].as_s.should eq("exploitation")
  end
end

describe "Assistant « Inviter un utilisateur » (D-ADM-022)" do
  it "invite un gestionnaire, lui confie des dossiers, et montre le courriel d'invitation dans sa langue" do
    firm = AdminSpec.firm("Cabinet Invitant")
    server, _ = AdminSpec.server
    mine = AdminSpec.dossier(firm, server, slug: "mien")
    other = AdminSpec.dossier(AdminSpec.firm, server, slug: "autre")
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    browser.get("/users").html.should contain(%(href="/wizards/user"))
    step(browser, "user", Data{"email" => "pas-une-adresse", "first_name" => "", "last_name" => ""}).status.should eq(422)
    step(browser, "user", Data{"email" => "gerante@invitant.fr", "first_name" => "Gina", "last_name" => "Gérante"}).status.should eq(302)
    step(browser, "user", Data{"role" => Cfg::FILE_MANAGER}).status.should eq(302)
    dossiers = browser.get("/wizards/user").html
    dossiers.should contain("mien — ")
    dossiers.should_not contain("autre — ")
    step(browser, "user", Data{"dossier_ids" => [other.pk.to_s]}).status.should eq(422)
    step(browser, "user", Data{"dossier_ids" => [mine.pk.to_s]}).status.should eq(302)
    language = browser.get("/wizards/user").html
    language.should contain("Courriel d'invitation")
    step(browser, "user", Data{"locale" => "de"}).status.should eq(302)
    summary = browser.get("/wizards/user").html
    summary.should contain("Étape 5 sur 5 : Récapitulatif")
    summary.should contain("Allemand")
    PartiduoAdmin::User.filter(email: "gerante@invitant.fr").exists?.should be_false

    before = Marten::Spec.delivered_emails.size
    done = step(browser, "user", Data.new, "finish")
    {done.status, done.headers["Location"]}.should eq({302, "/users"})
    invited = PartiduoAdmin::User.get!(email: "gerante@invitant.fr")
    {invited.role, invited.firm_id, invited.locale}.should eq({Cfg::FILE_MANAGER, firm.pk, "de"})
    PartiduoAdmin::Assignment.filter(user_id: invited.pk).map(&.dossier_id).should eq([mine.pk])
    Marten::Spec.delivered_emails[before..].map(&.to.map(&.address)).should eq([["gerante@invitant.fr"]])
  end

  it "ne propose pas de dossiers à confier à un admin de cabinet" do
    firm = AdminSpec.firm
    admin = AdminSpec.user(Cfg::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(admin))
    step(browser, "user", Data{"email" => "second@cabinet.fr", "first_name" => "", "last_name" => ""})
    step(browser, "user", Data{"role" => Cfg::FIRM_ADMIN})
    page = browser.get("/wizards/user").html
    page.should contain("Un admin de cabinet voit tous les dossiers de sa structure")
    page.should_not contain(%(name="dossier_ids"))
  end
end

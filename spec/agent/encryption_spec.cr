# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Sauvegardes chiffrées de bout en bout (D-CHF-013 à D-CHF-024) :
# l'exécutant en mode local, sur de vraies bases `partiduo_adm_*`,
# `pg_dump`, `tar`, `pg_restore`, `age` et `ssh-keygen`, un stockage dans
# un répertoire de la machine partagé par deux « serveurs » (loulou et
# bibou), pour les trois modes (aucun, clé d'exploitation, clé du cabinet).

private alias Crypto = PartiduoAdmin::BackupCrypto

private PG_HOST = ENV["PGHOST"]? || "/tmp"

private def pg_env : Hash(String, String)
  {"PGHOST" => PG_HOST}
end

private def psql(database : String, sql : String) : String
  output = IO::Memory.new
  Process.run("psql", ["-X", "-d", database, "-tAc", sql], env: pg_env, output: output)
  output.to_s.strip
end

# Interface d'instance simulée (contrat 1.0.0) sur une vraie base, avec de
# vraies pièces jointes sous `PARTIDUO_MEDIA_ROOT`.
private def fake_manage(directory : String) : String
  path = File.join(directory, "fake-manage")
  File.write(path, <<-SH, perm: 0o755)
    #!/bin/sh
    shift
    action="$1"
    case "$action" in
      version) echo '{"contract":"1.0.0","action":"version","ok":true,"data":{"version":"0.1.0","contract":"1.0.0"}}' ;;
      status)
        if psql -X "$DATABASE_URL" -tAc 'SELECT count(*) FROM spec_marker' >/dev/null 2>&1; then
          echo '{"contract":"1.0.0","action":"status","ok":true,"data":{"version":"0.1.0","provisioned":true,"migrations":{"applied":3,"pending":0}}}'
        else
          echo '{"contract":"1.0.0","action":"status","ok":false,"error":{"code":"database_unavailable","reason":"database.unavailable","message":"base"}}'
          exit 6
        fi ;;
      backup-plan)
        while [ $# -gt 0 ]; do
          if [ "$1" = "--list-file" ]; then (cd "$PARTIDUO_MEDIA_ROOT" 2>/dev/null && find . -type f | sed 's|^\\./||') > "$2"; fi
          shift
        done
        echo "{\\"contract\\":\\"1.0.0\\",\\"action\\":\\"backup-plan\\",\\"ok\\":true,\\"data\\":{\\"media_root\\":\\"$PARTIDUO_MEDIA_ROOT\\",\\"file_count\\":2,\\"missing\\":[]}}" ;;
      *) echo '{"contract":"1.0.0","ok":false,"error":{"code":"usage"}}'; exit 2 ;;
    esac
    SH
  path
end

# Clé d'exploitation de l'exploitant (identité en clair dans un fichier
# hors des répertoires de l'exécutant) et son destinataire.
private OPERATOR = begin
  directory = File.join(Dir.tempdir, "partiduo-chf-exploitant-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(directory)
  path = File.join(directory, "exploitation.age")
  Crypto.run!("age-keygen", ["-pq", "-o", path])
  {path, String.new(Crypto.run!("age-keygen", ["-y", path])).strip}
end

private class LocalBench
  getter admin = AdminSpec::FakeAdmin.new
  getter config : PartiduoAgent::Config
  getter database : String
  getter slug : String
  @next = 100_i64

  # `store` : stockage partagé (restauration sur un autre serveur).
  def initialize(@slug : String, server : String = "loulou", store : String? = nil, create : Bool = true)
    @database = "partiduo_adm_#{@slug.tr("-", "_")}"
    @config = admin.config(PartiduoAgent::Mode::Local)
    Dir.mkdir_p(config.state_dir)
    config.server_name = server
    config.store_dir = store || File.join(config.state_dir, "stockage")
    Dir.mkdir_p(config.store_dir)
    config.manage = fake_manage(config.state_dir)
    config.pg_socket = PG_HOST
    File.write(config.recipients_path, "# clé d'exploitation de la spec\n#{OPERATOR[1]}\n")
    return unless create
    Process.run("dropdb", ["--if-exists", database], env: pg_env)
    Process.run("createdb", ["--encoding=UTF8", database], env: pg_env).success?.should be_true
    # Plusieurs tables liées, index et données : de quoi éprouver pg_restore
    # lisant son entrée standard.
    psql(database, "CREATE TABLE spec_marker (id int PRIMARY KEY, label text); " \
                   "CREATE TABLE spec_line (id serial PRIMARY KEY, marker int REFERENCES spec_marker(id), amount numeric(12,2)); " \
                   "CREATE INDEX spec_line_marker ON spec_line (marker); " \
                   "INSERT INTO spec_marker VALUES (1, 'avant'); " \
                   "INSERT INTO spec_line (marker, amount) SELECT 1, g * 1.5 FROM generate_series(1, 20000) g;")
    media = media_root
    Dir.mkdir_p(File.join(media, "factures"))
    File.write(File.join(media, "factures", "F-001.pdf"), "%PDF facture confidentielle")
    File.write(File.join(media, "note.txt"), "pièce jointe")
  end

  def media_root : String
    File.join(config.work_dir, "instances", slug, "media")
  end

  def params(extra = {} of String => JSON::Any) : Hash(String, JSON::Any)
    base = JSON.parse({"slug" => slug, "host" => "#{slug}.partiduo.localhost", "domain" => "partiduo.localhost",
                       "database" => database, "package" => "app"}.to_json).as_h
    base.merge(extra)
  end

  def run(kind : String, extra : Hash(String, JSON::Any), data_keys : Array(String)? = nil) : JSON::Any
    id = (@next += 1)
    admin.push(id, kind, params(extra), data_keys: data_keys)
    PartiduoAgent::Runner.new(config).run_once.should be_true
    admin.finished[id]
  end

  # Fichiers laissés sur ce serveur (répertoire de sauvegarde du dossier).
  def spool_files : Array(String)
    Dir.glob(File.join(config.backup_dir, slug, "*")).map { |path| File.basename(path) }.sort!
  end

  # Fichiers du stockage, pris par `server`.
  def stored(server : String = config.server) : Array(String)
    Dir.glob(File.join(config.store_dir, server, slug, "*")).map { |path| File.basename(path) }.sort!
  end

  def store_path(locator : String) : String
    File.join(config.store_dir, locator)
  end

  def close : Nil
    admin.close
    Process.run("dropdb", ["--if-exists", database], env: pg_env)
    Process.run("dropdb", ["--if-exists", "partiduo_adm_rt_#{slug.tr("-", "_")}"], env: pg_env)
  end
end

private def any(value) : JSON::Any
  JSON.parse(value.to_json)
end

# Paramètres de lecture d'une sauvegarde, comme l'administration les
# envoie : emplacements, empreintes, mode et destinataire, clé de signature
# du serveur qui l'a prise.
private def source(result : JSON::Any, signers : Array(String)? = nil) : Hash(String, JSON::Any)
  enc = result["encryption"]
  signers ||= [AdminSpec.signer(result["server"].as_s, result["signing_key"].as_s)]
  {"path" => result["path"], "media_path" => result["media_path"], "sha256" => result["sha256"],
   "media_sha256" => result["media_sha256"], "signers" => any(signers),
   "backup_encryption" => any({"mode" => enc["mode"].as_s, "recipient" => enc["recipient"]?.try(&.as_s) || "",
                               "key_fingerprint" => enc["key_fingerprint"]?.try(&.as_s) || ""})}
end

# Clé de sauvegarde sortie de la capsule d'exploitation, sur le « poste de
# l'exploitant » : `age -d` avec la clé privée d'exploitation.
private def open_capsule(result : JSON::Any) : String
  capsule = Base64.decode(result["encryption"]["capsule"].as_s)
  String.new(Crypto.run!("age", ["-d", "-i", OPERATOR[0]], capsule)).strip
end

private def with_bench(slug : String, &)
  bench = LocalBench.new(slug)
  begin
    yield bench
  ensure
    bench.close
  end
end

describe "partiduo-agent : sauvegardes chiffrées en mode local (D-CHF-013 à D-CHF-024)" do
  it "aucun chiffrement : sauvegarde envoyée au stockage, signée, relue, rien ne reste sur le serveur" do
    with_bench("chf-aucun") do |bench|
      backup = bench.run("backup.run", {"kind" => any("manual"), "encryption" => any({"mode" => "none"})})
      backup["ok"].as_bool.should be_true, backup.to_json
      result = backup["result"]
      result["path"].as_s.should match(/\Aloulou\/chf-aucun\/backup-\d{8}T\d{6}Z\.dump\z/)
      result["encryption"]["mode"].should eq("none")
      result["manifest"].as_s.should contain("mode none")
      bench.spool_files.should be_empty
      bench.stored.map(&.sub(/\Abackup-\d{8}T\d{6}Z/, "")).should eq([".dump", ".manifest", ".manifest.sig", ".media.tar.gz"])
      tested = bench.run("backup.test_restore", source(result).reject("backup_encryption"))
      tested["ok"].as_bool.should be_true, tested.to_json
      tested["result"]["check"].should eq("full")
      bench.spool_files.should be_empty
    end
  end

  it "clé d'exploitation : rien en clair, le serveur ne relit plus seul ; la clé sortie de la capsule restaure tout" do
    with_bench("chf-exploitation") do |bench|
      backup = bench.run("backup.run", {"kind" => any("manual"), "encryption" => any({"mode" => "exploitation"})})
      backup["ok"].as_bool.should be_true, backup.to_json
      result = backup["result"]
      enc = result["encryption"]
      result["path"].as_s.should end_with(".dump.age")
      result["media_path"].as_s.should end_with(".media.tar.gz.age")
      enc["mode"].should eq("exploitation")
      enc["capsule_keys"].as_a.map(&.as_s).should eq([Crypto.recipient_fingerprint(OPERATOR[1])])
      # Rien sur le serveur ; au stockage, aucun fichier en clair.
      bench.spool_files.should be_empty
      stored = bench.stored
      stored.map(&.sub(/\Abackup-\d{8}T\d{6}Z/, "")).should eq(
        [".dump.age", ".key.age", ".manifest", ".manifest.sig", ".media.tar.gz.age"])
      dump = File.read(bench.store_path(result["path"].as_s))
      dump.starts_with?("age-encryption.org/v1").should be_true
      dump.includes?("spec_marker").should be_false
      File.read(bench.store_path(result["media_path"].as_s)).includes?("facture confidentielle").should be_false
      Crypto.check_structure(bench.store_path(result["path"].as_s))
      Digest::SHA256.new.file(bench.store_path(result["path"].as_s)).hexfinal.should eq(result["sha256"].as_s)
      # La capsule déposée au stockage est celle rendue à l'administration.
      capsule_file = bench.store_path(result["path"].as_s.sub(".dump.age", ".key.age"))
      File.read(capsule_file).to_slice.should eq(Base64.decode(enc["capsule"].as_s))
      # Journal de reprise effacé : aucune clé de sauvegarde ne reste.
      Dir.glob(File.join(bench.config.state_dir, "tasks", "*")).should be_empty

      # Sans la clé : signature, empreintes et structure seulement.
      tested = bench.run("backup.test_restore", source(result))
      tested["ok"].as_bool.should be_true, tested.to_json
      tested["result"]["check"].should eq("envelope")
      tested["result"]["verified"].as_bool.should be_false

      psql(bench.database, "UPDATE spec_marker SET label = 'après'; DELETE FROM spec_line WHERE id > 10")
      File.delete(File.join(bench.media_root, "factures", "F-001.pdf"))
      replace = source(result).merge({"target" => any("replace"), "encryption" => any({"mode" => "exploitation"})})
      refused = bench.run("backup.restore", replace)
      refused["ok"].as_bool.should be_false
      refused["error"].as_s.should contain("exige sa clé")
      psql(bench.database, "SELECT label FROM spec_marker").should eq("après")

      # Sur le poste de l'exploitant : la capsule s'ouvre avec la clé privée
      # d'exploitation ; seule la clé de cette sauvegarde est remise.
      backup_key = open_capsule(result)
      Crypto.recipient_of(backup_key).should eq(enc["recipient"].as_s)
      full = bench.run("backup.test_restore", source(result), data_keys: [backup_key])
      full["ok"].as_bool.should be_true, full.to_json
      full["result"]["check"].should eq("full")

      wrong = bench.run("backup.restore", replace, data_keys: [Crypto.keygen.identity])
      wrong["ok"].as_bool.should be_false
      psql(bench.database, "SELECT label FROM spec_marker").should eq("après")

      restored = bench.run("backup.restore", replace, data_keys: [backup_key])
      restored["ok"].as_bool.should be_true, restored.to_json
      psql(bench.database, "SELECT label FROM spec_marker").should eq("avant")
      psql(bench.database, "SELECT count(*) FROM spec_line").should eq("20000")
      File.read(File.join(bench.media_root, "factures", "F-001.pdf")).should eq("%PDF facture confidentielle")
      restored["result"]["safety_backup"]["encryption"]["mode"].should eq("exploitation")
      restored["result"]["safety_backup"]["path"].as_s.should contain("pre-restore")
      bench.spool_files.should be_empty
      Dir.glob(File.join(bench.config.state_dir, "tasks", "*")).each do |journal|
        File.read(journal).includes?("AGE-SECRET-KEY").should be_false
      end
    end
  end

  it "restaure sur un autre serveur une sauvegarde prise ailleurs ; seul le serveur d'origine l'efface" do
    with_bench("chf-croisee") do |loulou|
      backup = loulou.run("backup.run", {"kind" => any("manual"), "encryption" => any({"mode" => "exploitation"})})
      backup["ok"].as_bool.should be_true, backup.to_json
      result = backup["result"]
      psql(loulou.database, "UPDATE spec_marker SET label = 'perdue'")

      # loulou est tombé ; bibou partage le stockage et la machine de spec.
      bibou = LocalBench.new("chf-croisee", server: "bibou", store: loulou.config.store_dir, create: false)
      begin
        restored = bibou.run("backup.restore", source(result).merge({"target"     => any("replace"),
                                                                     "encryption" => any({"mode" => "exploitation"})}),
          data_keys: [open_capsule(result)])
        restored["ok"].as_bool.should be_true, restored.to_json
        psql(loulou.database, "SELECT label FROM spec_marker").should eq("avant")
        # Sauvegarde de sûreté : prise et signée par bibou, sous bibou/.
        restored["result"]["safety_backup"]["path"].as_s.should start_with("bibou/chf-croisee/pre-restore-")
        restored["result"]["safety_backup"]["manifest"].as_s.should contain("server bibou")

        # Signée par loulou : une clé de signature de bibou ne l'authentifie pas.
        forged = source(result, [AdminSpec.signer("loulou", restored["result"]["safety_backup"]["signing_key"].as_s)])
        refused = bibou.run("backup.test_restore", forged)
        refused["ok"].as_bool.should be_false
        refused["error"].as_s.should contain("signature du manifeste refusée")
        unknown = bibou.run("backup.test_restore", source(result, [] of String))
        unknown["error"].as_s.should contain("inconnue de l'administration")

        # Élagage par bibou : la sauvegarde de loulou est gardée, rendue.
        pruned = bibou.run("backup.prune", {"paths" => any([result["path"], result["media_path"]])})
        pruned["ok"].as_bool.should be_true, pruned.to_json
        pruned["result"]["kept"].as_a.map(&.as_s).should eq([result["path"].as_s, result["media_path"].as_s])
        loulou.stored("loulou").size.should eq(5)
        own = loulou.run("backup.prune", {"paths" => any([result["path"], result["media_path"]])})
        own["ok"].as_bool.should be_true, own.to_json
        loulou.stored("loulou").should be_empty
      ensure
        bibou.admin.close
      end
    end
  end

  it "clé du cabinet : ni le serveur ni l'exploitant ne relisent ; la clé ouverte par le cabinet restaure" do
    pair = AdminSpec::Keys.pair("a")
    public_key = Crypto::PublicKey.new(pair.public_pem)
    settings = any({"mode" => "cabinet", "public_key" => pair.public_pem, "key_fingerprint" => public_key.fingerprint})
    with_bench("chf-cabinet") do |bench|
      backup = bench.run("backup.run", {"kind" => any("manual"), "encryption" => settings})
      backup["ok"].as_bool.should be_true, backup.to_json
      result = backup["result"]
      enc = result["encryption"]
      enc["mode"].should eq("cabinet")
      enc["key_fingerprint"].should eq(public_key.fingerprint)
      bench.stored.map(&.sub(/\Abackup-\d{8}T\d{6}Z/, "")).should contain(".key.rsa")
      File.read(bench.store_path(result["path"].as_s)).includes?("spec_marker").should be_false
      # La clé d'exploitation n'ouvre pas une capsule du cabinet.
      expect_raises(Crypto::Error) { Crypto.run!("age", ["-d", "-i", OPERATOR[0]], Base64.decode(enc["capsule"].as_s)) }

      tested = bench.run("backup.test_restore", source(result))
      tested["ok"].as_bool.should be_true, tested.to_json
      tested["result"]["check"].should eq("envelope")

      # La capsule ouverte avec la clé privée du cabinet (ici comme dans son
      # navigateur) donne la clé de la sauvegarde.
      private_key = Crypto::PrivateKey.new(pair.private_pem, AdminSpec::Keys::PASSPHRASE)
      backup_key = Crypto.open_cabinet_capsule(Base64.decode(enc["capsule"].as_s), private_key)
      psql(bench.database, "UPDATE spec_marker SET label = 'après'")
      restored = bench.run("backup.restore", source(result).merge({"target" => any("replace"), "encryption" => settings}),
        data_keys: [backup_key])
      restored["ok"].as_bool.should be_true, restored.to_json
      psql(bench.database, "SELECT label FROM spec_marker").should eq("avant")
      psql(bench.database, "SELECT sum(amount) FROM spec_line").should eq("300015000.00")
    end
  end

  it "refuse une sauvegarde altérée au stockage (empreinte, manifeste signé, authentification)" do
    with_bench("chf-falsifie") do |bench|
      backup = bench.run("backup.run", {"kind" => any("manual"), "encryption" => any({"mode" => "exploitation"})})
      result = backup["result"]
      path = bench.store_path(result["path"].as_s)
      File.open(path, "r+") do |file|
        file.seek(4000)
        byte = file.read_byte || raise "octet absent"
        file.seek(4000)
        file.write_byte(byte ^ 0x20_u8)
      end
      digest = bench.run("backup.test_restore", source(result))
      digest["ok"].as_bool.should be_false
      digest["error"].as_s.should contain("empreinte")
      # Sans l'empreinte de l'administration : le manifeste signé la porte.
      unsigned = source(result).merge({"sha256" => any(""), "target" => any("replace"),
                                       "encryption" => any({"mode" => "exploitation"})})
      psql(bench.database, "UPDATE spec_marker SET label = 'intacte'")
      refused = bench.run("backup.restore", unsigned, data_keys: [open_capsule(result)])
      refused["ok"].as_bool.should be_false
      refused["error"].as_s.should contain("altérée")
      psql(bench.database, "SELECT label FROM spec_marker").should eq("intacte")
      bench.spool_files.should be_empty
    end
  end
end

describe "partiduo-agent : sauvegardes chiffrées à blanc et en production" do
  it "compte une archive chiffrée du stockage dans la durée légale (suppression définitive et élagage refusés)" do
    config = PartiduoAgent::Config.new
    config.mode = PartiduoAgent::Mode::Local
    config.server_name = "loulou"
    config.state_dir = File.join(Dir.tempdir, "partiduo-chf-archive-#{Random::Secure.hex(4)}")
    config.backup_dir = File.join(config.state_dir, "sauvegardes")
    system = PartiduoAgent::LocalSystem.new(config, ->(_line : String) { nil })
    stored = File.join(config.store_path, "bibou", "garde", "archive-20260101T000000Z.dump.age")
    Dir.mkdir_p(File.dirname(stored))
    File.write(stored, "chiffré")
    system.archive_dates("garde").should eq([Time.utc(2026, 1, 1)])
    expect_raises(PartiduoAgent::StepError, /durée légale/) { system.guard_retention!("garde", Time.utc(2030, 1, 1)) }
    expect_raises(PartiduoAgent::StepError, /durée légale/) { system.guard_archive_removal!(stored, Time.utc(2030, 1, 1)) }
  end

  it "chiffre, relit, signe et envoie les archives ; une archive chiffrée exige sa clé pour être restaurée" do
    admin = AdminSpec::FakeAdmin.new
    config = admin.config
    config.server_name = "loulou"
    params = {"slug" => "demo", "host" => "demo.partiduo.localhost", "domain" => "partiduo.localhost", "database" => "",
              "package" => "app", "encryption" => {"mode" => "exploitation"}}
    admin.push(1_i64, "instance.archive", params.merge({"reason" => "fin"}))
    runner = PartiduoAgent::Runner.new(config)
    runner.run_once
    report = admin.finished[1_i64]
    report["ok"].as_bool.should be_true, report.to_json
    archived = report["result"]["backup"]
    archived["path"].as_s.should match(/\Aloulou\/demo\/archive-\d{8}T\d{6}Z\.dump\.age\z/)
    archived["encryption"]["mode"].should eq("exploitation")
    archived["verified"].as_bool.should be_true
    calls = runner.last_system.as(PartiduoAgent::DrySystem).calls
    spool = File.join(config.backup_dir, "demo", File.basename(archived["path"].as_s))
    calls.should contain("age -d | pg_restore --list #{spool}")
    calls.should contain("ssh-keygen -Y sign loulou")
    calls.should contain("stockage put #{archived["path"].as_s}")
    calls.count(&.starts_with?("stockage put")).should eq(5)

    restore = params.merge({"target" => "replace", "path" => archived["path"].as_s, "signers" => ["loulou dry-run"],
                            "backup_encryption" => {"mode" => "exploitation", "recipient" => archived["encryption"]["recipient"].as_s}})
    admin.push(2_i64, "backup.restore", restore)
    runner.run_once
    refused = admin.finished[2_i64]
    refused["ok"].as_bool.should be_false
    refused["error"].as_s.should contain("exige sa clé")
  ensure
    admin.try(&.close)
  end

  it "refuse avant tout geste la suppression définitive d'un dossier dont des sauvegardes viennent d'un autre serveur" do
    admin = AdminSpec::FakeAdmin.new
    params = {"slug" => "garde", "host" => "garde.partiduo.localhost", "domain" => "partiduo.localhost", "database" => "",
              "approval_ref" => "DV-1", "approvers" => ["a@x.fr", "b@x.fr"],
              "backups" => ["loulou/garde/archive-20150101T000000Z.dump", "bibou/garde/archive-20150101T000000Z.dump"]}
    admin.push(1_i64, "instance.delete", params)
    runner = PartiduoAgent::Runner.new(admin.config)
    runner.run_once
    report = admin.finished[1_i64]
    report["ok"].as_bool.should be_false
    report["error"].as_s.should contain("sauvegardes prises par bibou")
    runner.last_system.as(PartiduoAgent::DrySystem).calls.none? { |call| call.starts_with?("dropdb") || call.starts_with?("retrait") }
      .should be_true
  ensure
    admin.try(&.close)
  end

  it "refuse un mode inconnu, le mode « clé du serveur » retiré et une clé du cabinet dont l'empreinte n'est pas celle annoncée" do
    admin = AdminSpec::FakeAdmin.new
    pair = AdminSpec::Keys.pair("a")
    base = {"slug" => "demo", "host" => "demo.partiduo.localhost", "domain" => "partiduo.localhost", "database" => "",
            "kind" => "manual"}
    admin.push(1_i64, "backup.run", base.merge({"encryption" => {"mode" => "rot13"}}))
    admin.push(2_i64, "backup.run", base.merge({"encryption" => {"mode" => "cabinet", "public_key" => pair.public_pem,
                                                                 "key_fingerprint" => "00" * 32}}))
    admin.push(3_i64, "backup.run", base.merge({"encryption" => {"mode" => "server"}}))
    runner = PartiduoAgent::Runner.new(admin.config)
    3.times { runner.run_once }
    admin.finished[1_i64]["error"].as_s.should contain("mode de chiffrement inconnu")
    admin.finished[2_i64]["error"].as_s.should contain("empreinte")
    admin.finished[3_i64]["error"].as_s.should contain("mode de chiffrement inconnu : server")
  ensure
    admin.try(&.close)
  end

  it "fait passer le clair par l'entrée et la sortie standard de l'enveloppe de sudo, jusqu'à age, jamais par un fichier" do
    config = PartiduoAgent::Config.new
    config.mode = PartiduoAgent::Mode::Production
    config.domain = "partiduo.app"
    config.backup_dir = File.join(Dir.tempdir, "partiduo-chf-prod-#{Random::Secure.hex(4)}")
    streams = [] of Array(String)
    system = StreamRecordingProduction.new(config, ->(_line : String) { nil }, streams)
    helper = ["/usr/local/bin/sudo", "-n", "-u", "partiduo", "/usr/local/libexec/partiduo-agent/partiduo-agent-instance"]
    root = system.backup_root("garde")
    system.pg_dump_sealed("partiduo_garde", File.join(root, "b.dump.age"), Crypto.keygen.recipient)
    streams.last.should eq(helper + ["dump", "partiduo_garde", "-"])
    File.read(File.join(root, "b.dump.age")).starts_with?("age-encryption.org/v1").should be_true
    system.dump_argv("partiduo_garde").should eq(helper + ["dump", "partiduo_garde", "-"])
    system.restore_argv("partiduo_garde").should eq(helper + ["restore", "partiduo_garde", "-"])
    system.media_archive_argv("garde", "/x", File.join(root, "b.files")).should eq(helper + ["media-archive", "garde", File.join(root, "b.files"), "-"])
    system.media_restore_argv("garde").should eq(helper + ["media-restore", "garde", "-"])
    expect_raises(PartiduoAgent::StepError, /hors du répertoire/) { system.media_archive_argv("garde", "/x", "/etc/liste") }
  end
end

# Production enregistrée : les flux ne lancent rien.
private class StreamRecordingProduction < PartiduoAgent::ProductionSystem
  def initialize(config : PartiduoAgent::Config, log : Proc(String, Nil), @streams : Array(Array(String)))
    super(config, log)
  end

  def run_stream(argv : Array(String), env = {} of String => String, input : IO? = nil, output : IO? = nil) : {Int32, String}
    @streams << argv
    {0, ""}
  end
end

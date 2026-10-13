# SPDX-License-Identifier: AGPL-3.0-or-later

require "../support/unit_helper"

# Sauvegardes, côté exécutant, sans base ni réseau : flux `age` du système,
# `store-serve` et client du stockage, configuration, commandes locales. Le
# format lui-même (clés, capsules, manifeste, signature, stockage) est vérifié
# par les specs du shard partiduo-backup.

private alias Crypto = PartiduoAdmin::BackupCrypto

private def scratch(name : String) : String
  path = File.join(Dir.tempdir, "partiduo-chf-#{name}-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(path)
  path
end

# Clé d'exploitation de spec : identité `age` post-quantique en clair dans
# un fichier, et son destinataire.
private def operator(directory : String, name : String = "exploitation") : {String, String}
  path = File.join(directory, "#{name}.age")
  Crypto.run!("age-keygen", ["-pq", "-o", path])
  {path, String.new(Crypto.run!("age-keygen", ["-y", path])).strip}
end

private def local_system(directory : String) : PartiduoAgent::LocalSystem
  config = PartiduoAgent::Config.new
  config.mode = PartiduoAgent::Mode::Local
  config.server_name = "loulou"
  config.state_dir = File.join(directory, "etat")
  config.backup_dir = File.join(directory, "sauvegardes")
  PartiduoAgent::LocalSystem.new(config, ->(_line : String) { nil })
end

private def manifest(recipient : String = "", mode : String = "none") : Crypto::Manifest
  Crypto::Manifest.new("loulou", "garde", "backup-20261009T101500Z", Time.utc(2026, 10, 9, 10, 15), mode, recipient,
    files: [Crypto::Entry.new("backup-20261009T101500Z.dump.age", 1234_i64, "a" * 64),
            Crypto::Entry.new("backup-20261009T101500Z.media.tar.gz.age", 56_i64, "b" * 64)])
end

describe "Sauvegardes : flux age de l'exécutant (D-CHF-013)" do
  it "chiffre un flux pour la clé de sauvegarde (age le relit) et refuse un octet changé ou une autre clé" do
    directory = scratch("flux")
    system = local_system(directory)
    plain = File.join(directory, "clair.bin")
    data = Random.new(7).random_bytes(300_000)
    File.write(plain, data)
    key = Crypto.keygen
    sealed = File.join(system.backup_root("garde"), "backup-20261009T101500Z.dump.age")
    system.seal_output(["cat", plain], sealed, key.recipient)
    File.read(sealed).starts_with?("age-encryption.org/v1").should be_true
    Dir.children(system.backup_root("garde")).should eq([File.basename(sealed)])
    Crypto.run!("age", ["-d", "-i", "-", sealed], "#{key.identity}\n").should eq(data)
    info = Crypto.check_structure(sealed)
    info["postquantum"].should eq("yes")
    system.verify_sealed(sealed, key.identity)

    copy = File.join(directory, "copie.bin")
    code, _, age = system.unseal_input(["dd", "of=#{copy}", "status=none"], sealed, key.identity)
    {code, age}.should eq({0, 0})
    File.read(copy).to_slice.should eq(data)
    # Un programme qui s'arrête avant la fin du flux (pg_restore --list) ne
    # coupe pas age : tout le fichier est lu et authentifié.
    code, _, age = system.unseal_input(["head", "-c", "10"], sealed, key.identity)
    {code, age}.should eq({0, 0})

    expect_raises(PartiduoAgent::StepError, /authentification refusée/) { system.verify_sealed(sealed, Crypto.keygen.identity) }
    File.open(sealed, "r+") do |file|
      file.seek(5000)
      byte = file.read_byte || raise "octet absent"
      file.seek(5000)
      file.write_byte(byte ^ 0x01_u8)
    end
    expect_raises(PartiduoAgent::StepError, /altérée/) { system.verify_sealed(sealed, key.identity) }
    _, _, age = system.unseal_input(["head", "-c", "10"], sealed, key.identity)
    age.should_not eq(0)
    system.pg_restore_list_sealed?(sealed, key.identity).should be_false
  end
end

describe "Sauvegardes : stockage de l'exécutant (D-CHF-024, D-CHF-025)" do
  it "sert le stockage par le protocole de store-serve, et le client le parle par une commande" do
    root = scratch("protocole")
    data = "contenu chiffré\x00\x01".to_slice
    locator = "loulou/garde/backup-20261009T101500Z.dump.age"
    output = IO::Memory.new
    PartiduoAgent::Tools.run(["store-serve", "--root", root, "--client", "loulou"], output, IO::Memory.new,
      IO::Memory.new("PUT #{locator} #{data.size}\n#{String.new(data)}")).should eq(0)
    output.to_s.should eq("OK #{Digest::SHA256.hexdigest(data)}\n")
    output = IO::Memory.new
    PartiduoAgent::Tools.run(["store-serve", "--root", root, "--client", "bibou"], output, IO::Memory.new,
      IO::Memory.new("GET #{locator}\n")).should eq(0)
    output.to_slice.should eq("OK #{data.size}\n".to_slice + data)
    output = IO::Memory.new
    PartiduoAgent::Tools.run(["store-serve", "--root", root, "--client", "bibou"], output, IO::Memory.new,
      IO::Memory.new("DEL #{locator}\n")).should eq(1)
    output.to_s.should start_with("ERR effacement refusé")
    output = IO::Memory.new
    PartiduoAgent::Tools.run(["store-serve", "--root", root, "--client", "bibou"], output, IO::Memory.new,
      IO::Memory.new("GET loulou/garde/../../etc/passwd\n")).should eq(1)
    output.to_s.should start_with("ERR emplacement invalide")

    # Client : une commande sans shell, qui répond selon le protocole.
    script = File.join(root, "faux-stockage")
    File.write(script, <<-SH, perm: 0o755)
      #!/bin/sh
      read command
      case "$command" in
        "LIST garde") printf 'OK 1\\n#{locator}\\n' ;;
        "STAT "*) echo "ERR absent" ;;
        "DEL "*) echo "ERR archive dans sa durée légale de conservation" ; exit 1 ;;
      esac
      SH
    store = PartiduoAgent::CommandStore.new([script])
    store.list("garde").map(&.to_s).should eq([locator])
    store.stat(AdminSpec.locator(locator)).should be_nil
    error = expect_raises(PartiduoAgent::StepError, /durée légale/) { store.delete(AdminSpec.locator(locator)) }
    error.code.should eq("refused")
  end

  it "exige en production un stockage : serveur de sauvegarde ou répertoire du serveur, pas les deux" do
    config = PartiduoAgent::Config.new
    config.token = "x"
    config.admin_url = "https://admin.partiduo.app"
    config.mode = PartiduoAgent::Mode::Production
    config.domain = "partiduo.app"
    config.server_name = "loulou"
    expect_raises(ArgumentError, /--store-command/) { config.validate! }
    config.store_command = "/usr/bin/ssh -T partiduo-store@quantas"
    config.validate!
    config.store_argv.should eq(["/usr/bin/ssh", "-T", "partiduo-store@quantas"])
    config.recipients_path.should eq("/usr/local/etc/partiduo-agent/exploitation.recipients")
    config.signing_key_path.should eq("/usr/local/etc/partiduo-agent/backup-signing.key")
    config.local_store?.should be_false
    # Sans serveur de sauvegarde : un répertoire du serveur (D-CHF-025).
    config.store_dir = "/var/backups/partiduo-store"
    expect_raises(ArgumentError, /s'excluent/) { config.validate! }
    config.store_command = ""
    config.validate!
    config.local_store?.should be_true
    config.store_path.should eq("/var/backups/partiduo-store")
    # Jamais dans les sauvegardes en préparation, que l'exécutant vide.
    config.store_dir = "/var/backups/partiduo/store"
    expect_raises(ArgumentError, /distinct du répertoire des sauvegardes/) { config.validate! }
    config.store_dir = "/var/backups"
    expect_raises(ArgumentError, /distinct du répertoire des sauvegardes/) { config.validate! }
    config.store_dir = "/var/backups/partiduo-store"
    config.server_name = "Lou Lou"
    expect_raises(ArgumentError, /nom de serveur/) { config.validate! }
  end
end

describe PartiduoAgent::Tools do
  it "déchiffre hors de Partiduo : clé de sauvegarde, capsule d'exploitation, capsule du cabinet" do
    directory = scratch("outils")
    identity_file, recipient = operator(directory)
    pair = AdminSpec::Keys.pair("a")
    key = Crypto.keygen
    data = Random.new(5).random_bytes(150_000)
    sealed = File.join(directory, "backup-20261009T101500Z.dump.age")
    File.write(sealed, Crypto.run!("age", ["-r", key.recipient], data))
    capsule = File.join(directory, "backup-20261009T101500Z.key.age")
    File.write(capsule, Crypto.capsule_for(key.identity, [recipient]))
    rsa = File.join(directory, "backup-20261009T101500Z.key.rsa")
    File.write(rsa, Crypto.capsule_for_cabinet(key.identity, Crypto::PublicKey.new(pair.public_pem)))
    key_file = File.join(directory, "backup.key")
    File.write(key_file, key.identity + "\n")
    passphrase = File.join(directory, "phrase")
    File.write(passphrase, AdminSpec::Keys::PASSPHRASE + "\n")
    output = IO::Memory.new
    error = IO::Memory.new

    PartiduoAgent::Tools.run(["inspect", sealed], output, error).should eq(0)
    output.to_s.should contain("post-quantique")
    {["--key", key_file], ["--capsule", capsule, "--identity", identity_file],
     ["--capsule", rsa, "--private-key", pair.private_path, "--passphrase-file", passphrase]}.each_with_index do |options, index|
      target = File.join(directory, "clair-#{index}")
      PartiduoAgent::Tools.run(["decrypt"] + options + [sealed, target], output, error).should eq(0), error.to_s
      File.read(target).to_slice.should eq(data)
    end
    other = AdminSpec::Keys.pair("b")
    PartiduoAgent::Tools.run(["decrypt", "--capsule", rsa, "--private-key", other.private_path, "--passphrase-file", passphrase,
                              sealed, File.join(directory, "refus")], output, error).should eq(1)
    File.exists?(File.join(directory, "refus")).should be_false
  end

  it "affiche un manifeste et vérifie sa signature avec les clés des serveurs" do
    directory = scratch("inspect")
    key = File.join(directory, "backup-signing.key")
    Crypto::Signature.generate(key, "loulou")
    path = File.join(directory, "backup-20261009T101500Z.manifest")
    File.write(path, manifest.to_s)
    File.write("#{path}.sig", Crypto::Signature.sign(manifest.to_s, key))
    signers = File.join(directory, "allowed_signers")
    File.write(signers, Crypto::Signature.allowed_signer("loulou", Crypto::Signature.public_line(key)) + "\n")
    output = IO::Memory.new
    PartiduoAgent::Tools.run(["inspect", path, "--signers", signers], output).should eq(0)
    output.to_s.should contain("signature valable : serveur loulou")
    File.write(path, manifest.to_s.sub("1234", "4321"))
    PartiduoAgent::Tools.run(["inspect", path, "--signers", signers], output).should eq(1)
    output.to_s.should contain("REFUSÉE")
  end
end

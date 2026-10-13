# SPDX-License-Identifier: AGPL-3.0-or-later

require "../support/unit_helper"

# Chiffrement des sauvegardes (D-CHF-013 à D-CHF-024), sans base ni réseau :
# clés de sauvegarde post-quantiques et fichiers `age`, capsules, manifeste
# signé, stockage hors du serveur, commandes locales. Les outils officiels
# (`age`, `age-keygen`, `age-inspect`, `ssh-keygen`, `openssl`) servent de
# seconde implémentation : ce que l'exécutant écrit, ils le relisent.

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

describe "Sauvegardes : clés et fichiers age (D-CHF-013, D-CHF-014)" do
  it "tire une clé de sauvegarde post-quantique, dont le destinataire est celui d'age-keygen" do
    key = Crypto.keygen
    Crypto.valid_identity?(key.identity).should be_true
    Crypto.valid_recipient?(key.recipient).should be_true
    key.identity.should start_with("AGE-SECRET-KEY-PQ-1")
    key.recipient.should start_with("age1pq1")
    Crypto.recipient_of(key.identity).should eq(key.recipient)
    Crypto.recipient_of("AGE-SECRET-KEY-1QQQQ").should be_nil
    Crypto.recipient_of("rien").should be_nil
    Crypto.keygen.identity.should_not eq(key.identity)
  end

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

  it "refuse comme sauvegarde un fichier age qui n'est pas pour une seule clé de sauvegarde post-quantique" do
    directory = scratch("structure")
    _, recipient = operator(directory)
    classic = String.new(Crypto.run!("age-keygen", [] of String)).lines.find!(&.starts_with?("AGE-SECRET-KEY-1"))
    classic_recipient = String.new(Crypto.run!("age-keygen", ["-y"], classic)).strip
    two = File.join(directory, "deux.age")
    File.write(two, Crypto.run!("age", ["-r", recipient, "-r", Crypto.keygen.recipient], "x"))
    expect_raises(Crypto::Error, /destinataire inattendu/) { Crypto.check_structure(two) }
    old = File.join(directory, "classique.age")
    File.write(old, Crypto.run!("age", ["-r", classic_recipient], "x"))
    expect_raises(Crypto::Error, /destinataire inattendu/) { Crypto.check_structure(old) }
    text = File.join(directory, "texte.age")
    File.write(text, "PDUOBAK ancien format")
    expect_raises(Crypto::Error) { Crypto.check_structure(text) }
  end
end

describe "Sauvegardes : capsules (D-CHF-014, D-CHF-015, D-CHF-020)" do
  it "capsule d'exploitation : chaque détenteur d'une clé d'exploitation l'ouvre avec age, personne d'autre" do
    directory = scratch("capsule")
    first, first_recipient = operator(directory, "premiere")
    second, second_recipient = operator(directory, "seconde")
    stranger, _ = operator(directory, "autre")
    key = Crypto.keygen
    capsule = File.join(directory, "backup.key.age")
    File.write(capsule, Crypto.capsule_for(key.identity, [first_recipient, second_recipient]))
    String.new(Crypto.run!("age", ["-d", "-i", first, capsule])).strip.should eq(key.identity)
    String.new(Crypto.run!("age", ["-d", "-i", second, capsule])).strip.should eq(key.identity)
    expect_raises(Crypto::Error) { Crypto.run!("age", ["-d", "-i", stranger, capsule]) }
    # Rotation : la capsule seule est re-chiffrée, avec les outils standard.
    third, third_recipient = operator(directory, "nouvelle")
    opened = Crypto.run!("age", ["-d", "-i", first, capsule])
    File.write(capsule, Crypto.run!("age", ["-r", third_recipient], opened))
    String.new(Crypto.run!("age", ["-d", "-i", third, capsule])).strip.should eq(key.identity)
    expect_raises(Crypto::Error) { Crypto.run!("age", ["-d", "-i", first, capsule]) }
  end

  it "n'accepte que des clés d'exploitation post-quantiques" do
    directory = scratch("destinataires")
    _, recipient = operator(directory)
    classic = String.new(Crypto.run!("age-keygen", ["-y"], String.new(Crypto.run!("age-keygen", [] of String)))).strip
    expect_raises(Crypto::Error, /age1pq1/) { Crypto.capsule_for(Crypto.keygen.identity, [classic]) }
    expect_raises(Crypto::Error, /aucune/) { Crypto.capsule_for(Crypto.keygen.identity, [] of String) }
    file = File.join(directory, "exploitation.recipients")
    File.write(file, "# clés d'exploitation\n#{recipient}\n\n#{recipient}\n")
    Crypto.read_recipients(file).should eq([recipient])
    File.write(file, "#{classic}\n")
    expect_raises(Crypto::Error, /age1pq1/) { Crypto.read_recipients(file) }
    expect_raises(Crypto::Error, /illisibles/) { Crypto.read_recipients(File.join(directory, "absent")) }
  end

  it "capsule du cabinet : RSA-OAEP, ouverte par openssl pkeyutl ou par la clé privée" do
    pair = AdminSpec::Keys.pair("a")
    key = Crypto.keygen
    capsule = Crypto.capsule_for_cabinet(key.identity, Crypto::PublicKey.new(pair.public_pem))
    path = File.join(scratch("cabinet"), "backup.key.rsa")
    File.write(path, capsule)
    opened = AdminSpec::Keys.openssl(["pkeyutl", "-decrypt", "-inkey", pair.private_path, "-passin", "pass:#{AdminSpec::Keys::PASSPHRASE}",
                                      "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256",
                                      "-pkeyopt", "rsa_mgf1_md:sha256", "-in", path])
    opened.should eq(key.identity)
    private_key = Crypto::PrivateKey.new(pair.private_pem, AdminSpec::Keys::PASSPHRASE)
    Crypto.open_cabinet_capsule(capsule, private_key).should eq(key.identity)
    other = Crypto::PrivateKey.new(AdminSpec::Keys.pair("b").private_pem, AdminSpec::Keys::PASSPHRASE)
    expect_raises(Crypto::Error) { Crypto.open_cabinet_capsule(capsule, other) }
  end

  it "n'accepte que des clés publiques RSA de 3072 bits au moins, empreinte identique à celle d'openssl" do
    a = AdminSpec::Keys.pair("a")
    key = Crypto::PublicKey.new(a.public_pem)
    key.bits.should eq(3072)
    der = AdminSpec::Keys.openssl(["pkey", "-pubin", "-in", a.public_path, "-outform", "DER"])
    key.fingerprint.should eq(Digest::SHA256.hexdigest(der.to_slice))
    Crypto::PrivateKey.new(a.private_pem, AdminSpec::Keys::PASSPHRASE).fingerprint.should eq(key.fingerprint)
    Crypto.display_fingerprint(key.fingerprint).split(' ').size.should eq(16)
    small = AdminSpec::Keys.pair("petite", 2048)
    expect_raises(Crypto::Error, /2048 bits/) { Crypto::PublicKey.new(small.public_pem) }
    expect_raises(Crypto::Error, /illisible/) { Crypto::PublicKey.new("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n") }
    ec = AdminSpec::Keys.openssl(["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"])
    ec_public = AdminSpec::Keys.openssl(["pkey", "-pubout"], IO::Memory.new(ec))
    expect_raises(Crypto::Error, /RSA seulement/) { Crypto::PublicKey.new(ec_public) }
  end
end

describe "Sauvegardes : manifeste signé (D-CHF-018)" do
  it "écrit un manifeste texte stable et le relit strictement" do
    recipient = Crypto.keygen.recipient
    text = manifest(recipient, "exploitation").to_s
    text.lines.first.should eq("partiduo-backup/2")
    text.should contain("server loulou\n")
    text.should contain("recipient #{recipient}\n")
    text.should contain("file backup-20261009T101500Z.dump.age 1234 #{"a" * 64}\n")
    parsed = Crypto::Manifest.parse(text)
    parsed.to_s.should eq(text)
    parsed.file?("backup-20261009T101500Z.media.tar.gz.age").try(&.size).should eq(56)
    parsed.taken_at.should eq(Time.utc(2026, 10, 9, 10, 15))

    expect_raises(Crypto::Error, /format/) { Crypto::Manifest.parse(text.sub("partiduo-backup/2", "partiduo-backup/1")) }
    expect_raises(Crypto::Error, /commande/) { Crypto::Manifest.parse(text + "commande rm -rf\n") }
    expect_raises(Crypto::Error, /destinataire/) { Crypto::Manifest.parse(text.sub("mode exploitation", "mode none")) }
    expect_raises(Crypto::Error, /en double/) { Crypto::Manifest.parse(text + "server bibou\n") }
    expect_raises(Crypto::Error, /server absent/) { Crypto::Manifest.parse(text.sub("server loulou\n", "")) }
    expect_raises(Crypto::Error) { Crypto::Manifest.parse(text.sub("1234", "beaucoup")) }
    Crypto::Manifest.parse(manifest.to_s).sealed?.should be_false
  end

  it "signe au format sshsig (ssh-keygen vérifie), pour ce serveur, à la date de prise, clé révoquée exclue" do
    directory = scratch("signature")
    key = File.join(directory, "backup-signing.key")
    Crypto::Signature.generate(key, "loulou")
    (File.info(key).permissions.value & 0o077).should eq(0)
    public_line = Crypto::Signature.public_line(key)
    public_line.should start_with("ssh-ed25519 ")
    listed = String.new(Crypto.run!("ssh-keygen", ["-l", "-f", "#{key}.pub"])).split(' ')[1]
    Crypto::Signature.fingerprint(public_line).should eq(listed)

    text = manifest.to_s
    signature = Crypto::Signature.sign(text, key)
    signature.should start_with("-----BEGIN SSH SIGNATURE-----")
    taken = Time.utc(2026, 10, 9, 10, 15)
    signers = [Crypto::Signature.allowed_signer("loulou", public_line)]
    Crypto::Signature.verify(text, signature, signers, "loulou", taken).should be_true
    # Un autre serveur, un texte changé, une signature d'une autre clé.
    Crypto::Signature.verify(text, signature, signers, "bibou", taken).should be_false
    Crypto::Signature.verify(text.sub("1234", "1235"), signature, signers, "loulou", taken).should be_false
    other = File.join(directory, "autre.key")
    Crypto::Signature.generate(other, "bibou")
    Crypto::Signature.verify(text, Crypto::Signature.sign(text, other), signers, "loulou", taken).should be_false
    Crypto::Signature.verify(text, signature, [] of String, "loulou", taken).should be_false
    # Révoquée après la prise : vaut encore ; avant : refusée.
    after = [Crypto::Signature.allowed_signer("loulou", public_line, taken + 1.day)]
    Crypto::Signature.verify(text, signature, after, "loulou", taken).should be_true
    before = [Crypto::Signature.allowed_signer("loulou", public_line, taken - 1.day)]
    Crypto::Signature.verify(text, signature, before, "loulou", taken).should be_false

    Crypto::Signature.normalize("ssh-ed25519 #{public_line.split(' ')[1]} commentaire").should eq(public_line)
    Crypto::Signature.normalize("ssh-rsa AAAAB3NzaC1yc2E").should be_nil
    Crypto::Signature.normalize("ssh-ed25519 pas;du;base64").should be_nil
  end
end

describe "Sauvegardes : stockage hors du serveur (D-CHF-024)" do
  it "n'accepte que des emplacements d'une liste fermée de noms" do
    locator = AdminSpec.locator("loulou/garde/backup-20261009T101500Z.dump.age")
    locator.stem.should eq("backup-20261009T101500Z")
    locator.taken_at.should eq(Time.utc(2026, 10, 9, 10, 15))
    locator.sibling(".manifest.sig").to_s.should eq("loulou/garde/backup-20261009T101500Z.manifest.sig")
    ["loulou/garde/backup-20261009T101500Z.dump.age", "loulou/garde/archive-20161009T101500Z.media.tar.gz",
     "bi.quimeo.net/garde/pre-restore-20261009T101500Z.key.rsa"].each do |value|
      PartiduoAgent::Locator.parse?(value).should_not be_nil
    end
    ["../garde/backup-20261009T101500Z.dump", "loulou/../backup-20261009T101500Z.dump", "loulou/garde/b.dump",
     "loulou/garde/backup-20261009T101500Z.dump.enc", "loulou/admin/backup-20261009T101500Z.dump", "loulou/garde",
     "/var/backups/garde/backup-20261009T101500Z.dump", "lou..lou/garde/backup-20261009T101500Z.dump",
     "loulou/garde/backup-20261009T101500Z.sh"].each do |value|
      PartiduoAgent::Locator.parse?(value).should be_nil
    end
  end

  it "écrit une seule fois, sous le répertoire du serveur client ; lit tout ; garde les archives dans leur durée légale" do
    root = scratch("stockage")
    loulou = PartiduoAgent::StoreRoot.new(root, "loulou")
    bibou = PartiduoAgent::StoreRoot.new(root, "bibou")
    locator = AdminSpec.locator("loulou/garde/backup-20261009T101500Z.dump.age")
    data = Random.new(3).random_bytes(200_000)
    sha = loulou.put(locator, IO::Memory.new(data), data.size.to_i64)
    sha.should eq(Digest::SHA256.hexdigest(data))
    loulou.stat(locator).should eq({data.size.to_i64, sha})
    expect_raises(PartiduoAgent::StoreRoot::Error, /existe déjà/) { loulou.put(locator, IO::Memory.new(data), data.size.to_i64) }
    expect_raises(PartiduoAgent::StoreRoot::Error, /refusée hors de bibou/) { bibou.put(locator.sibling(".manifest"), IO::Memory.new("x"), 1_i64) }
    expect_raises(PartiduoAgent::StoreRoot::Error, /interrompu/) { loulou.put(locator.sibling(".manifest"), IO::Memory.new("x"), 5_i64) }
    loulou.stat(locator.sibling(".manifest")).should be_nil
    Dir.glob(File.join(root, "**", "*.part")).should be_empty

    # Restauration sur un autre serveur : bibou lit ce que loulou a pris.
    copy = IO::Memory.new
    bibou.get(locator, copy)
    copy.to_slice.should eq(data)
    bibou.list("garde").map(&.to_s).should eq([locator.to_s])
    expect_raises(PartiduoAgent::StoreRoot::Error, /refusé hors de bibou/) { bibou.delete(locator) }

    young = AdminSpec.locator("loulou/garde/archive-20250101T000000Z.dump.age")
    old = AdminSpec.locator("loulou/garde/archive-20150101T000000Z.dump.age")
    [young, old].each { |archive| loulou.put(archive, IO::Memory.new("a"), 1_i64) }
    expect_raises(PartiduoAgent::StoreRoot::Error, /durée légale/) { loulou.delete(young, Time.utc(2026, 10, 9)) }
    loulou.delete(old, Time.utc(2026, 10, 9))
    loulou.delete(locator)
    loulou.list("garde").map(&.to_s).should eq([young.to_s])
  end

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

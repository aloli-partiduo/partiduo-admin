# SPDX-License-Identifier: AGPL-3.0-or-later

require "option_parser"
require "base64"

module PartiduoAgent
  # Commandes locales de l'exécutant, sans administration (D-CHF-020,
  # D-CHF-024) :
  #
  # * `partiduo-agent decrypt` : déchiffre une sauvegarde hors de Partiduo,
  #   avec sa clé de sauvegarde, ou en ouvrant sa capsule (clé
  #   d'exploitation ou clé privée du cabinet) ;
  # * `partiduo-agent inspect` : structure d'un fichier `age`, ou manifeste
  #   d'une sauvegarde et, avec les clés de signature, sa vérification ;
  # * `partiduo-agent store-serve` : le stockage, côté serveur de sauvegarde
  #   (commande forcée de `authorized_keys`).
  #
  # `age` et `openssl` suffisent aussi, sans Partiduo (README).
  module Tools
    COMMANDS = %w[decrypt inspect store-serve]

    def self.command?(args : Array(String)) : Bool
      COMMANDS.includes?(args.first?)
    end

    # Rend le code de sortie.
    def self.run(args : Array(String), output : IO = STDOUT, error : IO = STDERR, input : IO = STDIN) : Int32
      case args.first
      when "decrypt"     then decrypt(args[1..], output)
      when "inspect"     then inspect(args[1..], output)
      when "store-serve" then store_serve(args[1..], input, output)
      else                    2
      end
    rescue ex : BackupCrypto::Error | StepError | File::Error | OptionParser::Exception | ArgumentError | StoreRoot::Error
      error.puts "partiduo-agent : #{ex.message}"
      1
    end

    record DecryptOptions, key_file : String = "", capsule : String = "", identity_file : String = "",
      private_key : String = "", passphrase_file : String = ""

    def self.decrypt(args : Array(String), output : IO) : Int32
      options = DecryptOptions.new
      files = [] of String
      OptionParser.parse(args) do |parser|
        parser.banner = "Usage : partiduo-agent decrypt (--key F | --capsule C (--identity F | --private-key PEM " \
                        "[--passphrase-file F])) SOURCE.age DESTINATION"
        parser.on("--key F", "clé de sauvegarde (AGE-SECRET-KEY-PQ-1…)") { |value| options = options.copy_with(key_file: value) }
        parser.on("--capsule C", "capsule de la sauvegarde (….key.age ou ….key.rsa)") { |value| options = options.copy_with(capsule: value) }
        parser.on("--identity F", "clé d'exploitation (fichier d'identité age, chiffré ou non)") do |value|
          options = options.copy_with(identity_file: value)
        end
        parser.on("--private-key PEM", "clé privée du cabinet (PKCS#8, chiffrée ou non)") { |value| options = options.copy_with(private_key: value) }
        parser.on("--passphrase-file F", "phrase de passe de la clé privée (sinon : PARTIDUO_KEY_PASSPHRASE)") do |value|
          options = options.copy_with(passphrase_file: value)
        end
        parser.unknown_args { |rest| files = rest }
      end
      raise ArgumentError.new("SOURCE et DESTINATION attendus") unless files.size == 2
      source, destination = files
      identity = backup_identity(options)
      raise BackupCrypto::Error.new("clé de sauvegarde illisible") unless BackupCrypto.valid_identity?(identity)
      partial = "#{destination}.part"
      code, _, errors = BackupCrypto.run("age", ["-d", "-i", "-", "-o", partial, source], "#{identity}\n")
      raise BackupCrypto::Error.new("#{source} : déchiffrement refusé (#{errors.strip.lines.first?})") unless code == 0
      File.rename(partial, destination)
      output.puts "#{destination} : déchiffré et authentifié"
      0
    ensure
      File.delete(partial) if partial && File.exists?(partial)
    end

    # Clé de sauvegarde : donnée, ou sortie de sa capsule par la clé privée
    # du cabinet ou par une clé d'exploitation.
    private def self.backup_identity(options : DecryptOptions) : String
      return File.read(options.key_file).strip unless options.key_file.empty?
      raise ArgumentError.new("indiquez --key, ou --capsule avec --identity ou --private-key") if options.capsule.empty?
      unless options.private_key.empty?
        passphrase = options.passphrase_file.empty? ? (ENV["PARTIDUO_KEY_PASSPHRASE"]? || "") : File.read(options.passphrase_file).chomp
        key = BackupCrypto::PrivateKey.new(File.read(options.private_key), passphrase)
        return BackupCrypto.open_cabinet_capsule(File.read(options.capsule).to_slice, key)
      end
      raise ArgumentError.new("indiquez --identity ou --private-key avec --capsule") if options.identity_file.empty?
      # `age` demande lui-même la phrase de passe d'une identité chiffrée.
      opened = IO::Memory.new
      status = Process.run(BackupCrypto.tool("age"), ["-d", "-i", options.identity_file, options.capsule],
        input: Process::Redirect::Inherit, output: opened, error: Process::Redirect::Inherit)
      raise BackupCrypto::Error.new("capsule non ouverte par cette clé d'exploitation") unless status.success?
      opened.to_s.strip
    end

    def self.inspect(args : Array(String), output : IO) : Int32
      signers = signature = ""
      files = [] of String
      OptionParser.parse(args) do |parser|
        parser.banner = "Usage : partiduo-agent inspect FICHIER.age | FICHIER.manifest [--signers F] [--signature F]"
        parser.on("--signers F", "fichier allowed_signers des serveurs (ssh-keygen)") { |value| signers = value }
        parser.on("--signature F", "signature du manifeste (défaut : FICHIER.manifest.sig)") { |value| signature = value }
        parser.unknown_args { |rest| files = rest }
      end
      raise ArgumentError.new("un fichier attendu") unless files.size == 1
      path = files.first
      unless path.ends_with?(BackupCrypto::MANIFEST)
        info = BackupCrypto.check_structure(path)
        output.puts "age v1, post-quantique, destinataire #{BackupCrypto::STANZA}"
        output.puts "taille du contenu : #{info["sizes"]?.try(&.["max_payload"]?)} octets"
        return 0
      end
      text = File.read(path)
      manifest = BackupCrypto::Manifest.parse(text)
      output.puts text
      return 0 if signers.empty?
      signed = File.read(signature.presence || "#{path}.sig")
      allowed = File.read_lines(signers).reject { |line| line.strip.empty? || line.starts_with?('#') }
      if BackupCrypto::Signature.verify(text, signed, allowed, manifest.server, manifest.taken_at)
        output.puts "signature valable : serveur #{manifest.server}"
        0
      else
        output.puts "signature REFUSÉE pour le serveur #{manifest.server}"
        1
      end
    end

    # Côté serveur de sauvegarde : une commande du protocole du stockage.
    def self.store_serve(args : Array(String), input : IO, output : IO) : Int32
      root = client = ""
      OptionParser.parse(args) do |parser|
        parser.banner = "Usage : partiduo-agent store-serve --root RÉP --client SERVEUR"
        parser.on("--root RÉP", "racine du stockage") { |value| root = value }
        parser.on("--client SERVEUR", "serveur qui se connecte (écrit et efface sous SERVEUR/ seulement)") { |value| client = value }
      end
      raise ArgumentError.new("--root et --client attendus") if root.empty? || client.empty?
      raise ArgumentError.new("racine du stockage absente : #{root}") unless Dir.exists?(root)
      StoreServer.new(StoreRoot.new(root, client), input, output).serve
    end
  end
end

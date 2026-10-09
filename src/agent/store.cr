# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module PartiduoAgent
  # Emplacement d'un fichier de sauvegarde dans le stockage (D-CHF-024) :
  # `<serveur>/<sous-domaine>/<fichier>`, le serveur étant celui qui a pris
  # la sauvegarde. Les noms de fichiers forment une liste fermée.
  record Locator, server : String, slug : String, name : String do
    SERVER = /\A[a-z0-9][a-z0-9.-]{0,63}\z/
    NAME   = /\A((?:backup|archive|pre-restore)-(\d{8}T\d{6}Z))\.(dump(\.age)?|media\.tar\.gz(\.age)?|key\.age|key\.rsa|manifest(\.sig)?)\z/

    def self.valid_server?(server : String) : Bool
      SERVER.matches?(server) && !server.includes?("..")
    end

    def self.parse?(value : String) : Locator?
      parts = value.split('/')
      return unless parts.size == 3
      server, slug, name = parts
      return unless valid_server?(server) && PartiduoAdmin::Protocol.valid_slug?(slug) && NAME.matches?(name)
      new(server, slug, name)
    end

    def to_s(io : IO) : Nil
      io << server << '/' << slug << '/' << name
    end

    # `backup-20261009T101500Z` : préfixe commun aux fichiers d'une sauvegarde.
    def stem : String
      NAME.match!(name)[1]
    end

    def taken_at : Time
      Time.parse(NAME.match!(name)[2], "%Y%m%dT%H%M%SZ", Time::Location::UTC)
    end

    def sibling(suffix : String) : Locator
      Locator.new(server, slug, "#{stem}#{suffix}")
    end
  end

  # Stockage des sauvegardes, hors du serveur de production : un
  # répertoire (`DirStore`, développement), ou le serveur de sauvegarde
  # joint par une commande (`CommandStore`, en production
  # `ssh … partiduo-store@quantas`), où `partiduo-agent store-serve` sert un
  # `StoreRoot`. Écriture une seule fois, jamais d'écrasement.
  abstract class Store
    # Envoie `local` ; rend le SHA-256 calculé par le stockage.
    abstract def put(local : String, locator : Locator) : String
    # Ramène `locator` dans `local` (fichier partiel renommé à la fin).
    abstract def fetch(locator : Locator, local : String) : Nil
    # Taille et SHA-256, ou `nil` si le fichier n'existe pas.
    abstract def stat(locator : Locator) : {Int64, String}?
    # Fichiers d'un dossier, tous serveurs confondus.
    abstract def list(slug : String) : Array(Locator)
    abstract def delete(locator : Locator) : Nil

    # Écrit `local` par un fichier partiel renommé à la fin. Lisible par le
    # compte des instances, qui relit une sauvegarde en clair par
    # l'enveloppe de sudo (`restore`, `media-restore`) : le répertoire de
    # sauvegarde d'un dossier (0770, instances et exécutant) en garde
    # l'accès.
    def self.receive(local : String, & : File ->) : Nil
      Dir.mkdir_p(File.dirname(local))
      partial = "#{local}.part"
      begin
        File.open(partial, "wb", perm: 0o644) { |file| yield file }
        File.rename(partial, local)
      ensure
        File.delete(partial) if File.exists?(partial)
      end
    end
  end

  # Racine du stockage, côté serveur de sauvegarde. `client` : le serveur
  # qui s'y connecte ; il n'écrit et n'efface que sous `<client>/`, lit tout
  # (restauration sur un autre serveur, D-CHF-016). Une archive dans sa
  # durée légale n'est jamais effacée (D-CRA-007), quel que soit le client.
  class StoreRoot
    class Error < Exception
    end

    getter root : String
    getter client : String

    def initialize(@root : String, @client : String)
      raise Error.new("serveur client invalide : #{@client}") unless Locator.valid_server?(@client)
    end

    def path(locator : Locator) : String
      File.join(root, locator.server, locator.slug, locator.name)
    end

    def put(locator : Locator, input : IO, size : Int64) : String
      raise Error.new("écriture refusée hors de #{client}/ : #{locator}") unless locator.server == client
      target = path(locator)
      raise Error.new("existe déjà : #{locator}") if File.exists?(target)
      Dir.mkdir_p(File.dirname(target), 0o750)
      partial = "#{target}.#{Random::Secure.hex(6)}.part"
      digest = Digest::SHA256.new
      begin
        File.open(partial, "wb", perm: 0o640) do |file|
          buffer = Bytes.new(65_536)
          remaining = size
          while remaining > 0
            count = input.read(buffer[0, Math.min(buffer.size.to_i64, remaining).to_i32])
            raise Error.new("envoi interrompu : #{locator}") if count == 0
            file.write(buffer[0, count])
            digest.update(buffer[0, count])
            remaining -= count
          end
          file.fsync
        end
        # Lien physique : échoue si le fichier est apparu entre-temps.
        File.link(partial, target)
      rescue File::AlreadyExistsError
        raise Error.new("existe déjà : #{locator}")
      ensure
        File.delete(partial) if File.exists?(partial)
      end
      digest.hexfinal
    end

    def size(locator : Locator) : Int64?
      target = path(locator)
      File.file?(target) ? File.size(target).to_i64 : nil
    end

    def get(locator : Locator, output : IO) : Nil
      File.open(path(locator), "rb") { |file| IO.copy(file, output) }
    rescue File::Error
      raise Error.new("absent : #{locator}")
    end

    def stat(locator : Locator) : {Int64, String}?
      target = path(locator)
      return unless File.file?(target)
      {File.size(target).to_i64, Digest::SHA256.new.file(target).hexfinal}
    end

    def list(slug : String) : Array(Locator)
      raise Error.new("sous-domaine invalide : #{slug}") unless PartiduoAdmin::Protocol.valid_slug?(slug)
      Dir.glob(File.join(root, "*", slug, "*")).compact_map do |file|
        Locator.parse?(file.lchop(root).lchop('/'))
      end.sort_by!(&.to_s)
    end

    def delete(locator : Locator, now : Time = Time.utc) : Nil
      raise Error.new("effacement refusé hors de #{client}/ : #{locator}") unless locator.server == client
      if taken = PartiduoAdmin::Protocol.archive_taken_at(locator.name)
        if taken.shift(years: PartiduoAdmin::Protocol::ARCHIVE_RETENTION_YEARS) > now
          raise Error.new("archive dans sa durée légale de conservation : #{locator.name}")
        end
      end
      target = path(locator)
      File.delete(target) if File.exists?(target)
    end
  end

  # `partiduo-agent store-serve` : une commande par connexion, sur l'entrée
  # et la sortie standard (commande forcée de `authorized_keys`).
  #
  # * `PUT <emplacement> <taille>` puis les octets → `OK <sha256>`
  # * `GET <emplacement>` → `OK <taille>` puis les octets
  # * `STAT <emplacement>` → `OK <taille> <sha256>` ou `ERR absent`
  # * `LIST <sous-domaine>` → `OK <n>` puis n emplacements
  # * `DEL <emplacement>` → `OK`
  #
  # Toute erreur : `ERR <motif>`.
  class StoreServer
    def initialize(@root : StoreRoot, @input : IO, @output : IO)
    end

    def serve : Int32
      line = @input.gets(chomp: true) || return 0
      verb, _, rest = line.partition(' ')
      case verb
      when "PUT"
        target, _, size = rest.partition(' ')
        bytes = size.to_i64? || raise StoreRoot::Error.new("taille invalide")
        reply("OK #{@root.put(locator!(target), @input, bytes)}")
      when "GET"
        locator = locator!(rest)
        size = @root.size(locator) || raise StoreRoot::Error.new("absent : #{locator}")
        reply("OK #{size}")
        @root.get(locator, @output)
      when "STAT"
        if found = @root.stat(locator!(rest))
          reply("OK #{found[0]} #{found[1]}")
        else
          reply("ERR absent")
        end
      when "LIST"
        found = @root.list(rest)
        reply("OK #{found.size}")
        found.each { |locator| @output << locator << '\n' }
      when "DEL"
        @root.delete(locator!(rest))
        reply("OK")
      else
        raise StoreRoot::Error.new("commande inconnue")
      end
      @output.flush
      0
    rescue ex : StoreRoot::Error | IO::Error
      reply("ERR #{ex.message.to_s.gsub('\n', ' ')}")
      @output.flush rescue nil
      1
    end

    private def locator!(value : String) : Locator
      Locator.parse?(value) || raise StoreRoot::Error.new("emplacement invalide : #{value}")
    end

    private def reply(line : String) : Nil
      @output << line << '\n'
    end
  end

  # Stockage dans un répertoire de la machine (développement, specs).
  class DirStore < Store
    getter root : StoreRoot

    def initialize(directory : String, client : String)
      @root = begin
        StoreRoot.new(directory, client)
      rescue ex : StoreRoot::Error
        raise StepError.new("stockage : #{ex.message}", "usage")
      end
    end

    def put(local : String, locator : Locator) : String
      File.open(local, "rb") { |file| @root.put(locator, file, File.size(local).to_i64) }
    rescue ex : StoreRoot::Error | File::Error
      raise StepError.new("stockage : #{ex.message}")
    end

    def fetch(locator : Locator, local : String) : Nil
      Store.receive(local) { |file| @root.get(locator, file) }
    rescue ex : StoreRoot::Error
      raise StepError.new("stockage : #{ex.message}")
    end

    def stat(locator : Locator) : {Int64, String}?
      @root.stat(locator)
    end

    def list(slug : String) : Array(Locator)
      @root.list(slug)
    rescue ex : StoreRoot::Error
      raise StepError.new("stockage : #{ex.message}")
    end

    def delete(locator : Locator) : Nil
      @root.delete(locator)
    rescue ex : StoreRoot::Error
      raise StepError.new("stockage : #{ex.message}", "refused")
    end
  end

  # Stockage joint par une commande (sans shell) qui parle le protocole de
  # `StoreServer` : en production, `ssh` vers le serveur de sauvegarde, dont
  # `authorized_keys` force `partiduo-agent store-serve`.
  class CommandStore < Store
    def initialize(@argv : Array(String))
      raise StepError.new("commande du stockage vide", "usage") if @argv.empty?
    end

    def put(local : String, locator : Locator) : String
      size = File.size(local).to_i64
      reply = session("PUT #{locator} #{size}", payload: local) { |output| ok!(output, locator) }
      sha = reply.strip
      raise StepError.new("stockage : réponse invalide à l'envoi de #{locator}") unless sha.matches?(/\A[0-9a-f]{64}\z/)
      sha
    end

    def fetch(locator : Locator, local : String) : Nil
      session("GET #{locator}") do |output|
        size = ok!(output, locator).to_i64? || raise StepError.new("stockage : taille illisible pour #{locator}")
        Store.receive(local) do |file|
          copied = IO.copy(output, file, size)
          raise StepError.new("stockage : #{locator} tronqué") unless copied == size
        end
      end
    end

    def stat(locator : Locator) : {Int64, String}?
      session("STAT #{locator}") do |output|
        line = output.gets(chomp: true) || raise StepError.new("stockage injoignable")
        next if line == "ERR absent"
        parts = line.split(' ')
        raise StepError.new("stockage : #{line}") unless parts.size == 3 && parts[0] == "OK"
        {parts[1].to_i64, parts[2]}
      end
    end

    def list(slug : String) : Array(Locator)
      session("LIST #{slug}") do |output|
        count = ok!(output, slug).to_i? || 0
        Array(Locator).new(count) do
          line = output.gets(chomp: true) || raise StepError.new("stockage : liste tronquée")
          Locator.parse?(line) || raise StepError.new("stockage : emplacement illisible #{line}")
        end
      end
    end

    def delete(locator : Locator) : Nil
      session("DEL #{locator}") { |output| ok!(output, locator) }
    end

    private def ok!(output : IO, subject) : String
      line = output.gets(chomp: true) || raise StepError.new("stockage injoignable (#{subject})")
      raise StepError.new("stockage : #{line.lchop("ERR ")}", line.includes?("durée légale") ? "refused" : "failed") unless line.starts_with?("OK")
      line.lchop("OK").lstrip
    end

    private def session(command : String, payload : String? = nil, & : IO -> T) : T forall T
      errors = IO::Memory.new
      process = Process.new(@argv[0], @argv[1..], input: Process::Redirect::Pipe, output: Process::Redirect::Pipe,
        error: errors)
      begin
        process.input << command << '\n'
        begin
          File.open(payload, "rb") { |file| IO.copy(file, process.input) } if payload
          process.input.close
        rescue IO::Error
          # Le stockage a refusé avant la fin de l'envoi : sa réponse dit
          # pourquoi.
        end
        result = yield process.output
        process.output.close
        status = process.wait
        raise StepError.new("stockage : commande en échec (code #{status.exit_code? || -1}) #{errors.to_s.strip[0, 200]?}") unless status.success? || command.starts_with?("STAT")
        result
      ensure
        unless process.terminated?
          process.terminate rescue nil
        end
      end
    rescue ex : IO::Error | File::Error
      raise StepError.new("stockage : #{ex.message} #{errors.try(&.to_s.strip[0, 200]?)}")
    end
  end
end

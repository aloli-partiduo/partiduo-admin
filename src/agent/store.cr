# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"
require "partiduo-backup"

module PartiduoAgent
  # Emplacements, racine du stockage et protocole de `store-serve` : shard
  # partiduo-backup (D-CHF-024).
  alias Locator = PartiduoBackup::Locator
  alias StoreRoot = PartiduoBackup::StoreRoot
  alias StoreServer = PartiduoBackup::StoreServer

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

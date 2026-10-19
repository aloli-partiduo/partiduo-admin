# SPDX-License-Identifier: AGPL-3.0-or-later

require "api-ovh"
require "json"
require "log"

module PartiduoAdmin
  # DNS des dossiers (ADR-013) : l'administration seule pose, bascule et
  # efface le nom de chaque dossier, un `CNAME` vers le nom de son serveur ;
  # aucun exécutant n'a de clé DNS. Réglé par l'environnement :
  #
  # * `PARTIDUO_ADMIN_DNS_CREDENTIALS_FILE` : clé OVH de l'administration
  #   (JSON : `application_key`, `application_secret`, `consumer_key`,
  #   `endpoint` facultatif, `eu` par défaut), restreinte aux
  #   enregistrements de la zone et aux adresses de ce serveur (D2) ;
  # * `PARTIDUO_ADMIN_DNS_ZONES` : zones gérées, séparées par des virgules.
  #
  # Une zone non gérée (joker de la zone de test, D8) n'est jamais
  # modifiée : `dns_state` reste vide.
  module Dns
    Log = ::Log.for("partiduo_admin.dns")

    # Durée de vie des noms des dossiers (D3).
    TTL = 300

    # `pending` : à poser, basculer ou effacer ; `ok` : à jour ;
    # `removed` : effacé avec le dossier ; `error` : refus ou panne, repris
    # par la planification.
    STATES = %w[pending ok removed error]

    class Error < Exception
    end

    record Entry, id : Int64, field_type : String, target : String

    # Fournisseur de la zone (remplaçable dans les specs).
    abstract class Provider
      abstract def entries(zone : String, sub_domain : String) : Array(Entry)
      abstract def create(zone : String, sub_domain : String, target : String, ttl : Int32) : Int64
      abstract def update(zone : String, id : Int64, target : String, ttl : Int32) : Nil
      abstract def delete(zone : String, id : Int64) : Nil
      abstract def refresh(zone : String) : Nil
    end

    class OvhProvider < Provider
      def initialize(@client : OvhApi::Client)
      end

      def self.from_file(path : String) : OvhProvider
        data = JSON.parse(File.read(path))
        endpoint = data["endpoint"]?.try(&.as_s?).presence || "eu"
        new(OvhApi::Client.new(
          application_key: data["application_key"].as_s,
          application_secret: data["application_secret"].as_s,
          consumer_key: data["consumer_key"].as_s,
          endpoint: OvhApi::ENDPOINTS.keys.find { |key| key.to_s == endpoint } || endpoint))
      end

      def entries(zone : String, sub_domain : String) : Array(Entry)
        @client.domains.records(zone, sub_domain: sub_domain).map do |id|
          record = @client.domains.record(zone, id)
          Entry.new(record.id, record.field_type, record.target)
        end
      end

      def create(zone : String, sub_domain : String, target : String, ttl : Int32) : Int64
        @client.domains.create_record(zone, "CNAME", sub_domain, target, ttl: ttl).id
      end

      def update(zone : String, id : Int64, target : String, ttl : Int32) : Nil
        @client.domains.update_record(zone, id, target: target, ttl: ttl)
      end

      def delete(zone : String, id : Int64) : Nil
        @client.domains.delete_record(zone, id)
      end

      def refresh(zone : String) : Nil
        @client.domains.refresh(zone)
      end
    end

    @@provider : Provider? = nil
    @@loaded = false

    # Fournisseur réglé ; `nil` sans fichier de clé (aucune zone gérée).
    def self.provider : Provider?
      return @@provider if @@loaded
      @@loaded = true
      path = ENV["PARTIDUO_ADMIN_DNS_CREDENTIALS_FILE"]?.presence
      # Aucune zone gérée (zone de test à joker) : la clé n'est pas posée.
      @@provider = path && !zones.empty? ? OvhProvider.from_file(path) : nil
    rescue ex : File::Error | JSON::ParseException | KeyError | TypeCastError
      Log.error { "clé DNS illisible (#{path}) : #{ex.message}" }
      @@provider = nil
    end

    # Specs : fournisseur et zones imposés.
    def self.provider=(provider : Provider?) : Nil
      @@provider = provider
      @@loaded = true
    end

    class_property zones_override : Array(String)? = nil

    def self.zones : Array(String)
      zones_override || (ENV["PARTIDUO_ADMIN_DNS_ZONES"]? || "").split(',').map(&.strip.downcase).reject(&.empty?)
    end

    # Le nom de ce dossier est-il tenu par l'administration ?
    def self.managed?(dossier : Dossier) : Bool
      !provider.nil? && zones.includes?(dossier.zone.downcase)
    end

    # Cible du `CNAME` : le nom du serveur, absolu (point final).
    def self.target_for(server : Server) : String
      "#{server.hostname.to_s.strip.downcase.rchop('.')}."
    end

    # Nom attendu par l'exécutant avant le certificat (D5) ; `nil` hors
    # zone gérée.
    def self.wait_target(dossier : Dossier) : String?
      managed?(dossier) ? dossier.server.try { |server| target_for(server).rchop('.') } : nil
    end

    private def self.same?(left : String, right : String) : Bool
      left.downcase.rchop('.') == right.downcase.rchop('.')
    end

    # Met le nom du dossier en accord avec son état : `CNAME` vers son
    # serveur, ou effacé une fois le dossier supprimé. Ne vise que
    # l'enregistrement que l'administration a créé ; un autre enregistrement
    # pour ce nom bloque (rien n'est écrasé). Vrai si le nom est à jour.
    def self.sync(dossier : Dossier, actor : User? = nil, now : Time = Config.now) : Bool
      return true unless managed?(dossier)
      provider = self.provider.not_nil!
      zone = dossier.zone.downcase
      sub_domain = dossier.slug.to_s
      begin
        entries = provider.entries(zone, sub_domain)
        own = entries.find { |entry| entry.id == dossier.dns_record_id }
        others = entries.reject { |entry| entry.id == dossier.dns_record_id }
        if dossier.state == "deleted"
          if own
            provider.delete(zone, own.id)
            provider.refresh(zone)
            Audit.log(actor, "dns.delete", target: dossier, detail: {"name" => dossier.host, "record" => own.id.to_s},
              actor_label: actor ? nil : "system")
          end
          dossier.dns_record_id = nil
          return settle(dossier, "removed", now)
        end
        unless Protocol.valid_slug?(sub_domain)
          raise Error.new("sous-domaine refusé : #{sub_domain}")
        end
        server = dossier.server
        if server.nil? || !server.active?
          raise Error.new("serveur du dossier absent ou inactif")
        end
        target = target_for(server)
        unless others.empty?
          described = others.map { |entry| "#{entry.field_type} #{entry.target}" }.join(", ")
          raise Error.new("nom déjà présent dans la zone, non créé par l'administration : #{described}")
        end
        if own.nil?
          id = provider.create(zone, sub_domain, target, TTL)
          provider.refresh(zone)
          dossier.dns_record_id = id
          Audit.log(actor, "dns.create", target: dossier, detail: {"name" => dossier.host, "target" => target, "record" => id.to_s},
            actor_label: actor ? nil : "system")
        elsif !same?(own.target, target)
          provider.update(zone, own.id, target, TTL)
          provider.refresh(zone)
          Audit.log(actor, "dns.update", target: dossier,
            detail: {"name" => dossier.host, "from" => own.target, "target" => target, "record" => own.id.to_s},
            actor_label: actor ? nil : "system")
        end
        settle(dossier, "ok", now)
      rescue ex : Error | OvhApi::Error | IO::Error | Socket::Error | JSON::ParseException
        Log.warn { "DNS de #{dossier.host} : #{ex.message}" }
        dossier.dns_state = "error"
        dossier.save!
        Alerts.open("dns", "danger", dossier: dossier, detail: ex.message.to_s[0, 250]? || "", now: now)
        false
      end
    end

    private def self.settle(dossier : Dossier, state : String, now : Time) : Bool
      dossier.dns_state = state
      dossier.save!
      Alerts.resolve("dns", dossier: dossier, now: now)
      true
    end

    # Reprise par la planification (D4) : noms en attente ou en erreur.
    def self.resync(now : Time = Config.now) : Int32
      return 0 if provider.nil?
      count = 0
      Dossier.filter(dns_state__in: %w[pending error]).each do |dossier|
        sync(dossier, nil, now)
        count += 1
      end
      count
    end

    # Marque le nom à mettre à jour, puis le met à jour tout de suite ; en
    # cas d'échec, la planification reprend.
    def self.request(dossier : Dossier, actor : User? = nil, now : Time = Config.now) : Bool
      return true unless managed?(dossier)
      dossier.dns_state = "pending"
      dossier.save!
      sync(dossier, actor, now)
    end
  end
end

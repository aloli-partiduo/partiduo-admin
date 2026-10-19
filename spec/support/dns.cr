# SPDX-License-Identifier: AGPL-3.0-or-later

# Zone DNS simulée (ADR-013) : enregistrements en mémoire, panne à la
# demande ; zone `partiduo.localhost` gérée le temps d'un bloc.
module AdminDnsSpec
  class Provider < PartiduoAdmin::Dns::Provider
    getter records = {} of Int64 => {String, String, String, String} # id → zone, nom, type, cible
    getter calls = [] of String
    property down = false
    @next = 100_i64

    def entries(zone : String, sub_domain : String) : Array(PartiduoAdmin::Dns::Entry)
      fail!
      records.compact_map do |id, (record_zone, name, type, target)|
        PartiduoAdmin::Dns::Entry.new(id, type, target) if record_zone == zone && name == sub_domain
      end
    end

    def create(zone : String, sub_domain : String, target : String, ttl : Int32) : Int64
      fail!
      id = (@next += 1)
      records[id] = {zone, sub_domain, "CNAME", target}
      calls << "create #{sub_domain} #{target} #{ttl}"
      id
    end

    def update(zone : String, id : Int64, target : String, ttl : Int32) : Nil
      fail!
      zone_name, name, type, _ = records[id]
      records[id] = {zone_name, name, type, target}
      calls << "update #{name} #{target}"
    end

    def delete(zone : String, id : Int64) : Nil
      fail!
      calls << "delete #{records[id][1]}"
      records.delete(id)
    end

    def refresh(zone : String) : Nil
      calls << "refresh #{zone}"
    end

    # Enregistrement posé par quelqu'un d'autre (beryl, à la main).
    def foreign(zone : String, name : String, type : String, target : String) : Nil
      records[(@next += 1)] = {zone, name, type, target}
    end

    def target_of(name : String) : String?
      records.values.find { |record| record[1] == name }.try(&.[3])
    end

    private def fail! : Nil
      raise IO::Error.new("OVH injoignable") if down
    end
  end

  def self.with_dns(&)
    provider = Provider.new
    PartiduoAdmin::Dns.provider = provider
    PartiduoAdmin::Dns.zones_override = ["partiduo.localhost"]
    begin
      yield provider
    ensure
      PartiduoAdmin::Dns.provider = nil
      PartiduoAdmin::Dns.zones_override = nil
    end
  end
end

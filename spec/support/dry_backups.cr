# SPDX-License-Identifier: AGPL-3.0-or-later

module AdminSpec
  DRY_STEM = "backup-20260901T000000Z"

  # Sauvegarde en clair déjà au stockage simulé d'un exécutant à blanc
  # (base, pièces jointes, manifeste « signé ») ; rend les paramètres de
  # lecture que l'administration enverrait (D-CHF-018, D-CHF-024).
  def self.seed_dry_backup(dry : PartiduoAgent::DrySystem, slug : String = "garde", stem : String = DRY_STEM) : Hash(String, JSON::Any)
    server = dry.config.server
    store = dry.store.as(PartiduoAgent::DryStore)
    names = ["#{stem}.dump", "#{stem}.media.tar.gz"]
    entries = names.map do |name|
      PartiduoAdmin::BackupCrypto::Entry.new(name, 4096_i64, dry.sha256(File.join(dry.backup_root(slug), name)))
    end
    taken = PartiduoAgent::Locator.new(server, slug, names.first).taken_at
    manifest = PartiduoAdmin::BackupCrypto::Manifest.new(server, slug, stem, taken, "none", files: entries).to_s
    names.each { |name| store.stored["#{server}/#{slug}/#{name}"] = 4096_i64 }
    {"#{stem}.manifest" => manifest, "#{stem}.manifest.sig" => "signature à blanc"}.each do |name, text|
      store.stored["#{server}/#{slug}/#{name}"] = text.bytesize.to_i64
      store.contents["#{server}/#{slug}/#{name}"] = text
    end
    {"path" => JSON::Any.new("#{server}/#{slug}/#{names[0]}"), "media_path" => JSON::Any.new("#{server}/#{slug}/#{names[1]}"),
     "signers" => JSON.parse(["#{server} à blanc"].to_json)}
  end
end

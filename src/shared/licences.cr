# SPDX-License-Identifier: AGPL-3.0-or-later

# Provenance du code (AGPL-3.0, article 13) : les programmes web de ce dépôt
# (administration, connect) offrent leur code source à qui les utilise à
# travers le réseau, et les licences des composants tiers qu'ils embarquent.
module PartiduoLicences
  SOURCE_URL = "https://github.com/aloli-partiduo/partiduo-admin"

  # Assemblé par scripts/third-party-licenses.sh, lu à la compilation.
  TEXT = {{ read_file("#{__DIR__}/../../THIRD-PARTY-LICENSES.txt") }}

  # Un composant du texte : nom, licence, provenance (tableau de la page).
  record Component, name : String, licence : String, source : String do
    include Marten::Template::Object::Auto

    # Adresse seule (la provenance d'une fourche cite aussi l'origine).
    def url : String
      source.split(' ').first
    end
  end

  def self.components : Array(Component)
    lines = TEXT.lines
    lines.each_index.compact_map do |index|
      next unless lines[index].starts_with?("Provenance : ")
      name = lines[index - 1]
      source = lines[index].sub("Provenance : ", "")
      licence = lines[index + 1]?.to_s.sub(/\ALicence *: /, "")
      Component.new(name, licence, source)
    end.to_a
  end
end

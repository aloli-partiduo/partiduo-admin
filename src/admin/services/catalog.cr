# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Catalogue des pièces qu'un dossier peut activer (DECISIONS D-ADM-016) :
  # modules officiels de partiduo-app et extensions connues, rangés par
  # famille, avec les règles de leurs manifestes — `depends_on`,
  # `depends_on_any`, `incompatible_with`, `incompatible_with_kind` — et
  # celles des types de dossier (`InitialData.register_kind` du cœur :
  # modules requis et exclus).
  #
  # Seule source des règles de la console : le contrôle serveur (`problems`,
  # appelé par `Fleet`) et le confort du navigateur (attributs `data-*` lus
  # par `pieces.js`) en dérivent. `spec/admin/catalog_spec.cr` le compare aux
  # manifestes des dépôts voisins quand ils sont présents : une règle
  # ajoutée à un manifeste doit être reportée ici.
  #
  # Codes en minuscules, comme `partiduo-provision --modules` et `--with`
  # (le registre du cœur les met en majuscules).
  module Catalog
    # Pièce : code, famille, module officiel (`--modules`) ou extension
    # (`--with`), dépendances (`depends_on` : toutes ; `depends_on_any` : une
    # au moins de chaque groupe), incompatibilités déclarées par la pièce,
    # types de dossier qui l'excluent (`incompatible_with_kind`).
    record Piece, code : String, family : String, official : Bool = false,
      depends_on : Array(String) = [] of String,
      depends_on_any : Array(Array(String)) = [] of Array(String),
      incompatible_with : Array(String) = [] of String,
      excluded_kinds : Array(String) = [] of String

    # Règles d'un type de dossier : pièces requises et exclues
    # (`register_kind(…, required:, excluded:)` de partiduo-app,
    # src/core/initial_data.cr).
    record KindRule, required : Array(String) = [] of String, excluded : Array(String) = [] of String

    # Familles, dans l'ordre des formulaires.
    FAMILIES = %w[keeping management declarations einvoicing banking household tools]

    # Pièces connues, par famille. Manifestes : partiduo-app/src/<module>/
    # et partiduo-<extension>/src/<extension>/manifest.cr. Écartées : les
    # pièces du socle (toujours actives) et l'extension d'exemple `skel`,
    # qui reste possible comme autre extension.
    PIECES = [
      # Tenue des comptes : les trois se cumulent (ADR-007 D3, D6 : la
      # Comptabilité reprend en partie double les registres de la
      # micro-entreprise ou de la profession libérale).
      Piece.new("accounting", "keeping", official: true),
      Piece.new("micro", "keeping", official: true),
      Piece.new("liberal", "keeping", official: true),
      # Gestion.
      Piece.new("invoicing", "management", official: true),
      Piece.new("stock", "management", official: true, depends_on_any: [%w[invoicing accounting]]),
      Piece.new("followup", "management", official: true),
      Piece.new("analytic", "management", official: true, depends_on: %w[accounting]),
      Piece.new("amortis", "management", depends_on: %w[accounting], excluded_kinds: %w[household]),
      Piece.new("crm", "management", depends_on: %w[invoicing]),
      # Télédéclarations.
      Piece.new("teledec", "declarations", depends_on_any: [%w[accounting liberal]]),
      Piece.new("urssaf", "declarations", depends_on: %w[micro]),
      # Facture électronique : plusieurs plateformes peuvent être actives,
      # le dossier n'en raccorde qu'une (partiduo-einvoicing,
      # `Connections.active`).
      Piece.new("einv", "einvoicing", depends_on: %w[document]),
      Piece.new("superpdp", "einvoicing", depends_on: %w[einv]),
      Piece.new("esalink", "einvoicing", depends_on: %w[einv]),
      Piece.new("choruspro", "einvoicing", depends_on: %w[invoicing]),
      # Banque et paiements.
      Piece.new("bankimport", "banking", depends_on: %w[accounting]),
      Piece.new("sepa", "banking", depends_on: %w[accounting]),
      # Foyer (ADR-011 A1, D-PER-002).
      Piece.new("perso", "household", depends_on: %w[accounting bankimport],
        incompatible_with: %w[invoicing micro liberal stock followup analytic einv superpdp esalink choruspro teledec urssaf crm modeles]),
      # Outils.
      Piece.new("document", "tools"),
      Piece.new("import", "tools", depends_on: %w[accounting]),
      Piece.new("reports", "tools", depends_on: %w[accounting]),
      Piece.new("form", "tools"),
      Piece.new("modeles", "tools"),
    ]

    KINDS = {
      "company"   => KindRule.new,
      "household" => KindRule.new(required: %w[accounting], excluded: %w[invoicing micro liberal stock followup analytic]),
    }

    # Manquement à une règle : clé i18n (`admin.errors.pieces.*`), pièce en
    # cause, autres pièces citées, type de dossier.
    record Problem, key : String, piece : String, others : Array(String) = [] of String, kind : String = "" do
      # Famille de la pièce en cause : le formulaire y affiche le message.
      def field : String
        "family.#{Catalog.piece(piece).family}"
      end

      # Clé et paramètres en une chaîne (`Fleet::Errors` ne porte que des
      # chaînes), relue par `Catalog.message`.
      def encoded : String
        ["#{PREFIX}#{key}", "piece=#{piece}", "others=#{others.join(',')}", "kind=#{kind}"].join('|')
      end
    end

    PREFIX = "pieces:"

    BY_CODE = PIECES.to_h { |piece| {piece.code, piece} }

    def self.piece?(code : String) : Piece?
      BY_CODE[code]?
    end

    def self.piece(code : String) : Piece
      BY_CODE[code]? || raise KeyError.new("pièce inconnue : #{code}")
    end

    def self.known?(code : String) : Bool
      BY_CODE.has_key?(code)
    end

    def self.official?(code : String) : Bool
      piece?(code).try(&.official) || false
    end

    def self.in_family(family : String) : Array(Piece)
      PIECES.select { |piece| piece.family == family }
    end

    def self.kind_rule(kind : String) : KindRule
      KINDS[kind]? || KindRule.new
    end

    # Exclue de ce type de dossier, par le type ou par son manifeste.
    def self.excluded?(code : String, kind : String) : Bool
      kind_rule(kind).excluded.includes?(code) || (piece?(code).try(&.excluded_kinds.includes?(kind)) || false)
    end

    def self.required?(code : String, kind : String) : Bool
      kind_rule(kind).required.includes?(code)
    end

    # Types de dossier qui requièrent cette pièce.
    def self.required_kinds(code : String) : Array(String)
      KINDS.compact_map { |kind, rule| kind if rule.required.includes?(code) }
    end

    # Types de dossier qui l'excluent.
    def self.excluded_kinds(code : String) : Array(String)
      KINDS.keys.select { |kind| excluded?(code, kind) }
    end

    # Pièces incompatibles avec `code`, quel que soit le côté qui le déclare
    # (le cœur contrôle les deux sens, ADR-011 A1).
    def self.conflicts(code : String) : Array(String)
      own = piece?(code).try(&.incompatible_with) || [] of String
      others = PIECES.select(&.incompatible_with.includes?(code)).map(&.code)
      (own + others).uniq
    end

    # Pièces que ce type de dossier ne peut pas avoir : exclues, ou dont une
    # dépendance ne peut pas l'être (point fixe). Un foyer ne les voit pas.
    def self.unavailable(kind : String) : Set(String)
      out = PIECES.select { |piece| excluded?(piece.code, kind) }.map(&.code).to_set
      loop do
        added = PIECES.reject { |piece| out.includes?(piece.code) }.select do |piece|
          piece.depends_on.any? { |code| out.includes?(code) } ||
            piece.depends_on_any.any?(&.all? { |code| out.includes?(code) })
        end
        break if added.empty?
        added.each { |piece| out << piece.code }
      end
      out
    end

    # Manquements de l'ensemble `codes` (modules et extensions) pour ce type
    # de dossier. Les codes inconnus du catalogue (autres extensions) ne sont
    # pas jugés ici : le cœur les contrôle à l'activation.
    def self.problems(kind : String, codes : Array(String)) : Array(Problem)
      chosen = codes.uniq
      known = chosen.select { |code| known?(code) }
      found = [] of Problem
      kind_rule(kind).required.each do |code|
        found << Problem.new("kind_requires", code, kind: kind) unless chosen.includes?(code)
      end
      known.each do |code|
        next found << Problem.new("kind_excludes", code, kind: kind) if excluded?(code, kind)
        found.concat(dependency_problems(piece(code), chosen))
      end
      known.each_with_index do |code, index|
        known[(index + 1)..].each do |other|
          found << Problem.new("incompatible", code, [other]) if conflicts(code).includes?(other)
        end
      end
      found
    end

    private def self.dependency_problems(piece : Piece, chosen : Array(String)) : Array(Problem)
      found = piece.depends_on.reject { |code| chosen.includes?(code) }.map { |code| Problem.new("requires", piece.code, [code]) }
      piece.depends_on_any.each do |group|
        found << Problem.new("requires_any", piece.code, group) if group.none? { |code| chosen.includes?(code) }
      end
      found
    end

    # Erreurs des manquements, par champ (famille de la pièce en cause).
    def self.errors(kind : String, codes : Array(String)) : Hash(String, Array(String))
      errors = {} of String => Array(String)
      problems(kind, codes).each { |problem| (errors[problem.field] ||= [] of String) << problem.encoded }
      errors
    end

    # Message traduit d'une erreur codée par `Problem#encoded` ; `nil` pour
    # une simple clé.
    def self.message(encoded : String) : String?
      return unless encoded.starts_with?(PREFIX)
      key, *pairs = encoded.lchop(PREFIX).split('|')
      params = pairs.to_h { |pair| name, _, value = pair.partition('='); {name, value} }
      others = params["others"].split(',').reject(&.empty?)
      list = key == "requires_any" ? alternatives(others) : others.map { |code| quoted(code) }.join(", ")
      I18n.t("admin.errors.pieces.#{key}", piece: quoted(params["piece"]), others: list,
        kind: params["kind"].empty? ? "" : I18n.t("admin.kinds.#{params["kind"]}"))
    end

    # Nom d'une pièce dans la langue courante.
    def self.label(code : String) : String
      known?(code) ? I18n.t("admin.pieces.#{code}.name") : code
    end

    def self.quoted(code : String) : String
      I18n.t("admin.pieces.quoted", name: label(code))
    end

    # « A », « B » ou « C ».
    def self.alternatives(codes : Array(String)) : String
      names = codes.map { |code| quoted(code) }
      return names.join if names.size < 2
      I18n.t("admin.pieces.or", first: names[0...-1].join(", "), last: names.last)
    end

    # Libellés des pièces d'un dossier, dans l'ordre du catalogue, suivis
    # des autres codes.
    def self.labels(codes : Array(String)) : Array(String)
      ordered = PIECES.map(&.code).select { |code| codes.includes?(code) } + codes.reject { |code| known?(code) }
      ordered.map { |code| label(code) }
    end
  end
end

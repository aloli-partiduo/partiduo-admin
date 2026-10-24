# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Rappel lisible sans JavaScript : `requires` (dépendances),
  # `incompatible`, `kind` (restriction de type, à la création). Avec
  # JavaScript, `pieces.js` masque les deux derniers : l'état de la case
  # les dit quand ils jouent.
  record PieceNote, type : String, text : String do
    include Marten::Template::Object::Auto
  end

  # Une pièce proposée au choix (`admin/_pieces.html`) : nom, code, ligne
  # d'explication, règles du catalogue (attributs `data-*` de `pieces.js`)
  # et rappels lisibles sans JavaScript.
  class PieceChoice
    include Marten::Template::Object::Auto

    getter code : String
    getter label : String
    getter help : String
    getter checked : Bool
    # Requise par le type du dossier (page des modules d'un foyer) : cochée,
    # non modifiable, envoyée par un champ caché.
    getter locked : Bool
    getter notes : Array(PieceNote)

    def initialize(@code, @checked, @locked, @notes)
      @label = Catalog.label(code)
      @help = I18n.t("admin.pieces.#{code}.help")
    end

    def piece : Catalog::Piece
      Catalog.piece(code)
    end

    # Champ du formulaire : `modules` (`--modules`) ou `extensions` (`--with`).
    def name : String
      piece.official ? "modules" : "extensions"
    end

    def id : String
      "p-#{code}"
    end

    def help_id : String
      "#{id}-help"
    end

    def status_id : String
      "#{id}-status"
    end

    def requires : String
      piece.depends_on.join(' ')
    end

    def requires_any : String
      piece.depends_on_any.map(&.join(',')).join(' ')
    end

    def conflicts : String
      Catalog.conflicts(code).join(' ')
    end

    def excluded_kinds : String
      Catalog.excluded_kinds(code).join(' ')
    end

    def required_kinds : String
      Catalog.required_kinds(code).join(' ')
    end
  end

  # Une famille de pièces : `fieldset` et `legend`, ligne d'explication,
  # erreurs du contrôle serveur qui la concernent.
  class PieceFamily
    include Marten::Template::Object::Auto

    getter code : String
    getter legend : String
    getter help : String
    getter pieces : Array(PieceChoice)
    getter errors : Array(String)

    def initialize(@code, @pieces, @errors)
      @legend = I18n.t("admin.pieces.families.#{code}.legend")
      @help = I18n.t("admin.pieces.families.#{code}.help")
    end

    def id : String
      "family-#{code}"
    end

    def help_id : String
      "#{id}-help"
    end

    def error_id : String
      "#{id}-error"
    end

    def has_errors : Bool
      !errors.empty?
    end

    def describedby : String
      has_errors ? "#{help_id} #{error_id}" : help_id
    end
  end

  # Réglages du choix des pièces pour `pieces.js` (attributs du conteneur).
  class PiecePicker
    include Marten::Template::Object::Auto

    getter kind : String

    def initialize(@kind : String, @initial : Array(String))
    end

    def initial : String
      @initial.join(' ')
    end

    def messages : String
      PieceForm.messages.to_json
    end

    def kinds : String
      PieceForm.kind_labels.to_json
    end
  end

  # Choix des pièces d'un dossier par familles (D-ADM-016), à la création
  # (`kind` nil : le type se choisit sur la même page, toutes les pièces
  # sont proposées avec leurs restrictions de type) ou sur la page des
  # modules (`kind` fixé : seules les pièces admises par ce type sont
  # proposées, plus celles déjà choisies, pour pouvoir les retirer).
  module PieceForm
    def self.families(kind : String?, chosen : Array(String), errors : Hash(String, Array(String))) : Array(PieceFamily)
      hidden = kind ? Catalog.unavailable(kind) : Set(String).new
      Catalog::FAMILIES.compact_map do |family|
        pieces = Catalog.in_family(family).compact_map do |piece|
          next if hidden.includes?(piece.code) && !chosen.includes?(piece.code)
          locked = kind ? Catalog.required?(piece.code, kind) : false
          PieceChoice.new(piece.code, locked || chosen.includes?(piece.code), locked, notes(piece, kind))
        end
        PieceFamily.new(family, pieces, errors["family.#{family}"]? || [] of String) unless pieces.empty?
      end
    end

    # Rappels sans JavaScript : dépendances, incompatibilités et, à la
    # création, restrictions de type.
    def self.notes(piece : Catalog::Piece, kind : String?) : Array(PieceNote)
      notes = [] of PieceNote
      unless piece.depends_on.empty?
        others = piece.depends_on.map { |code| Catalog.quoted(code) }.join(", ")
        notes << PieceNote.new("requires", I18n.t("admin.pieces.notes.requires", others: others))
      end
      piece.depends_on_any.each do |group|
        notes << PieceNote.new("requires", I18n.t("admin.pieces.notes.requires", others: Catalog.alternatives(group)))
      end
      conflicts = Catalog.conflicts(piece.code)
      unless conflicts.empty?
        others = conflicts.map { |code| Catalog.quoted(code) }.join(", ")
        notes << PieceNote.new("incompatible", I18n.t("admin.pieces.notes.incompatible", others: others))
      end
      notes.concat(kind_notes(piece)) if kind.nil?
      notes
    end

    private def self.kind_notes(piece : Catalog::Piece) : Array(PieceNote)
      excluded = Catalog.excluded_kinds(piece.code).map do |code|
        PieceNote.new("kind", I18n.t("admin.pieces.notes.kind_excludes", kind: I18n.t("admin.kinds.#{code}")))
      end
      excluded + Catalog.required_kinds(piece.code).map do |code|
        PieceNote.new("kind", I18n.t("admin.pieces.notes.kind_requires", kind: I18n.t("admin.kinds.#{code}")))
      end
    end

    # Messages de `pieces.js`, traduits, `%{…}` remplacés dans le navigateur.
    def self.messages : Hash(String, String)
      {
        "required_by"   => I18n.t("admin.pieces.js.required_by", others: "%{others}"),
        "incompatible"  => I18n.t("admin.pieces.js.incompatible", others: "%{others}"),
        "kind_required" => I18n.t("admin.pieces.js.kind_required", kind: "%{kind}"),
        "unavailable"   => I18n.t("admin.pieces.js.unavailable", kind: "%{kind}"),
        "quoted"        => I18n.t("admin.pieces.quoted", name: "%{name}"),
        "missing"       => I18n.t("admin.pieces.notes.requires", others: "%{others}"),
        "checked"       => I18n.t("admin.pieces.js.checked", piece: "%{piece}", others: "%{others}"),
        "unchecked"     => I18n.t("admin.pieces.js.unchecked", others: "%{others}"),
        "confirm"       => I18n.t("admin.pieces.js.confirm", piece: "%{piece}", others: "%{others}"),
        "enable"        => I18n.t("admin.pieces.js.enable", others: "%{others}"),
        "disable"       => I18n.t("admin.pieces.js.disable", others: "%{others}"),
      }
    end

    # Noms des types de dossier, pour les messages du navigateur.
    def self.kind_labels : Hash(String, String)
      Protocol::DOSSIER_KINDS.to_h { |code| {code, I18n.t("admin.kinds.#{code}")} }
    end

    # Codes saisis comme autres extensions : ceux que le catalogue ne
    # connaît pas.
    def self.others(extensions : Array(String)) : String
      extensions.reject { |code| Catalog.known?(code) }.join(", ")
    end

    # Modules et extensions d'un formulaire : cases cochées et autres codes
    # saisis (séparés par des virgules ou des espaces) ; un module officiel
    # saisi comme extension rejoint les modules.
    def self.split(modules : Array(String), extensions : Array(String)) : {Array(String), Array(String)}
      codes = extensions.flat_map(&.split(/[\s,]+/)).map(&.strip.downcase).reject(&.empty?).uniq!
      official = codes.select { |code| Catalog.official?(code) }
      {(modules + official).uniq, codes - official}
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Rappel lisible sans JavaScript : `requires` (dépendances),
  # `incompatible`, `kind` (restriction de type ou de régime, à la
  # création). Avec JavaScript, `pieces.js` masque les deux derniers :
  # l'état de la case les dit quand ils jouent.
  record PieceNote, type : String, text : String do
    include Marten::Template::Object::Auto
  end

  # Une pièce proposée au choix (`admin/_piece.html`) : nom, code, ligne
  # d'explication, règles du catalogue (attributs `data-*` de `pieces.js`)
  # et rappels lisibles sans JavaScript. Case à cocher, ou bouton radio
  # pour une pièce d'un choix exclusif (`Catalog::CHOICES`).
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

    def input_type : String
      piece.choice ? "radio" : "checkbox"
    end

    def choice : String
      piece.choice || ""
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

    def regimes : String
      Catalog.regimes(code).join(' ')
    end
  end

  # Choix exclusif d'une famille (`Catalog::CHOICES`) : `fieldset` de
  # boutons radio, pièces du choix et « ni l'un ni l'autre » (valeur vide,
  # ignorée par `PieceForm.split`).
  class PieceGroup
    include Marten::Template::Object::Auto

    getter code : String
    getter legend : String
    getter help : String
    getter none_label : String
    getter pieces : Array(PieceChoice)

    def initialize(@code, @pieces)
      @legend = I18n.t("admin.pieces.choices.#{code}.legend")
      @help = I18n.t("admin.pieces.choices.#{code}.help")
      @none_label = I18n.t("admin.pieces.choices.#{code}.none")
    end

    def id : String
      "choice-#{code}"
    end

    def help_id : String
      "#{id}-help"
    end

    def none_id : String
      "#{id}-none"
    end

    # Champ des pièces du choix (toutes du même côté).
    def name : String
      pieces.first?.try(&.name) || "modules"
    end

    def none_checked : Bool
      pieces.none?(&.checked)
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
    getter groups : Array(PieceGroup)
    getter errors : Array(String)

    def initialize(@code, @pieces, @errors, @groups = [] of PieceGroup)
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
    getter regime : String

    def initialize(@kind : String, @initial : Array(String), @regime : String = "")
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

    def regimes : String
      PieceForm.regime_labels.to_json
    end
  end

  # Choix des pièces d'un dossier par familles (D-ADM-016), à la création
  # (`kind` et `regime` nil : ils se choisissent sur la même page, toutes
  # les pièces sont proposées avec leurs restrictions de type et de régime)
  # ou sur la page des modules (`kind` et `regime` fixés : seules les
  # pièces admises sont proposées, plus celles déjà choisies, pour pouvoir
  # les retirer). Les pièces d'un choix exclusif forment un groupe de
  # boutons radio (D-ADM-019).
  module PieceForm
    def self.families(kind : String?, regime : String?, chosen : Array(String),
                      errors : Hash(String, Array(String))) : Array(PieceFamily)
      hidden = kind ? Catalog.unavailable(kind, regime) : Set(String).new
      Catalog::FAMILIES.compact_map do |family|
        choices = Catalog.in_family(family).compact_map do |piece|
          next if hidden.includes?(piece.code) && !chosen.includes?(piece.code)
          locked = kind ? Catalog.required?(piece.code, kind) : false
          PieceChoice.new(piece.code, locked || chosen.includes?(piece.code), locked, notes(piece, kind, regime))
        end
        pieces = choices.reject(&.piece.choice)
        groups = choices.compact_map(&.piece.choice).uniq!.map do |code|
          PieceGroup.new(code, choices.select(&.piece.choice.==(code)))
        end
        next if pieces.empty? && groups.empty?
        PieceFamily.new(family, pieces, errors["family.#{family}"]? || [] of String, groups)
      end
    end

    # Rappels sans JavaScript : dépendances, incompatibilités (sauf entre
    # les pièces d'un même choix exclusif, que les boutons radio disent) et,
    # à la création, restrictions de type et de régime.
    def self.notes(piece : Catalog::Piece, kind : String?, regime : String? = nil) : Array(PieceNote)
      notes = [] of PieceNote
      unless piece.depends_on.empty?
        others = piece.depends_on.map { |code| Catalog.quoted(code) }.join(", ")
        notes << PieceNote.new("requires", I18n.t("admin.pieces.notes.requires", others: others))
      end
      piece.depends_on_any.each do |group|
        notes << PieceNote.new("requires", I18n.t("admin.pieces.notes.requires", others: Catalog.alternatives(group)))
      end
      conflicts = Catalog.conflicts(piece.code).reject do |code|
        (choice = piece.choice) && Catalog.piece(code).choice == choice
      end
      unless conflicts.empty?
        others = conflicts.map { |code| Catalog.quoted(code) }.join(", ")
        notes << PieceNote.new("incompatible", I18n.t("admin.pieces.notes.incompatible", others: others))
      end
      notes.concat(kind_notes(piece)) if kind.nil?
      notes.concat(regime_notes(piece)) if regime.nil?
      notes
    end

    private def self.regime_notes(piece : Catalog::Piece) : Array(PieceNote)
      return [] of PieceNote if piece.regimes.empty?
      names = piece.regimes.map { |code| I18n.t("admin.regimes.#{code}") }
      label = names.size < 2 ? names.join : I18n.t("admin.pieces.or", first: names[0...-1].join(", "), last: names.last)
      [PieceNote.new("kind", I18n.t("admin.pieces.notes.regime_only", regimes: label))]
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
        "regime"        => I18n.t("admin.pieces.js.unavailable_regime", regime: "%{regime}"),
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

    # Noms des régimes fiscaux, pour les messages du navigateur.
    def self.regime_labels : Hash(String, String)
      Catalog::REGIMES.to_h { |code| {code, I18n.t("admin.regimes.#{code}")} }
    end

    # Codes saisis comme autres extensions : ceux que le catalogue ne
    # connaît pas.
    def self.others(extensions : Array(String)) : String
      extensions.reject { |code| Catalog.known?(code) }.join(", ")
    end

    # Modules et extensions d'un formulaire : cases cochées et autres codes
    # saisis (séparés par des virgules ou des espaces) ; un module officiel
    # saisi comme extension rejoint les modules. Valeur vide (« ni l'un ni
    # l'autre » d'un choix exclusif) ignorée.
    def self.split(modules : Array(String), extensions : Array(String)) : {Array(String), Array(String)}
      codes = extensions.flat_map(&.split(/[\s,]+/)).map(&.strip.downcase).reject(&.empty?).uniq!
      official = codes.select { |code| Catalog.official?(code) }
      {(modules.map(&.strip).reject(&.empty?) + official).uniq, codes - official}
    end
  end
end

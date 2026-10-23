# SPDX-License-Identifier: AGPL-3.0-or-later

require "html"
require "yaml"

# Contrôle des traductions (fr, en, nl, de, es, it, pt) de la console
# d'administration et de connect, deux programmes Marten à part (`spec/`,
# `spec-connect/`, qui requiert ce fichier). Même contrôle que celui de
# l'interface des dossiers (`partiduo-ui-bulma`, spec/support/translations.cr),
# dont l'administration ne dépend pas (ADR-008 D1) :
#
# . *statique* (`parity_failures`, `unknown_keys`) : les fichiers de
#   locales ont les mêmes clés et les mêmes interpolations dans chaque
#   langue ; chaque clé citée par le code ou les gabarits (`I18n.t("…")`,
#   `{% translate "…" %}`) existe dans chaque langue, en formes du pluriel
#   si elle est recherchée avec un compte ;
# . *sonde* (`Probe`) : toute recherche de traduction faite pendant la suite
#   de specs, quelle que soit la langue active, doit trouver sa clé dans les
#   sept langues ; les défauts sont rapportés en fin de suite, qui échoue ;
# . *dynamique* (`Explorer`) : toutes les routes du routeur de Marten,
#   pages à paramètres atteintes par les liens des pages du jeu de données,
#   chaque page obtenue dans chaque langue, puis chaque formulaire `POST`
#   relevé envoyé dans chaque langue ; le HTML rendu (page, réponse à un
#   envoi, page où il redirige) ne doit contenir ni marqueur de traduction
#   absente, ni clé brute, ni interpolation non résolue, et aucune réponse
#   n'est une erreur 500. Une route servie en `GET` qu'aucun lien n'atteint
#   fait échouer le contrôle, sauf exclusion motivée ; un formulaire jamais
#   envoyé est déclaré, avec son motif.
module PartiduoTranslations
  LOCALES = %w[fr en nl de es it pt]

  # Marqueur rendu par crystal-i18n pour une clé absente.
  MISSING = /(?:missing translation|translation missing):\s*([\w.\-]+)/i

  INTERPOLATION = /%\{[^}]*\}/

  # Attributs lus par une personne (les autres, techniques ou `data-*`, ne
  # sont pas contrôlés).
  HUMAN_ATTRIBUTES = %w[title placeholder aria-label aria-description aria-placeholder alt label hx-confirm data-pd-confirm]

  # --- Catalogue chargé -----------------------------------------------------------

  @@texts : Hash(String, Hash(String, I18n::TranslationsHashValues))? = nil
  @@catalog : Hash(String, Set(String))? = nil
  @@namespaces : Set(String)? = nil

  # Valeur de chaque clé (feuille ou nœud : clés de pluriel, sous-arbres),
  # par langue, dans l'ordre de chargement de Marten (la dernière l'emporte).
  def self.texts : Hash(String, Hash(String, I18n::TranslationsHashValues))
    @@texts ||= begin
      values = Hash(String, Hash(String, I18n::TranslationsHashValues)).new do |hash, locale|
        hash[locale] = {} of String => I18n::TranslationsHashValues
      end
      LOCALES.each { |locale| values[locale] }
      I18n.config.loaders.each do |loader|
        loader.load.each do |locale, data|
          flatten(data, "", values[locale]) if data.is_a?(Hash)
        end
      end
      values
    end
  end

  def self.catalog : Hash(String, Set(String))
    @@catalog ||= texts.transform_values(&.keys.to_set)
  end

  def self.namespaces : Set(String)
    @@namespaces ||= catalog.values.flat_map(&.map(&.split('.').first)).to_set
  end

  def self.known?(locale : String, key : String) : Bool
    catalog[locale].includes?(key)
  end

  private def self.flatten(data : I18n::TranslationsHash, prefix : String,
                           into : Hash(String, I18n::TranslationsHashValues)) : Nil
    data.each do |name, value|
      key = prefix.empty? ? name : "#{prefix}.#{name}"
      into[key] = value
      flatten(value, key, into) if value.is_a?(Hash)
    end
  end

  # Défaut d'une recherche de traduction dans une langue : clé absente,
  # sous-arbre demandé sans compte, ou interpolation à laquelle aucun
  # paramètre ne répond (`names`, `count` compris ; non contrôlé si `nil`).
  # `nil` si rien.
  def self.lookup_problem(locale : String, key : String, names : Set(String)?, plural : Bool) : String?
    value = texts[locale][key]?
    return "#{locale}.#{key} absente" if value.nil? && !texts[locale].has_key?(key)
    return "#{locale}.#{key} recherchée avec un compte, sans formes du pluriel" if plural && !value.is_a?(Hash)
    strings = case value
              when Hash
                return "#{locale}.#{key} est un sous-arbre, demandé sans compte" unless plural
                plurals = [] of String
                value.each_value { |form| plurals << form if form.is_a?(String) }
                plurals
              when Array then [value.join("\n")]
              else            [value.to_s]
              end
    return if names.nil?
    unresolved = strings.flat_map(&.scan(/%\{(\w+)\}/).map(&.[1])).uniq!.reject { |name| names.includes?(name) }
    "#{locale}.#{key} : #{unresolved.map { |name| "%{#{name}}" }.join(" ")} sans paramètre" unless unresolved.empty?
  end

  # --- Sonde des recherches de traduction --------------------------------------
  #
  # Toute recherche faite pendant la suite de specs (`I18n.t` du code,
  # `{% translate %}` des gabarits, courriel, message de Marten, réponse à
  # un envoi…), quelle que soit la langue active : la clé doit exister dans
  # les sept langues (pluriel compris), et une recherche faite par le code
  # avec des paramètres (`Probe.translate`) doit en fournir un à chaque
  # interpolation. Une recherche avec `default:` est volontairement
  # tolérante et n'est pas contrôlée, comme celle d'une spec elle-même. Les
  # défauts sont rapportés en fin de suite, qui échoue alors (`Probe.report`).
  module Probe
    @@failures = {} of String => String
    @@lookups = 0
    @@quiet = 0

    def self.failures : Hash(String, String)
      @@failures
    end

    def self.lookups : Int32
      @@lookups
    end

    # Recherche faite par crystal-i18n (`I18n::Catalog#fetch_translation!`,
    # clé complète, portée appliquée) : existence de la clé dans chaque
    # langue.
    def self.lookup(key : String, count, default) : Nil
      return unless default.nil? && @@quiet == 0
      @@lookups += 1
      check(key, nil, !count.nil?)
    end

    # Recherche avec ses paramètres (`I18n::Catalog#translate!`) : chaque
    # interpolation, dans chaque langue, doit en recevoir un.
    def self.translate(key : String, names : Set(String), count, default) : Nil
      return unless default.nil? && @@quiet == 0
      check(key, names, !count.nil?)
    end

    private def self.check(key : String, names : Set(String)?, plural : Bool) : Nil
      LOCALES.each do |locale|
        problem = PartiduoTranslations.lookup_problem(locale, key, names, plural)
        next if problem.nil? || @@failures.has_key?(problem)
        where = origin
        @@failures[problem] = where unless spec?(where)
      end
    end

    # Recherche tolérante de crystal-i18n (`fetch_translation`, sans point
    # d'exclamation : formats des nombres de `I18n.localize`), absence admise.
    def self.quietly(&)
      @@quiet += 1
      yield
    ensure
      @@quiet -= 1
    end

    # Recherche faite par une spec elle-même (`I18n.t` d'une attente), et
    # non par le code : pas un défaut.
    private def self.spec?(where : String) : Bool
      where.matches?(%r{(?:\A|/)spec(?:-connect)?/}) && !where.includes?("/support/") && !where.starts_with?("spec/support/") &&
        !where.starts_with?("spec-connect/support/")
    end

    # Chemin relatif : la pile cite le fichier par le dépôt.
    PROBE_FILE = "spec/support/translations.cr"

    # Premier appelant du code de Partiduo (handler, service, spec), hors des
    # dépendances (`lib/` : crystal-i18n, gabarits de Marten) et de cette
    # sonde.
    private def self.origin : String
      caller.find do |frame|
        (!frame.starts_with?('/') || frame.includes?("partiduo")) && !frame.starts_with?("lib/") &&
          !frame.includes?("/lib/") && !frame.includes?(PROBE_FILE)
      end.try(&.strip) || "?"
    rescue
      # Pile illisible.
      "?"
    end

    # Défauts relevés, un par ligne, avec leur premier appelant.
    def self.report : Array(String)
      @@failures.map { |problem, where| "#{problem} (#{where})" }.sort!
    end
  end

  # --- Contrôle statique ------------------------------------------------------------

  # Fichiers `<langue>.yml` d'un répertoire : mêmes clés, mêmes
  # interpolations que `fr.yml`.
  def self.parity_failures(dir : String) : Array(String)
    values = LOCALES.to_h do |locale|
      path = File.join(dir, "#{locale}.yml")
      tree = File.exists?(path) ? YAML.parse(File.read(path))[locale]? : nil
      {locale, tree ? leaves(tree, "") : {} of String => String}
    end
    failures = [] of String
    reference = values["fr"]
    LOCALES.skip(1).each do |locale|
      other = values[locale]
      (reference.keys - other.keys).sort!.each { |key| failures << "#{dir} : #{locale} n'a pas la clé #{key}" }
      (other.keys - reference.keys).sort!.each { |key| failures << "#{dir} : #{locale} a la clé #{key}, absente en fr" }
      (reference.keys & other.keys).sort!.each do |key|
        expected = reference[key].scan(INTERPOLATION).map(&.[0]).to_set
        found = other[key].scan(INTERPOLATION).map(&.[0]).to_set
        next if expected == found
        failures << "#{dir} : #{locale}.#{key} interpole #{found.to_a.sort.join(" ")}, fr #{expected.to_a.sort.join(" ")}"
      end
    end
    failures
  end

  private def self.leaves(node : YAML::Any, prefix : String, into = {} of String => String) : Hash(String, String)
    if hash = node.as_h?
      hash.each { |key, value| leaves(value, prefix.empty? ? key.to_s : "#{prefix}.#{key}", into) }
    elsif array = node.as_a?
      into[prefix] = array.map(&.to_s).join("\n")
    else
      into[prefix] = node.to_s
    end
    into
  end

  USAGES = [
    /I18n\.t(?:ranslate)?!?\(\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"/,
    /\{%-?\s*(?:translate|t)\s+["']([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)["']/,
  ]

  # Recherche avec un compte : crystal-i18n cherche alors une forme du
  # pluriel (`….one`, `….other`).
  COUNTED = [
    /I18n\.t(?:ranslate)?!?\(\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"[^)]*?\bcount:/,
    /\{%-?\s*(?:translate|t)\s+["']([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)["'][^%]*?\bcount:/,
  ]

  # Clés citées par les fichiers `globs` (relatifs à `root`) absentes du
  # catalogue chargé dans une langue au moins, ou recherchées avec un compte
  # sans formes du pluriel ; commentaires écartés. `namespaces` : premiers
  # segments contrôlés (ceux du programme), dont tout littéral
  # (`"admin.menu.users"`, passé à une aide) est une clé.
  def self.unknown_keys(root : String, globs : Array(String), namespaces : Array(String)) : Array(String)
    failures = [] of String
    patterns = USAGES + [Regex.new(%(["'](#{namespaces.map { |name| Regex.escape(name) }.join('|')})((?:\\.[a-z0-9_]+)+)["']))]
    Dir.glob(globs.map { |glob| File.join(root, glob) }).sort!.each do |path|
      relative = Path[path].relative_to(root).to_s
      File.read_lines(path).each_with_index(1) do |text, number|
        next if text.lstrip.starts_with?('#') || text.lstrip.starts_with?("{#")
        # Source d'un journal (`Log.for("connect.mailer")`), pas une clé.
        next if text.includes?("Log.for(")
        patterns.each do |pattern|
          text.scan(pattern) do |match|
            key = match[2]? ? "#{match[1]}#{match[2]}" : match[1]
            next unless namespaces.includes?(key.split('.').first)
            missing = LOCALES.reject { |locale| known?(locale, key) }
            failures << "#{relative}:#{number} : #{key} absente en #{missing.join(", ")}" unless missing.empty?
          end
        end
        COUNTED.each do |pattern|
          text.scan(pattern) do |match|
            singular = LOCALES.select { |locale| known?(locale, match[1]) && !texts[locale][match[1]].is_a?(Hash) }
            next if singular.empty?
            failures << "#{relative}:#{number} : #{match[1]} recherchée avec un compte, sans pluriel en #{singular.join(", ")}"
          end
        end
      end
    end
    failures.uniq
  end

  # --- Contrôle du HTML rendu --------------------------------------------------------

  def self.problems(html : String) : Array(String)
    found = [] of String
    html.scan(MISSING) { |match| found << "traduction absente : #{match[1]}" }
    readable(html).each do |text|
      text.scan(INTERPOLATION) { |match| found << "interpolation non résolue : #{match[0]}" }
      text.scan(/(?<![\w.\/@:-])([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)(?![\w\/@-])/) do |match|
        found << "clé brute : #{match[1]}" if raw_key?(match[1])
      end
    end
    found.uniq
  end

  # Texte visible et attributs lus, entités décodées. Écartés : scripts,
  # styles, commentaires, zones de saisie et codes affichés tels quels.
  def self.readable(html : String) : Array(String)
    source = html.gsub(/<!--.*?-->/m, " ")
      .gsub(/<(script|style|textarea|code|kbd|samp|pre)\b[^>]*>.*?<\/\1>/mi, " ")
    parts = [] of String
    source.scan(/<[a-zA-Z][^>]*>/) do |tag|
      tag[0].scan(/\s([a-zA-Z\-]+)\s*=\s*("([^"]*)"|'([^']*)')/) do |attribute|
        next unless HUMAN_ATTRIBUTES.includes?(attribute[1].downcase)
        parts << HTML.unescape(attribute[3]? || attribute[4]? || "")
      end
    end
    parts << HTML.unescape(source.gsub(/<[^>]*>/, " "))
    parts
  end

  def self.raw_key?(word : String) : Bool
    segments = word.split('.')
    return false unless namespaces.includes?(segments.first)
    return true if catalog.values.any?(&.includes?(word))
    segments.size > 2 && catalog.values.any?(&.includes?(segments.first(2).join('.')))
  end

  # --- Routes -----------------------------------------------------------------------

  class Route
    getter name : String
    getter pattern : String
    getter handler : Marten::Handlers::Base.class
    getter regex : Regex

    def initialize(@name, @pattern, @handler)
      @regex = Marten::Routing::Rule::Base.path_to_regex(@pattern, "$")[0]
    end

    def parameters? : Bool
      pattern.includes?('<')
    end

    def placeholder_url : String
      pattern.gsub(/<(\w+)(?::(\w+))?>/) do
        case $~[2]?
        when "int"  then "999999999"
        when "uuid" then "00000000-0000-0000-0000-000000000000"
        else             "inconnu"
        end
      end
    end

    # Sert `GET` : le handler (ou une classe dont il hérite) définit `get`
    # ou `dispatch`, et ses méthodes admises comprennent `GET`.
    def serves_get? : Bool
      handler.http_method_names.includes?("GET") && PartiduoTranslations.handlers_serving_get.includes?(handler.name)
    end
  end

  @@handlers_serving_get : Set(String)? = nil

  def self.handlers_serving_get : Set(String)
    @@handlers_serving_get ||= begin
      names = Set(String).new
      {% for klass in Marten::Handlers::Base.all_subclasses %}
        {% chain = [klass] + klass.ancestors.select { |ancestor| ancestor < Marten::Handlers::Base } %}
        {% if chain.any? { |type| type.methods.any? { |method| method.name == "get" || method.name == "dispatch" } } %}
          names << {{ klass.name.stringify }}
        {% end %}
      {% end %}
      names
    end
  end

  def self.routes(map : Marten::Routing::Map = Marten.routes, prefix : String = "", namespace : String = "") : Array(Route)
    map.rules.flat_map do |rule|
      case rule
      when Marten::Routing::Rule::Path
        path = rule.path
        path.is_a?(String) ? [Route.new(qualified(namespace, rule.name), prefix + path, rule.handler)] : [] of Route
      when Marten::Routing::Rule::Map
        path = rule.path
        path.is_a?(String) ? routes(rule.map, prefix + path, qualified(namespace, rule.name)) : [] of Route
      else
        [] of Route
      end
    end
  end

  private def self.qualified(namespace : String, name : String) : String
    [namespace, name].reject(&.empty?).join(':')
  end

  GLUE = %w[Marten::Handlers::Defaults::Development::ServeAsset]

  # --- Visiteur ---------------------------------------------------------------------

  # Obtient une adresse dans une langue.
  alias Fetch = String, String -> Marten::HTTP::Response
  # Envoie un corps de formulaire déjà encodé (adresse, corps, langue,
  # en-têtes) dans une langue.
  alias Post = String, String, String, Hash(String, String) -> Marten::HTTP::Response

  # Navigation d'un jeu de données dans chaque langue : un navigateur par
  # langue (la langue d'un compte connecté prime sur le cookie), qui garde
  # ses cookies (session, jeton CSRF) d'une requête à l'autre.
  record Visitor, get : Fetch, post : Post

  # --- Exploration ------------------------------------------------------------------

  class Explorer
    PER_ROUTE = 4

    getter routes : Array(Route)
    getter exclusions : Hash(String, String)
    getter failures = [] of String
    getter reached = Set(String).new
    getter checked = 0
    getter checked_routes = Set(String).new

    # `exclusions` : nom de route → motif (route servie en `GET` qui n'est
    # pas une page à explorer) ; `unsent` : nom de route → motif
    # (formulaire jamais envoyé : fin de la session de l'exploration…).
    def initialize(@exclusions : Hash(String, String) = {} of String => String,
                   @unsent : Hash(String, String) = {} of String => String,
                   @routes : Array(Route) = PartiduoTranslations.routes)
      @routes = @routes.reject { |route| GLUE.includes?(route.handler.name) }
      unknown = (@exclusions.keys + @unsent.keys) - @routes.map(&.name)
      raise ArgumentError.new("exclusions sans route : #{unknown.join(", ")}") unless unknown.empty?
    end

    def explorable?(route : Route) : Bool
      route.serves_get? && !exclusions.has_key?(route.name)
    end

    def route_for(path : String) : Route?
      routes.find(&.regex.matches?(path))
    end

    # Routes sans paramètre, `seeds`, puis les liens de chaque page obtenue.
    def crawl(visitor : Visitor, variant : String, seeds : Array(String) = [] of String) : Nil
      queue = Deque(String).new
      routes.each { |route| queue << route.pattern if explorable?(route) && !route.parameters? }
      seeds.each { |seed| queue << seed }
      plain = Hash(String, Int32).new(0)
      seen = Set(String).new
      while url = queue.shift?
        path, _, query = url.partition('?')
        route = route_for(path)
        next unless route && explorable?(route)
        key = query.empty? ? url : "#{route.name}?#{URI::Params.parse(query).map { |name, _| name }.uniq!.sort!.join('&')}"
        next if seen.includes?(key) || (query.empty? && plain[route.name] >= PER_ROUTE)
        seen << key
        plain[route.name] += 1 if query.empty?
        html = check_all(visitor, route, url, variant)
        links(html).each { |link| queue << link } if html
      end
    end

    # Chaque route, paramètres remplacés par des valeurs qui ne désignent
    # rien : pages d'accès, de jeton invalide et d'erreur.
    def visit_placeholders(visitor : Visitor, variant : String) : Nil
      routes.each do |route|
        check_all(visitor, route, route.placeholder_url, variant) if explorable?(route)
      end
    end

    # Adresses données, sans suivre leurs liens.
    def visit(visitor : Visitor, variant : String, urls : Array(String)) : Nil
      urls.each do |url|
        route = route_for(url.partition('?')[0]) || raise ArgumentError.new("adresse sans route : #{url}")
        check_all(visitor, route, url, variant) if explorable?(route)
      end
    end

    # Une adresse, dans chaque langue ; la langue active du processus est
    # rétablie ensuite. Les formulaires de la page sont relevés.
    def check_all(visitor : Visitor, route : Route, url : String, variant : String) : String?
      previous = I18n.locale
      html = check_locales(visitor, route, url, variant)
      collect_forms(html, url, variant) if html
      html
    ensure
      I18n.activate(previous) if previous
    end

    private def check_locales(visitor : Visitor, route : Route, url : String, variant : String) : String?
      first = nil
      LOCALES.each_with_index do |locale, index|
        response = begin
          visitor.get.call(url, locale)
        rescue ex
          failures << "#{variant} #{route.name} #{url} [#{locale}] : #{ex.class} #{ex.message}"
          return
        end
        status = response.status
        reached << route.name if status < 400
        failures << "#{variant} #{route.name} #{url} [#{locale}] : erreur #{status}" if status >= 500
        return unless html?(response)
        @checked += 1
        checked_routes << route.name
        PartiduoTranslations.problems(response.content).each do |problem|
          failures << "#{variant} #{route.name} #{url} [#{locale}] : #{problem}"
        end
        first = response.content if index == 0
      end
      first
    end

    def unreached : Array(String)
      routes.select { |route| explorable?(route) && !reached.includes?(route.name) }.map do |route|
        "#{route.name} (#{route.pattern})"
      end
    end

    def report : String
      "#{checked_routes.size} routes, #{checked} pages contrôlées (adresse × langue), " \
      "#{all_forms.size} formulaires relevés sur #{sent_routes.size} routes d'envoi, " \
      "#{submitted} envois contrôlés (formulaire × valeurs × variante × langue), " \
      "#{Probe.lookups} recherches de traduction sondées"
    end

    private def html?(response : Marten::HTTP::Response) : Bool
      response.content_type.to_s.includes?("text/html") && !response.headers.has_key?("Content-Disposition")
    end

    # Liens internes d'une page : `href`, `hx-get`, `src`, `action`, sans
    # ancre ni export (`format=`).
    private def links(html : String) : Array(String)
      found = [] of String
      html.scan(/\s(?:href|hx-get|src|action)\s*=\s*"([^"]*)"/) do |match|
        link = HTML.unescape(match[1]).split('#').first
        next if !internal?(link)
        next if link.includes?("format=")
        found << link
      end
      found
    end

    # --- Envois de formulaires ---------------------------------------------------

    # Champ d'un formulaire relevé dans une page : nom, type (`select`,
    # `textarea`, type d'un `input`), valeur initiale.
    record Field, name : String, type : String, value : String do
      # Champ rempli par une personne (ni caché, ni bouton, ni fichier).
      def editable? : Bool
        !%w[hidden submit button reset image file].includes?(type)
      end
    end

    # Formulaire `POST` relevé dans une page : adresse d'envoi, champs,
    # envoi par HTMX (`hx-post` ou `hx-boost`), page d'origine, variante
    # du jeu de données qui l'a vu.
    record PostForm, action : String, fields : Array(Field), htmx : Bool, page : String, variant : String do
      def editable? : Bool
        fields.any?(&.editable?)
      end

      def names : Array(String)
        fields.map(&.name).uniq!.sort!
      end
    end

    CSRF_FIELD = "csrftoken"

    # Formulaires relevés pas encore envoyés ; tous les formulaires relevés.
    getter forms = [] of PostForm
    getter all_forms = [] of PostForm
    @form_keys = Set(String).new
    # Envois contrôlés : formulaire × valeurs × variante × langue.
    getter submitted = 0
    # Routes d'envoi effectivement atteintes.
    getter sent_routes = Set(String).new

    # Formulaires `POST` d'une page : un par adresse d'envoi (identifiants
    # numériques confondus) et par forme de champs.
    def collect_forms(html : String, page : String, variant : String) : Nil
      post_forms(html, page, variant).each do |form|
        route = route_for(form.action.partition('?')[0])
        next if route.nil? || @unsent.has_key?(route.name)
        key = "#{form.action.partition('?')[0].gsub(/\d+/, "N")} #{form.names.join(',')}"
        next if @form_keys.includes?(key)
        @form_keys << key
        @forms << form
        @all_forms << form
      end
    end

    # Envoie chaque formulaire, dans chaque langue : vide, puis avec des
    # valeurs fausses (texte trop long, nombre, date et courriel invalides,
    # choix inexistant) ; un formulaire sans champ à remplir (bouton
    # d'action : supprimer, approuver, révoquer…) tel quel, après tous les
    # autres. Avant chaque envoi, la page d'origine est obtenue dans la
    # langue de l'envoi (jeton CSRF de son navigateur, champs cachés).
    # Contrôlés : la réponse (erreurs du formulaire, refus), la page où elle
    # redirige (message flash), la réponse partielle à une requête HTMX et
    # sa redirection (`HX-Redirect`) ; une erreur 500 est un échec.
    #
    # `forms` : par défaut, ceux qui n'ont pas encore été envoyés ;
    # `all_forms` (ou une partie) pour les renvoyer avec un autre compte.
    def submit_forms(visitor : Visitor, variant : String, forms : Array(PostForm)? = nil) : Nil
      pending = (forms || @forms).sort_by { |form| form.editable? ? 0 : 1 }
      @forms = [] of PostForm if forms.nil?
      previous = I18n.locale
      pending.each do |form|
        route = route_for(form.action.partition('?')[0]) || next
        sent_routes << route.name
        kinds = form.editable? ? ["vide", "valeurs fausses"] : ["tel quel"]
        kinds.each do |kind|
          LOCALES.each do |locale|
            fields = refreshed(visitor, form, locale)
            values = case kind
                     when "vide"            then blank(fields)
                     when "valeurs fausses" then wrong(fields)
                     else                        fields.map { |field| {field.name, field.value} }
                     end
            body = URI::Params.build { |params| values.each { |name, value| params.add(name, value) } }
            where = "#{variant} #{route.name} POST #{form.action} (#{kind}, depuis #{form.page}) [#{locale}]"
            send(visitor, where, form.action, body, locale, htmx: false)
            send(visitor, where + " HTMX", form.action, body, locale, htmx: true) if form.htmx
          end
        end
      end
    ensure
      I18n.activate(previous) if previous
    end

    # Champs du même formulaire dans la page d'origine obtenue dans la
    # langue de l'envoi ; à défaut (page refusée à ce compte, objet
    # disparu), ceux relevés, jeton CSRF remplacé par celui du navigateur
    # de cette langue s'il en a un.
    private def refreshed(visitor : Visitor, form : PostForm, locale : String) : Array(Field)
      html = visitor.get.call(form.page, locale).content
      same = post_forms(html, form.page, form.variant).find { |other| other.action == form.action && other.names == form.names }
      return same.fields if same
      token = html.match(/name="#{CSRF_FIELD}" value="([^"]*)"/).try(&.[1])
      form.fields.map { |field| field.name == CSRF_FIELD && token ? Field.new(field.name, field.type, token) : field }
    rescue
      form.fields
    end

    private def send(visitor : Visitor, where : String, action : String, body : String, locale : String,
                     htmx : Bool) : Nil
      headers = htmx ? {"HX-Request" => "true"} : {} of String => String
      response = visitor.post.call(action, body, locale, headers)
      @submitted += 1
      inspect_response(response, where)
      target = response.headers["HX-Redirect"]? || (response.status.in?(300..399) ? response.headers["Location"]? : nil)
      return unless target && internal?(target)
      inspect_response(visitor.get.call(target, locale), "#{where} → #{target}")
    rescue ex
      failures << "#{where} : #{ex.class} #{ex.message}"
    end

    private def inspect_response(response : Marten::HTTP::Response, where : String) : Nil
      failures << "#{where} : erreur #{response.status}" if response.status >= 500
      return unless html?(response)
      PartiduoTranslations.problems(response.content).each { |problem| failures << "#{where} : #{problem}" }
    end

    # Champs à remplir vidés ; champs cachés gardés (identifiants, jeton),
    # cases décochées.
    private def blank(fields : Array(Field)) : Array(Tuple(String, String))
      fields.compact_map do |field|
        next if field.type.in?("checkbox", "radio", "submit", "button", "reset", "image", "file")
        {field.name, field.editable? ? "" : field.value}
      end
    end

    # Valeurs refusées par les contrôles : texte trop long, nombre, date,
    # mois et courriel invalides, choix qui n'existe pas.
    private def wrong(fields : Array(Field)) : Array(Tuple(String, String))
      fields.compact_map do |field|
        next if field.type.in?("submit", "button", "reset", "image", "file")
        value = case field.type
                when "hidden"            then field.value
                when "checkbox", "radio" then field.value.presence || "on"
                else                          WRONG.fetch(field.type, "x" * 600)
                end
        {field.name, value}
      end
    end

    # Valeur fausse par type de champ ; texte trop long pour les autres.
    WRONG = {
      "number" => "abc", "range" => "abc", "date" => "2026-13-45", "datetime-local" => "2026-13-45",
      "month" => "2026-13", "time" => "25:99", "email" => "pas-un-courriel", "url" => "pas une adresse",
      "select" => "999999999",
    }

    # Formulaires `POST` internes d'une page (`method="post"`, `hx-post`).
    private def post_forms(html : String, page : String, variant : String) : Array(PostForm)
      found = [] of PostForm
      html.scan(/<form\b([^>]*)>(.*?)<\/form>/mi) do |match|
        attributes = match[1]
        htmx_action = attribute(attributes, "hx-post")
        next unless htmx_action || attribute(attributes, "method").try(&.downcase) == "post"
        action = htmx_action || attribute(attributes, "action").presence || page
        next unless internal?(action)
        htmx = !htmx_action.nil? || attribute(attributes, "hx-boost") == "true"
        found << PostForm.new(action, form_fields(match[2]), htmx, page, variant)
      end
      found
    end

    private def form_fields(html : String) : Array(Field)
      fields = [] of Field
      html.scan(/<(input|select|textarea|button)\b([^>]*)>/mi) do |match|
        name = attribute(match[2], "name")
        next if name.nil? || name.empty?
        tag = match[1].downcase
        type = case tag
               when "input"  then attribute(match[2], "type").try(&.downcase) || "text"
               when "button" then "hidden" # bouton nommé : sa valeur part avec l'envoi
               else               tag
               end
        fields << Field.new(name, type, attribute(match[2], "value") || "")
      end
      fields
    end

    # Adresse du site (chemin absolu, sans hôte).
    private def internal?(url : String) : Bool
      url.starts_with?('/') && !url.starts_with?("//")
    end

    private def attribute(attributes : String, name : String) : String?
      attributes.match(/(?:^|\s)#{name}\s*=\s*(?:"([^"]*)"|'([^']*)')/i).try do |match|
        HTML.unescape(match[1]? || match[2]? || "")
      end
    end
  end
end

# Sonde des traductions (`PartiduoTranslations::Probe`) : chaque recherche
# passe par `I18n::Catalog`.
class I18n::Catalog
  def translate!(key : String | Symbol, params : (Hash | NamedTuple)? = nil, count : (Float | Int)? = nil,
                 scope : (Array(String | Symbol) | String | Symbol)? = nil, default = nil, **kwargs) : String
    full = case scope
           when Array then (scope.map(&.to_s) + [key.to_s]).join('.')
           when Nil   then key.to_s
           else            "#{scope}.#{key}"
           end
    names = kwargs.keys.map(&.to_s).to_set
    params.try &.each_key { |name| names << name.to_s }
    names << "count" unless count.nil?
    PartiduoTranslations::Probe.translate(full, names, count, default)
    previous_def
  end

  private def fetch_translation(locale, key, count = nil, default = nil, ongoing_fallback = false)
    PartiduoTranslations::Probe.quietly { previous_def }
  end

  private def fetch_translation!(locale, key, count = nil, default = nil, ongoing_fallback = false)
    PartiduoTranslations::Probe.lookup(key.to_s, count, default) unless ongoing_fallback
    previous_def
  end
end

# Rapport après le résumé des specs (crochet de sortie posé en fin de
# suite), pour ne pas le masquer.
Spec.after_suite do
  at_exit do
    failures = PartiduoTranslations::Probe.report
    next if failures.empty?
    STDERR.puts "\nTraductions absentes ou incomplètes relevées pendant la suite " \
                "(#{failures.size}, sonde de spec/support/translations.cr) :"
    failures.each { |failure| STDERR.puts "  #{failure}" }
    exit 1
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

require "html"
require "yaml"

# Contrôle des traductions (fr, en, nl) de la console d'administration et
# de connect, deux programmes Marten à part (`spec/`, `spec-connect/`, qui
# requiert ce fichier). Même contrôle que celui de l'interface des dossiers
# (`partiduo-ui-bulma`, spec/support/translations.cr), dont l'administration
# ne dépend pas (ADR-008 D1) :
#
# . *statique* (`parity_failures`, `unknown_keys`) : les fichiers de
#   locales ont les mêmes clés et les mêmes interpolations dans chaque
#   langue ; chaque clé citée par le code ou les gabarits (`I18n.t("…")`,
#   `{% translate "…" %}`) existe dans chaque langue ;
# . *dynamique* (`Explorer`) : toutes les routes du routeur de Marten,
#   pages à paramètres atteintes par les liens des pages du jeu de données,
#   chaque page obtenue dans chaque langue ; le HTML rendu ne doit contenir
#   ni marqueur de traduction absente, ni clé brute, ni interpolation non
#   résolue. Une route servie en `GET` qu'aucun lien n'atteint fait échouer
#   le contrôle, sauf exclusion motivée.
module PartiduoTranslations
  LOCALES = %w[fr en nl]

  # Marqueur rendu par crystal-i18n pour une clé absente.
  MISSING = /(?:missing translation|translation missing):\s*([\w.\-]+)/i

  INTERPOLATION = /%\{[^}]*\}/

  # Attributs lus par une personne (les autres, techniques ou `data-*`, ne
  # sont pas contrôlés).
  HUMAN_ATTRIBUTES = %w[title placeholder aria-label aria-description aria-placeholder alt label]

  # --- Catalogue chargé -----------------------------------------------------------

  @@catalog : Hash(String, Set(String))? = nil
  @@namespaces : Set(String)? = nil

  # Clés de toutes les traductions chargées, par langue : feuilles et
  # nœuds (clés de pluriel, sous-arbres).
  def self.catalog : Hash(String, Set(String))
    @@catalog ||= begin
      keys = Hash(String, Set(String)).new { |hash, locale| hash[locale] = Set(String).new }
      I18n.config.loaders.each do |loader|
        loader.load.each do |locale, data|
          flatten(data, "", keys[locale]) if data.is_a?(Hash)
        end
      end
      keys
    end
  end

  def self.namespaces : Set(String)
    @@namespaces ||= catalog.values.flat_map(&.map(&.split('.').first)).to_set
  end

  def self.known?(locale : String, key : String) : Bool
    catalog[locale].includes?(key)
  end

  private def self.flatten(data : I18n::TranslationsHash, prefix : String, into : Set(String)) : Nil
    data.each do |name, value|
      key = prefix.empty? ? name : "#{prefix}.#{name}"
      into << key
      flatten(value, key, into) if value.is_a?(Hash)
    end
  end

  # --- Contrôle statique ------------------------------------------------------------

  # Fichiers `fr.yml`, `en.yml`, `nl.yml` d'un répertoire : mêmes clés,
  # mêmes interpolations.
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

  # Clés citées par les fichiers `globs` (relatifs à `root`) absentes du
  # catalogue chargé dans une langue au moins ; commentaires écartés.
  # `namespaces` : premiers segments contrôlés (ceux du programme), dont
  # tout littéral (`"admin.menu.users"`, passé à une aide) est une clé.
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

  # --- Exploration ------------------------------------------------------------------

  # Explore les pages d'un jeu de données dans chaque langue. Chaque passage
  # reçoit une fonction qui obtient une adresse dans une langue (navigateur
  # propre à chaque langue : la langue d'un compte connecté prime sur le
  # cookie).
  class Explorer
    PER_ROUTE = 4

    alias Fetch = String, String -> Marten::HTTP::Response

    getter routes : Array(Route)
    getter exclusions : Hash(String, String)
    getter failures = [] of String
    getter reached = Set(String).new
    getter checked = 0
    getter checked_routes = Set(String).new

    def initialize(@exclusions : Hash(String, String) = {} of String => String, @routes : Array(Route) = PartiduoTranslations.routes)
      @routes = @routes.reject { |route| GLUE.includes?(route.handler.name) }
      unknown = @exclusions.keys - @routes.map(&.name)
      raise ArgumentError.new("exclusions sans route : #{unknown.join(", ")}") unless unknown.empty?
    end

    def explorable?(route : Route) : Bool
      route.serves_get? && !exclusions.has_key?(route.name)
    end

    def route_for(path : String) : Route?
      routes.find(&.regex.matches?(path))
    end

    # Routes sans paramètre, `seeds`, puis les liens de chaque page obtenue.
    def crawl(variant : String, seeds : Array(String) = [] of String, &fetch : Fetch) : Nil
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
        html = check_all(route, url, variant, fetch)
        links(html).each { |link| queue << link } if html
      end
    end

    # Chaque route, paramètres remplacés par des valeurs qui ne désignent
    # rien : pages d'accès, de jeton invalide et d'erreur.
    def visit_placeholders(variant : String, &fetch : Fetch) : Nil
      routes.each do |route|
        check_all(route, route.placeholder_url, variant, fetch) if explorable?(route)
      end
    end

    # Adresses données, sans suivre leurs liens.
    def visit(variant : String, urls : Array(String), &fetch : Fetch) : Nil
      urls.each do |url|
        route = route_for(url.partition('?')[0]) || raise ArgumentError.new("adresse sans route : #{url}")
        check_all(route, url, variant, fetch) if explorable?(route)
      end
    end

    # Une adresse, dans chaque langue ; la langue active du processus est
    # rétablie ensuite.
    def check_all(route : Route, url : String, variant : String, fetch : Fetch) : String?
      previous = I18n.locale
      check_locales(route, url, variant, fetch)
    ensure
      I18n.activate(previous) if previous
    end

    private def check_locales(route : Route, url : String, variant : String, fetch : Fetch) : String?
      first = nil
      LOCALES.each_with_index do |locale, index|
        response = begin
          fetch.call(url, locale)
        rescue ex
          failures << "#{variant} #{route.name} #{url} [#{locale}] : #{ex.class} #{ex.message}"
          return
        end
        status = response.status
        reached << route.name if status < 400
        failures << "#{variant} #{route.name} #{url} [#{locale}] : erreur #{status}" if status >= 500
        return if !response.content_type.to_s.includes?("text/html") || response.headers.has_key?("Content-Disposition")
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
      "#{checked_routes.size} routes, #{checked} pages contrôlées (adresse × langue)"
    end

    private def links(html : String) : Array(String)
      found = [] of String
      html.scan(/\s(?:href|hx-get|src|action)\s*=\s*"([^"]*)"/) do |match|
        link = HTML.unescape(match[1]).split('#').first
        next if !link.starts_with?('/') || link.starts_with?("//")
        next if link.includes?("format=")
        found << link
      end
      found
    end
  end
end

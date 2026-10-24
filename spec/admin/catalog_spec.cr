# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Catalogue des pièces (D-ADM-016) : seule source des règles du choix des
# modules et extensions, comparée aux manifestes des dépôts voisins quand
# ils sont là ; contrôles serveur, formulaires sans JavaScript.

# Manifestes des dépôts voisins (`partiduo-app/src/<module>/manifest.cr`,
# `partiduo-<extension>/src/<extension>/manifest.cr`), lus comme du texte.
module CatalogManifests
  WORKSPACE = File.expand_path("../../..", __DIR__)
  APP       = File.join(WORKSPACE, "partiduo-app")

  record Declared, code : String, official : Bool, socle : Bool, depends_on : Array(String),
    depends_on_any : Array(Array(String)), incompatible_with : Array(String), excluded_kinds : Array(String),
    regimes : Array(String)

  def self.present? : Bool
    Dir.exists?(File.join(APP, "src"))
  end

  def self.files : Array(String)
    Dir.glob(File.join(WORKSPACE, "partiduo-*/src/*/manifest.cr")).reject do |path|
      path.includes?("/lib/") || path.ends_with?("partiduo-app/src/modules/manifest.cr")
    end.sort!
  end

  def self.codes(list : String) : Array(String)
    list.scan(/"([A-Za-z0-9_]+)"/).map(&.[1].downcase)
  end

  def self.parse(path : String) : Declared
    source = File.read_lines(path).reject(&.lstrip.starts_with?('#')).join('\n')
    code = source.match(/^\s*code\s+"([A-Z0-9_]+)"/m).try(&.[1]) || raise "code absent : #{path}"
    statements = {} of String => Array(String)
    source.scan(/^\s*(depends_on_any|depends_on|incompatible_with_kind|incompatible_with|regimes)\s+("[^"]+"(?:\s*,\s*"[^"]+")*)/m) do |match|
      (statements[match[1]] ||= [] of String) << match[2]
    end
    list = ->(name : String) { (statements[name]? || [] of String).flat_map { |text| codes(text) } }
    Declared.new(code.downcase, source.includes?("Kind::Module"), source.includes?("Kind::Socle"),
      list.call("depends_on"), (statements["depends_on_any"]? || [] of String).map { |text| codes(text) },
      list.call("incompatible_with"), list.call("incompatible_with_kind"), list.call("regimes"))
  end

  # Pièces que la console peut proposer : ni socle ni extension d'exemple.
  def self.declared : Hash(String, Declared)
    files.map { |path| parse(path) }.reject { |piece| piece.socle || piece.code == "skel" }.to_h { |piece| {piece.code, piece} }
  end

  # Type foyer du cœur : `register_kind(HOUSEHOLD, …, required:, excluded:)`.
  def self.household : {Array(String), Array(String)}
    source = File.read(File.join(APP, "src/core/initial_data.cr"))
    match = source.match(/register_kind\([^)]*HOUSEHOLD[^)]*required:\s*%w\[([^\]]*)\][^)]*excluded:\s*%w\[([^\]]*)\]/m) ||
            raise "type foyer introuvable"
    {match[1].split.map(&.downcase), match[2].split.map(&.downcase)}
  end
end

# Guillemets français du catalogue : espaces insécables.
private def fr(text : String) : String
  text.gsub("« ", "«\u00a0").gsub(" »", "\u00a0»")
end

private def problem_keys(kind : String, codes : Array(String), regime : String? = "fr") : Array(String)
  PartiduoAdmin::Catalog.problems(kind, regime, codes).map { |problem| "#{problem.key} #{problem.piece} #{problem.others.join(',')}".strip }
end

describe "Catalogue des pièces (D-ADM-016)" do
  it "reprend les modules officiels du protocole" do
    PartiduoAdmin::Catalog::PIECES.select(&.official).map(&.code).sort!.should eq(PartiduoAdmin::Protocol::MODULES.sort)
    PartiduoAdmin::Catalog::PIECES.map(&.family).uniq!.should eq(PartiduoAdmin::Catalog::FAMILIES)
    PartiduoAdmin::Catalog::KINDS.keys.sort!.should eq(PartiduoAdmin::Protocol::DOSSIER_KINDS.sort)
  end

  it "suit les manifestes des dépôts voisins, s'ils sont là : pièces, dépendances, incompatibilités, types exclus, régimes" do
    next unless CatalogManifests.present?
    declared = CatalogManifests.declared
    catalog = PartiduoAdmin::Catalog::BY_CODE
    {catalog.keys.sort!, "pièces"}.should eq({declared.keys.sort!, "pièces"})
    declared.each do |code, piece|
      known = catalog[code]
      {code, known.official, known.depends_on.sort, known.depends_on_any.map(&.sort), known.incompatible_with.sort, known.excluded_kinds.sort,
       known.regimes.sort}
        .should eq({code, piece.official, piece.depends_on.sort, piece.depends_on_any.map(&.sort), piece.incompatible_with.sort,
                    piece.excluded_kinds.sort, piece.regimes.sort})
    end
  end

  it "range en choix exclusif des pièces deux à deux incompatibles d'une même famille" do
    PartiduoAdmin::Catalog::CHOICES.each do |choice, codes|
      PartiduoAdmin::Catalog.choice(choice).map(&.code).should eq(codes)
      codes.map { |code| PartiduoAdmin::Catalog.piece(code).family }.uniq!.size.should eq(1)
      codes.each_permutation(2) do |(code, other)|
        {code, other, PartiduoAdmin::Catalog.conflicts(code).includes?(other)}.should eq({code, other, true})
      end
    end
    PartiduoAdmin::Catalog::PIECES.compact_map(&.choice).uniq!.sort!.should eq(PartiduoAdmin::Catalog::CHOICES.keys.sort!)
    PartiduoAdmin::Catalog::REGIMES.should eq(%w[fr be])
  end

  it "suit le type foyer du cœur, et aucune extension n'en exclut d'autre pièce" do
    next unless CatalogManifests.present?
    required, excluded = CatalogManifests.household
    rule = PartiduoAdmin::Catalog::KINDS["household"]
    rule.required.sort.should eq(required.sort)
    rule.excluded.sort.should eq(excluded.sort)
    # `InitialData.exclude` ou `register_kind` dans une extension : à
    # reporter au catalogue.
    Dir.glob(File.join(CatalogManifests::WORKSPACE, "partiduo-*/src/**/*.cr")).each do |path|
      next if path.includes?("/lib/") || path.includes?("/partiduo-app/")
      source = File.read(path)
      {path, source.includes?("InitialData.exclude(") || source.includes?("InitialData.register_kind(")}.should eq({path, false})
    end
  end

  it "requiert la Comptabilité d'un foyer et en écarte les modules d'entreprise" do
    problem_keys("household", %w[invoicing perso]).should eq([
      "kind_requires accounting", "kind_excludes invoicing", "requires perso accounting", "requires perso bankimport",
      "incompatible invoicing perso",
    ])
    problem_keys("household", %w[accounting amortis]).should eq(["kind_excludes amortis"])
    problem_keys("household", %w[accounting bankimport perso sepa teledec]).should eq(["kind_excludes teledec", "incompatible perso teledec"])
    problem_keys("household", %w[accounting bankimport perso sepa]).should be_empty
    problem_keys("company", %w[accounting amortis]).should be_empty
  end

  it "écarte d'un foyer les services d'entreprise, même sans PERSO, et réserve PERSO aux foyers" do
    %w[teledec einv superpdp esalink modeles crm choruspro urssaf].each do |code|
      PartiduoAdmin::Catalog.excluded?(code, "household").should be_true
    end
    problem_keys("household", %w[accounting document einv modeles]).should eq(["kind_excludes einv", "kind_excludes modeles"])
    problem_keys("company", %w[accounting bankimport perso]).should eq(["kind_excludes perso"])
    PartiduoAdmin::Catalog.excluded_kinds("perso").should eq(["company"])
  end

  it "réserve au régime fr les services de l'administration française" do
    %w[urssaf teledec choruspro].each { |code| PartiduoAdmin::Catalog.regimes(code).should eq(["fr"]) }
    problem_keys("company", %w[micro urssaf], "be").should eq(["regime_excludes urssaf"])
    problem_keys("company", %w[accounting teledec invoicing choruspro], "be").should eq(["regime_excludes teledec", "regime_excludes choruspro"])
    problem_keys("company", %w[micro urssaf], "fr").should be_empty
    # Régime invalide, déjà refusé par le formulaire : non jugé.
    problem_keys("company", %w[micro urssaf], nil).should be_empty
    unavailable = PartiduoAdmin::Catalog.unavailable("company", "be")
    %w[urssaf teledec choruspro perso].each { |code| unavailable.should contain(code) }
    unavailable.should_not contain("micro")
    unavailable.should_not contain("einv")
  end

  it "contrôle les dépendances, toutes ou l'une d'un groupe" do
    problem_keys("company", %w[analytic]).should eq(["requires analytic accounting"])
    problem_keys("company", %w[stock]).should eq(["requires_any stock invoicing,accounting"])
    problem_keys("company", %w[invoicing stock]).should be_empty
    problem_keys("company", %w[micro teledec]).should eq(["requires_any teledec accounting,liberal"])
    problem_keys("company", %w[liberal teledec]).should be_empty
    problem_keys("company", %w[accounting superpdp]).should eq(["requires superpdp einv"])
    problem_keys("company", %w[accounting superpdp einv]).should eq(["requires einv document"])
    problem_keys("company", %w[accounting document einv superpdp esalink]).should be_empty
  end

  it "contrôle les incompatibilités dans les deux sens, et ignore les extensions inconnues" do
    problem_keys("company", %w[accounting micro liberal]).should eq(["incompatible micro liberal"])
    problem_keys("company", %w[liberal accounting micro]).should eq(["incompatible liberal micro"])
    problem_keys("household", %w[accounting bankimport perso invoicing]).should eq(["kind_excludes invoicing", "incompatible perso invoicing"])
    PartiduoAdmin::Catalog.conflicts("invoicing").should eq(["perso"])
    PartiduoAdmin::Catalog.conflicts("micro").should eq(["liberal", "perso"])
    problem_keys("company", %w[accounting skel maison]).should be_empty
    # La Comptabilité se cumule avec la micro-entreprise ou la profession
    # libérale (ADR-007 D3, D6), qui ne se cumulent pas entre elles.
    problem_keys("company", %w[accounting micro]).should be_empty
    problem_keys("company", %w[accounting liberal]).should be_empty
  end

  it "écarte d'un foyer les pièces exclues et celles qui en dépendent, et d'une entreprise les finances du foyer" do
    unavailable = PartiduoAdmin::Catalog.unavailable("household")
    %w[invoicing micro liberal stock followup analytic amortis crm choruspro urssaf teledec einv superpdp esalink modeles].each do |code|
      unavailable.should contain(code)
    end
    %w[accounting bankimport sepa perso document import reports form].each do |code|
      unavailable.should_not contain(code)
    end
    PartiduoAdmin::Catalog.unavailable("company").should eq(Set{"perso"})
  end

  it "rédige les messages dans la langue courante" do
    message = ->(problem : PartiduoAdmin::Catalog::Problem) { PartiduoAdmin::Catalog.message(problem.encoded) }
    stock = PartiduoAdmin::Catalog::Problem.new("requires_any", "stock", %w[invoicing accounting])
    excluded = PartiduoAdmin::Catalog::Problem.new("kind_excludes", "invoicing", kind: "household")
    regime = PartiduoAdmin::Catalog::Problem.new("regime_excludes", "urssaf", regime: "be")
    I18n.with_locale("fr") do
      message.call(stock).should eq(fr("« Stock » requiert « Facturation » ou « Comptabilité »."))
      message.call(excluded).should eq(fr("« Facturation » n'est pas admis dans un dossier « Foyer »."))
      message.call(regime).should eq(fr("« URSSAF » n'est pas admis dans un dossier « Belgique »."))
    end
    I18n.with_locale("en") { message.call(stock).should eq("“Stock” requires “Invoicing” or “Accounting”.") }
    I18n.with_locale("de") { message.call(excluded).should eq("„Fakturierung“ ist in einem Mandanten „Haushalt“ nicht zulässig.") }
    I18n.with_locale("nl") { message.call(regime).should eq("‘URSSAF’ is niet toegestaan in een dossier ‘België’.") }
    PartiduoAdmin::Catalog.message("admin.errors.required").should be_nil
  end
end

private def creation_data(server, payer, slug : String, kind : String, modules : Array(String), extensions = [] of String)
  {"slug" => slug, "label" => "Essai #{slug}", "regime" => "fr", "locale" => "fr", "kind" => kind,
   "modules" => modules, "extensions" => extensions, "admin_email" => "gerant@#{slug}.fr",
   "server_id" => server.pk.to_s, "payer_id" => payer.pk.to_s, "backup_schedule" => "daily", "backup_retention_days" => "30"}
end

describe "Choix des modules et extensions par familles, sans JavaScript (D-ADM-016)" do
  it "présente la création par familles, type et régime en boutons radio, code visible en petit" do
    firm = AdminSpec.firm
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)))
    html = browser.get("/dossiers/new").html
    html.should contain(%(<input type="radio" name="kind" value="household"))
    html.should contain(%(<input type="radio" name="regime" value="be"))
    %w[keeping management declarations einvoicing banking household tools].each do |family|
      html.should contain(%(<fieldset class="pd-fieldset pd-family" id="family-#{family}"))
    end
    html.should contain("<legend>Régime et tenue des comptes</legend>")
    html.should contain(%(<code class="pd-piece-code">analytic</code>))
    # Micro-entreprise ou profession libérale : boutons radio, « ni l'un ni
    # l'autre » coché par défaut ; la Comptabilité reste une case.
    html.should contain(%(<input type="radio" id="p-micro" name="modules" value="micro"))
    html.should contain(%(<input type="radio" id="p-liberal" name="modules" value="liberal"))
    html.should contain(%(<input type="radio" id="choice-scheme-none" name="modules" value="" checked data-pd-none="scheme">))
    html.should contain(%(<input type="checkbox" id="p-accounting" name="modules" value="accounting"))
    html.should contain("<legend>Régime d'imposition</legend>")
    html.should_not contain(fr("Incompatible avec « Profession libérale (2035) »"))
    html.should contain(%(data-regimes="fr" data-choice=""))
    html.should contain(fr("Seulement pour un dossier « France »."))
    html.should contain(fr("Non admis dans un dossier « Entreprise »."))
    html.should contain(%(name="extensions" value="perso"))
    html.should contain(%(data-requires="accounting bankimport"))
    html.should contain(%(data-requires-any="invoicing,accounting"))
    html.should contain(fr("Requiert « Comptabilité »."))
    html.should contain(fr("Non admis dans un dossier « Foyer »."))
    html.should contain(fr("Requis pour un dossier « Foyer »."))
    html.should contain(%(src="/assets/admin/js/pieces.js"))
  end

  it "refuse côté serveur, avec un message par famille, et crée quand les règles sont tenues" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    payer = AdminSpec.payer(firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)))
    refused = browser.post("/dossiers/new", creation_data(server, payer, "pieces-foyer", "household", %w[accounting invoicing], %w[perso]))
    refused.status.should eq(422)
    html = refused.html
    html.should contain(fr("« Facturation » n'est pas admis dans un dossier « Foyer »."))
    html.should contain(fr("« Finances du foyer » requiert « Import des relevés bancaires »."))
    html.should contain(fr("« Facturation » est incompatible avec « Finances du foyer »."))
    html.should contain(%(aria-describedby="family-household-help family-household-error"))
    html.should contain(%(id="p-perso" name="extensions" value="perso" checked))
    refused = browser.post("/dossiers/new", creation_data(server, payer, "pieces-stock", "company", %w[analytic stock]))
    refused.status.should eq(422)
    refused.html.should contain(fr("« Analytique » requiert « Comptabilité »."))
    refused.html.should contain(fr("« Stock » requiert « Facturation » ou « Comptabilité »."))
    # Micro-entreprise et profession libérale envoyées ensemble (sans le
    # navigateur) ; services français pour un dossier belge.
    refused = browser.post("/dossiers/new", creation_data(server, payer, "pieces-regimes", "company", ["accounting", "micro", "liberal", ""]))
    refused.status.should eq(422)
    refused.html.should contain(fr("« Micro-entreprise » est incompatible avec « Profession libérale (2035) »."))
    belgian = creation_data(server, payer, "pieces-belge", "company", %w[micro], %w[urssaf]).merge({"regime" => "be"})
    refused = browser.post("/dossiers/new", belgian)
    refused.status.should eq(422)
    refused.html.should contain(fr("« URSSAF » n'est pas admis dans un dossier « Belgique »."))
    PartiduoAdmin::Dossier.filter(slug__in: %w[pieces-foyer pieces-stock pieces-regimes pieces-belge]).exists?.should be_false

    # « Ni l'un ni l'autre » (valeur vide) est ignoré.
    created = browser.post("/dossiers/new", creation_data(server, payer, "pieces-aucun", "company", ["accounting", ""]))
    created.status.should eq(302)
    PartiduoAdmin::Dossier.get!(slug: "pieces-aucun").modules.should eq("accounting")

    # Extension connue saisie comme autre extension, module saisi en texte :
    # rangés à leur place.
    created = browser.post("/dossiers/new", creation_data(server, payer, "pieces-foyer", "household", %w[accounting], ["perso, bankimport", "skel"]))
    created.status.should eq(302)
    dossier = PartiduoAdmin::Dossier.get!(slug: "pieces-foyer")
    dossier.modules.should eq("accounting")
    dossier.extensions.should eq("perso,bankimport,skel")
  end

  it "ne propose à un foyer que les pièces admises, la Comptabilité verrouillée, et contrôle l'enregistrement" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    dossier.kind = "household"
    dossier.modules = "accounting"
    dossier.save!
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)))
    html = browser.get("/dossiers/#{dossier.pk}/modules").html
    %w[invoicing micro liberal stock amortis crm choruspro urssaf teledec einv superpdp esalink modeles].each do |code|
      html.should_not contain(%(id="p-#{code}"))
    end
    %w[perso bankimport sepa document].each { |code| html.should contain(%(id="p-#{code}")) }
    html.should_not contain(%(id="choice-scheme"))
    html.should_not contain(%(id="family-management"))
    html.should contain(%(id="family-keeping"))
    html.should contain(%(value="accounting" checked disabled data-pd-locked))
    html.should contain(%(<input type="hidden" name="modules" value="accounting">))
    html.should contain(%(data-kind="household"))
    html.should contain("Désactiver un module conserve ses données, en lecture seule.")

    refused = browser.post("/dossiers/#{dossier.pk}/modules", {"modules" => ["accounting"], "extensions" => ["perso"]})
    refused.status.should eq(422)
    refused.html.should contain(fr("« Finances du foyer » requiert « Import des relevés bancaires »."))
    refused = browser.post("/dossiers/#{dossier.pk}/modules", {"modules" => ["accounting", "invoicing"]})
    refused.status.should eq(422)
    refused.html.should contain(fr("« Facturation » n'est pas admis dans un dossier « Foyer »."))
    # Une pièce choisie mais non admise reste affichée, pour être retirée.
    refused.html.should contain(%(id="p-invoicing"))

    done = browser.post("/dossiers/#{dossier.pk}/modules", {"modules" => ["accounting"], "extensions" => ["perso", "bankimport"]})
    done.status.should eq(302)
    task = PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "instance.modules").first || fail("tâche absente")
    task.params_json["enable"].as_a.map(&.as_s).should eq(%w[perso bankimport])
  end

  it "refuse une incompatibilité sur la page d'une entreprise, en anglais aussi, et affiche les noms sur la fiche" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    user = AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)
    browser = AdminSpec::Browser.new(token: AdminSpec.session(user))
    html = browser.get("/dossiers/#{dossier.pk}/modules").html
    html.should contain(%(<input type="radio" id="p-micro" name="modules" value="micro"))
    html.should contain(%(id="choice-scheme-none" name="modules" value="" checked))
    html.should_not contain(%(id="p-perso"))
    html.should contain(%(data-initial="accounting invoicing"))
    html.should contain(%(data-regime="fr"))
    data = {"modules" => ["accounting", "invoicing", "micro", "liberal"]}
    browser.post("/dossiers/#{dossier.pk}/modules", data).html
      .should contain(fr("« Micro-entreprise » est incompatible avec « Profession libérale (2035) »."))
    refused = browser.post("/dossiers/#{dossier.pk}/modules", {"modules" => ["accounting"], "extensions" => ["bankimport", "perso"]})
    refused.status.should eq(422)
    refused.html.should contain(fr("« Finances du foyer » n'est pas admis dans un dossier « Entreprise »."))
    user.locale = "en"
    user.save!
    english = AdminSpec::Browser.new(locale: "en", token: AdminSpec.session(user))
    english.post("/dossiers/#{dossier.pk}/modules", data).html
      .should contain("“Micro-enterprise” is incompatible with “Liberal profession (2035)”.")
    page = english.get("/dossiers/#{dossier.pk}").html
    page.should contain(%(Accounting, Invoicing <code class="pd-piece-code">accounting,invoicing</code>))
  end
end

describe "Dossier belge : services français exclus (D-ADM-019)" do
  it "ne les propose pas, rappelle le régime et refuse côté serveur" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    dossier.regime = "be"
    dossier.save!
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)))
    html = browser.get("/dossiers/#{dossier.pk}/modules").html
    %w[urssaf teledec choruspro perso].each { |code| html.should_not contain(%(id="p-#{code}")) }
    %w[micro liberal einv superpdp esalink].each { |code| html.should contain(%(id="p-#{code}")) }
    html.should contain(%(data-regime="be"))
    html.should contain("<strong>Belgique</strong>")
    refused = browser.post("/dossiers/#{dossier.pk}/modules", {"modules" => ["accounting", "invoicing"], "extensions" => ["choruspro"]})
    refused.status.should eq(422)
    refused.html.should contain(fr("« Chorus Pro » n'est pas admis dans un dossier « Belgique »."))
    # Une pièce choisie mais non admise reste affichée, pour être retirée.
    refused.html.should contain(%(id="p-choruspro"))
  end

  it "passe de la micro-entreprise à la profession libérale : désactivation d'abord" do
    firm = AdminSpec.firm
    server, _ = AdminSpec.server
    dossier = AdminSpec.dossier(firm, server)
    dossier.modules = "accounting,micro"
    dossier.save!
    browser = AdminSpec::Browser.new(token: AdminSpec.session(AdminSpec.user(PartiduoAdmin::Config::FIRM_ADMIN, firm)))
    browser.get("/dossiers/#{dossier.pk}/modules").html
      .should contain(%(<input type="radio" id="p-micro" name="modules" value="micro" checked))
    done = browser.post("/dossiers/#{dossier.pk}/modules", {"modules" => ["accounting", "liberal"]})
    done.status.should eq(302)
    task = PartiduoAdmin::Task.filter(dossier_id: dossier.pk, kind: "instance.modules").first || fail("tâche absente")
    task.params_json["enable"].as_a.map(&.as_s).should eq(%w[liberal])
    task.params_json["disable"].as_a.map(&.as_s).should eq(%w[micro])
  end
end

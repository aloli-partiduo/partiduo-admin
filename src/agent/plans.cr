# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAgent
  # Contexte d'exécution d'une tâche : paramètres, système, journal de
  # reprise, résultat renvoyé à l'admin.
  class Context
    getter task : TaskInfo
    getter system : System
    getter journal : Journal
    getter result = {} of String => JSON::Any
    property on_step : Proc(String, Nil) = ->(_step : String) { nil }
    getter keyring : Keyring

    def initialize(@task : TaskInfo, @system : System, @journal : Journal)
      @keyring = Keyring.new(journal, task.data_keys, ->(identity : String) { system.recipient_of(identity) })
    end

    def params : JSON::Any
      task.params
    end

    def param(key : String) : String
      params[key]?.try { |value| value.as_s? || value.raw.to_s } || ""
    end

    def list(key : String) : Array(String)
      params[key]?.try(&.as_a?).try(&.map(&.to_s)) || [] of String
    end

    # Paquet FreeBSD du dossier (`package`) : vide, `app` ou `devel`
    # (`Protocol::PACKAGES`) ; jamais un chemin.
    def package : String
      value = param("package")
      unless value.empty? || PartiduoAdmin::Protocol.valid_package?(value)
        raise StepError.new("paquet invalide : #{value}", "usage")
      end
      value
    end

    def slug : String
      value = param("slug")
      raise StepError.new("sous-domaine invalide : #{value}", "usage") unless PartiduoAdmin::Protocol.valid_slug?(value)
      value
    end

    # Domaine des dossiers du serveur : celui de la configuration de
    # l'exécutant (obligatoire en production) ; à défaut (modes local et à
    # blanc), celui de la tâche, vérifié. Un domaine de tâche différent de
    # celui de la configuration est refusé.
    def domain : String
      configured = system.config.domain
      given = param("domain")
      if !configured.empty? && !given.empty? && given != configured
        raise StepError.new("domaine refusé : #{given} (serveur : #{configured})", "usage")
      end
      value = configured.presence || given
      raise StepError.new("domaine invalide : #{value}", "usage") unless PartiduoAdmin::Protocol.valid_domain?(value)
      value
    end

    # Hôte d'un dossier : toujours calculé (`<sous-domaine>.<domaine>`) ;
    # l'hôte reçu, s'il y en a un, doit être celui-là (D-AFN-004).
    def host_for(slug : String, key : String = "host") : String
      expected = "#{slug}.#{domain}"
      given = param(key)
      raise StepError.new("hôte refusé : #{given} (attendu : #{expected})", "usage") unless given.empty? || given == expected
      expected
    end

    def host : String
      host_for(slug)
    end

    # Base du dossier : toujours celle du sous-domaine dans ce mode ; la base
    # reçue de l'administration, s'il y en a une, doit être celle-là
    # (D-AFN-004). Une tâche forgée ne vise donc jamais la base d'un autre
    # dossier.
    def database : String
      expected = system.database_for(slug)
      given = param("database")
      raise StepError.new("base refusée : #{given} (attendue : #{expected})", "usage") unless given.empty? || given == expected
      expected
    end

    # Emplacement d'une sauvegarde reçu de l'administration (D-CHF-024) :
    # `<serveur>/<sous-domaine>/<fichier>` *du dossier*, jamais d'un autre.
    # Une tâche forgée ne restaure donc pas la base d'un dossier dans un
    # autre, ni n'efface les sauvegardes d'un autre (D-CRA-001). Un chemin du
    # répertoire de sauvegarde du dossier sur ce serveur
    # (`<backup_dir>/<sous-domaine>/<fichier>`) désigne le fichier de même
    # nom pris par ce serveur.
    def locator!(value : String, of_slug : String = slug) : Locator
      if value.starts_with?('/')
        full = system.guard_backup_path!(value, of_slug)
        return Locator.parse?("#{system.config.server}/#{of_slug}/#{File.basename(full)}") ||
          raise StepError.new("fichier de sauvegarde refusé : #{File.basename(full)}", "usage")
      end
      locator = Locator.parse?(value) || raise StepError.new("emplacement de sauvegarde refusé : #{value}", "usage")
      unless locator.slug == of_slug
        raise StepError.new("chemin hors du répertoire des sauvegardes du dossier : #{value}", "usage")
      end
      locator
    end

    # Fichiers ramenés du stockage pour cette tâche, effacés à sa fin.
    getter fetched = [] of String

    # Fichier du stockage ramené dans le répertoire de sauvegarde du
    # dossier sur ce serveur ; rend son chemin.
    def fetch!(locator : Locator) : String
      local = File.join(system.backup_root(locator.slug), locator.name)
      unless fetched.includes?(local)
        system.mkdir(system.backup_root(locator.slug))
        system.store.fetch(locator, local)
        fetched << local
      end
      local
    end

    # Rien d'une sauvegarde lue ne reste sur le serveur après la tâche.
    def cleanup : Nil
      fetched.each do |path|
        system.remove(path) if system.exists?(path)
      rescue error : StepError
        log("#{File.basename(path)} non effacé : #{error.message}")
      end
      fetched.clear
    end

    # Valeur reçue de l'administration et passée en argument à
    # `manage instance` : jamais prise pour une option (`--list-file=…`),
    # jamais sur plusieurs lignes (D-CRA-002).
    def value_arg(key : String) : String
      value = param(key)
      if value.starts_with?('-') || value.includes?('\n') || value.includes?('\r') || value.includes?('\0')
        raise StepError.new("valeur refusée pour #{key}", "usage")
      end
      value
    end

    def log(line : String) : Nil
      system.log(line)
    end

    def set(key : String, value) : Nil
      result[key] = JSON.parse(value.to_json)
    end

    # Étape idempotente : faite une fois, sautée à la reprise.
    def step(name : String, &) : Nil
      if journal.done?(name)
        log("étape « #{name} » déjà faite (reprise)")
        return
      end
      log("— #{name}")
      yield
      journal.mark(name)
      on_step.call(name)
    end

    # Appel de l'interface en ligne de commande d'instance ; échec levé.
    # `package` : seulement pour une instance pas encore déclarée sur le
    # serveur (sinon, le paquet qui la sert).
    def instance!(action : String, args = [] of String, package : String? = nil, database : String? = nil,
                  slug_override : String? = nil) : JSON::Any
      reply = instance(action, args, package, database, slug_override)
      raise StepError.new("instance #{action} : #{reply.message}", reply.error_code) unless reply.ok?
      reply.data
    end

    def instance(action : String, args = [] of String, package : String? = nil, database : String? = nil,
                 slug_override : String? = nil) : InstanceReply
      full = args + ["--task", task.id.to_s]
      full += ["--requested-by", task.requested_by] unless task.requested_by.empty?
      system.instance(slug_override || slug, action, full, package, database)
    end
  end

  # Liste fermée des types de tâches (ADR-008 D4) et leurs étapes, traduites
  # en appels à partiduo-provision et à `manage instance`. Jamais de
  # commande arbitraire : les paramètres ne sont que des valeurs validées.
  module Plans
    alias Plan = Proc(Context, Nil)

    # Un plan par type de la liste fermée ; tout autre type est refusé.
    PLANS = {
      "instance.create"          => Plan.new { |ctx| create(ctx) },
      "instance.modules"         => Plan.new { |ctx| modules(ctx) },
      "instance.suspend"         => Plan.new { |ctx| suspend(ctx) },
      "instance.resume"          => Plan.new { |ctx| resume(ctx) },
      "instance.archive"         => Plan.new { |ctx| archive(ctx) },
      "instance.restore_archive" => Plan.new { |ctx| restore_archive(ctx) },
      "instance.delete"          => Plan.new { |ctx| delete(ctx) },
      "instance.admin_invite"    => Plan.new { |ctx| admin_invite(ctx) },
      "backup.run"               => Plan.new { |ctx| backup(ctx, ctx.param("kind").presence || "manual") },
      "backup.prune"             => Plan.new { |ctx| prune(ctx) },
      "backup.test_restore"      => Plan.new { |ctx| test_restore(ctx) },
      "backup.restore"           => Plan.new { |ctx| restore(ctx) },
      "supervision.check"        => Plan.new { |ctx| supervision(ctx) },
    }

    def self.run(ctx : Context) : Nil
      plan = PLANS[ctx.task.kind]? || raise StepError.new("type de tâche refusé : #{ctx.task.kind}", "usage")
      # Tâche d'un dossier : sous-domaine, hôte et base vérifiés avant tout
      # geste (D-AFN-004).
      unless ctx.task.kind == "supervision.check"
        ctx.host
        ctx.database
      end
      begin
        plan.call(ctx)
      ensure
        ctx.cleanup
      end
    end

    # Contrat de l'interface d'instance : majeure attendue (instance-cli.adoc).
    # Renvoie la version lue (`1.1.0`), pour les gestes qui dépendent d'une
    # mineure. `package` : pour une instance pas encore déclarée (création),
    # l'outil du paquet qui la servira.
    def self.check_contract(ctx : Context, package : String? = nil) : String
      contract = ""
      ctx.step("contrat") do
        data = ctx.instance!("version", package: package)
        contract = data["contract"]?.try(&.as_s?) || ""
        major = contract.split('.').first.to_i?
        unless major == PartiduoAdmin::Protocol::INSTANCE_CLI_MAJOR
          raise StepError.new("contrat d'instance #{data["contract"]?} non pris en charge", "usage")
        end
      end
      contract
    end

    # Le contrat `contract` (`1.1.0`) est-il au moins `major.minor` ?
    def self.contract_at_least?(contract : String, major : Int32, minor : Int32) : Bool
      parts = contract.split('.').map(&.to_i?)
      {parts[0]? || 0, parts[1]? || 0} >= {major, minor}
    end

    # --- Création -------------------------------------------------------------

    def self.create(ctx : Context) : Nil
      system = ctx.system
      database = ctx.database
      host = ctx.host
      # Instance pas encore déclarée : le paquet choisi dans l'admin (`app`
      # s'il n'est pas dit) fournit l'outil `manage` et la servira.
      package = ctx.package.presence || "app"
      check_contract(ctx, package)
      ctx.step("provisionnement") do
        exists = system.database_exists?(database)
        provisioned = exists && ctx.instance("status", package: package, database: database).data["provisioned"]?.try(&.as_bool?) == true
        if provisioned
          ctx.log("base #{database} déjà provisionnée : rien à refaire")
        else
          # Client connect du dossier (ADR-012) : déclaré juste avant, à chaque
          # essai (un nouveau secret remplace celui d'un essai interrompu).
          connect = system.connect_client(host)
          output = system.provision(ctx.slug, ctx.domain, ctx.params, database, skip_createdb: exists, connect: connect)
          if link = output.match(/https?:\/\/\S+\/invitation\/\S+/)
            ctx.journal["invitation_url"] = link[0]
          end
          # Code de création du compte connect (ADR-012 D6), à transmettre à
          # l'administrateur du dossier par un autre canal que le courriel.
          if code = output.match(/\b([A-Z2-9]{4}-[A-Z2-9]{4})\s*$/m)
            ctx.journal["signup_code"] = code[1]
          end
        end
      end
      ctx.step("installation") do
        ctx.journal["certificate"] = system.install_instance(ctx.slug, host, package).to_s
      end
      status = ctx.instance!("status", package: package, database: database)
      raise StepError.new("instance non provisionnée après création", "refused") unless status["provisioned"]?.try(&.as_bool?)
      ctx.set("database", database)
      ctx.set("version", status["version"]?.try(&.as_s?) || "")
      if url = ctx.journal["invitation_url"]?
        if ctx.system.mailer?
          # Lien remis par le serveur lui-même (D-CRA-003).
          ctx.step("invitation") do
            ctx.system.deliver_invitation(ctx.param("admin_email"), host, url, ctx.param("locale"))
          end
          ctx.set("invitation_delivered", "server")
        else
          ctx.set("invitation_url", url)
        end
      end
      if code = ctx.journal["signup_code"]?
        ctx.set("signup_code", code)
      end
      ctx.set("certificate", {"issued" => ctx.journal["certificate"]? == "true", "staging" => system.config.acme_staging})
    end

    # --- Modules et extensions (ADR-006 D2 : désactiver conserve les données)

    # Ordre des gestes selon les dépendances que rend `status`
    # (`depends_on`) : une pièce se désactive après celles qui la requièrent,
    # s'active après celles qu'elle requiert (`Modules.deactivate` et
    # `activate` refusent sinon). Sans dépendance connue, l'ordre reçu est
    # gardé (l'admin met déjà les extensions avant les modules à la
    # désactivation, après à l'activation).
    def self.modules(ctx : Context) : Nil
      check_contract(ctx)
      depends = dependencies(ctx.instance!("status"))
      disable_order(ctx.list("disable"), depends).each do |code|
        ctx.step("désactiver #{code}") { ctx.instance!("disable", [code]) }
      end
      enable_order(ctx.list("enable"), depends).each do |code|
        ctx.step("activer #{code}") { ctx.instance!("enable", [code]) }
      end
      status = ctx.instance!("status")
      ctx.set("modules", status["modules"]? || [] of String)
    end

    alias Depends = Hash(String, Array(String))

    # Dépendances par pièce (codes en majuscules ; une alternative `A|B`
    # compte ses deux membres).
    def self.dependencies(status : JSON::Any) : Depends
      depends = Depends.new
      (status["modules"]?.try(&.as_a?) || [] of JSON::Any).each do |piece|
        code = piece["code"]?.try(&.as_s?) || next
        list = piece["depends_on"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
        depends[code.upcase] = list.flat_map(&.split('|')).map(&.upcase)
      end
      depends
    end

    # Pièces requises d'abord.
    def self.enable_order(codes : Array(String), depends : Depends) : Array(String)
      ordered = [] of String
      codes.each { |code| visit(code, codes, depends, false, ordered, Set(String).new) }
      ordered
    end

    # Pièces qui requièrent les autres d'abord.
    def self.disable_order(codes : Array(String), depends : Depends) : Array(String)
      ordered = [] of String
      codes.each { |code| visit(code, codes, depends, true, ordered, Set(String).new) }
      ordered
    end

    private def self.requires?(code : String, other : String, depends : Depends) : Bool
      (depends[code.upcase]? || [] of String).includes?(other.upcase)
    end

    # Parcours en profondeur : passent avant `code` les codes qu'il requiert
    # (`dependents` faux) ou ceux qui le requièrent (`dependents` vrai) ;
    # un cycle est ignoré.
    private def self.visit(code : String, codes : Array(String), depends : Depends, dependents : Bool,
                           ordered : Array(String), path : Set(String)) : Nil
      return if ordered.includes?(code) || path.includes?(code)
      path << code
      codes.each do |other|
        next if other == code
        first = dependents ? requires?(other, code, depends) : requires?(code, other, depends)
        visit(other, codes, depends, dependents, ordered, path) if first
      end
      path.delete(code)
      ordered << code
    end

    # --- Cycle de vie -----------------------------------------------------------

    def self.suspend(ctx : Context) : Nil
      ctx.step("arrêt du service") { ctx.system.service(ctx.slug, "stop") }
      ctx.set("service", ctx.system.service(ctx.slug, "status"))
    end

    def self.resume(ctx : Context) : Nil
      ctx.step("démarrage du service") { ctx.system.service(ctx.slug, "start") }
      ctx.instance!("status")
      ctx.set("service", ctx.system.service(ctx.slug, "status"))
    end

    # Archivage : lecture seule, sauvegarde figée *vérifiée* (relue à sa
    # prise, D-CHF-017 ; empreintes et manifeste signé), envoyée au
    # stockage, instance arrêtée.
    def self.archive(ctx : Context) : Nil
      check_contract(ctx)
      ctx.step("lecture seule") do
        ctx.instance!("read-only", ["on", "--reason", ctx.param("reason").presence || "archivage", "--terminate-sessions"])
      end
      data = backup(ctx, "archive", prefix: "archive")
      ctx.step("arrêt du service") { ctx.system.service(ctx.slug, "stop") }
      verified = data.as_h.merge({"verified" => JSON::Any.new(true)})
      ctx.result.clear
      ctx.set("backup", verified)
    end

    # Restauration d'une archive en instance active : base recréée depuis
    # l'archive si elle a disparu, lecture seule levée, service démarré.
    def self.restore_archive(ctx : Context) : Nil
      path = ctx.param("path")
      ctx.locator!(path) unless path.empty?
      ctx.step("base") do
        unless ctx.system.database_exists?(ctx.database)
          raise StepError.new("base absente et aucune archive fournie", "usage") if path.empty?
          source = source(ctx)
          identity = source_identity!(ctx, source)
          ctx.system.createdb(ctx.database)
          ctx.system.restore_database(ctx.database, source.dump, identity)
        end
      end
      ctx.step("lecture seule levée") { ctx.instance!("read-only", ["off", "--reason", "restauration de l'archive"]) }
      ctx.step("démarrage du service") { ctx.system.service(ctx.slug, "start") }
      ctx.set("version", ctx.instance!("status")["version"]? || "")
    end

    # Suppression définitive (après la durée légale et la validation, à une
    # ou deux personnes, vérifiées par l'admin) : service et fichiers
    # retirés, base supprimée, sauvegardes effacées du stockage.
    def self.delete(ctx : Context) : Nil
      # Emplacements vérifiés avant tout geste : une liste qui vise un autre
      # dossier n'a rien retiré (D-CRA-001).
      backups = ctx.list("backups").map { |path| ctx.locator!(path) }
      # Ce serveur n'efface que ses propres sauvegardes (D-CHF-024) : celles
      # d'un autre (dossier déplacé) sont refusées avant tout geste.
      others = backups.reject { |locator| locator.server == ctx.system.config.server }.map(&.server).uniq!
      unless others.empty?
        raise StepError.new("sauvegardes prises par #{others.join(", ")} : à effacer depuis ce serveur ou sur le " \
                            "stockage avant la suppression définitive", "refused")
      end
      ctx.system.guard_retention!(ctx.slug)
      ctx.log("suppression définitive — #{approval_line(ctx)}")
      ctx.step("retrait du service") { ctx.system.remove_instance(ctx.slug, ctx.host) }
      ctx.step("client connect") { ctx.system.disable_connect_client(ctx.host) }
      ctx.step("suppression de la base") { ctx.system.dropdb(ctx.database) }
      ctx.step("suppression des sauvegardes") do
        backup_files(ctx, backups).each { |locator| ctx.system.store.delete(locator) }
      end
      ctx.set("deleted", true)
    end

    # --- Opérations sensibles : mode de validation (D-VAL2-005) --------------

    # Mode reçu : `single` ou `dual` ; absent, `dual` (administration
    # antérieure à l'API 1.2.0). Toute autre valeur est refusée.
    def self.approval_mode(ctx : Context) : String
      mode = ctx.param("approval_mode").presence || "dual"
      raise StepError.new("mode de validation refusé : #{mode}", "usage") unless PartiduoAdmin::Protocol::APPROVAL_MODES.includes?(mode)
      mode
    end

    # Personnes cohérentes avec le mode : exactement une pour `single`, au
    # moins deux distinctes pour `dual` ; aucune valeur prise pour une
    # option ni séparateur (D-CRA-002).
    def self.checked_approvers(ctx : Context) : Array(String)
      approvers = ctx.list("approvers").map(&.strip)
      if approvers.any? { |approver| approver.empty? || approver.starts_with?('-') || approver.includes?(',') || approver.includes?('\n') }
        raise StepError.new("valeur refusée pour approvers", "usage")
      end
      distinct = approvers.map(&.downcase).uniq!.size
      case approval_mode(ctx)
      when "single"
        raise StepError.new("validation à une personne : un seul nom attendu", "usage") unless approvers.size == 1
      else
        raise StepError.new("validation à deux personnes incomplète", "usage") unless distinct >= 2
      end
      approvers
    end

    # Ligne du journal : mode, référence et personnes.
    def self.approval_line(ctx : Context) : String
      approvers = checked_approvers(ctx)
      label = approval_mode(ctx) == "single" ? "validation à une personne" : "validation à deux personnes"
      "#{label} #{ctx.param("approval_ref")} par #{approvers.join(", ")}"
    end

    # --- Recours d'accès (décision prise dans l'admin) -----------------------

    def self.admin_invite(ctx : Context) : Nil
      contract = check_contract(ctx)
      approvers = checked_approvers(ctx)
      mode = approval_mode(ctx)
      ctx.log("recours d'accès — #{approval_line(ctx)}")
      arguments = [ctx.value_arg("email"), "--reason", ctx.value_arg("reason"),
                   "--approval-ref", ctx.value_arg("approval_ref")]
      # Contrat 1.1.0 (B-VAL2-001) : le mode est transmis, un seul nom en
      # mode `single`. Instance en 1.0.0 : elle exige deux noms ; la
      # validation à deux passe sans l'option (repli consigné), celle à une
      # personne est refusée avant tout geste — l'instance est à mettre à
      # jour.
      if contract_at_least?(contract, 1, PartiduoAdmin::Protocol::APPROVAL_MODE_MINOR)
        arguments += ["--approval-mode", mode]
      elsif mode == "single"
        raise StepError.new("contrat d'instance #{contract} : la validation à une personne exige le contrat " \
                            "1.#{PartiduoAdmin::Protocol::APPROVAL_MODE_MINOR}.0 (mettre l'instance à jour)", "refused")
      else
        ctx.log("contrat d'instance #{contract} : validation à deux personnes transmise sans --approval-mode")
      end
      data = ctx.instance!("admin-invite", arguments + ["--approvers", approvers.join(',')])
      # `signup_code`, `connect_account` : connect (ADR-012 D6, contrat 1.3).
      %w[email user_created expires_at usable_admins signup_code connect_account].each do |key|
        ctx.result[key] = data[key] if data[key]?
      end
      url = data["url"]?.try(&.as_s?)
      if url && ctx.system.mailer?
        # Lien remis par le serveur lui-même : il ne passe jamais par
        # l'administration (D-CRA-003).
        ctx.system.deliver_invitation(data["email"]?.try(&.as_s?) || ctx.param("email"), ctx.host, url, ctx.param("locale"))
        ctx.set("invitation_delivered", "server")
      elsif url
        ctx.result["url"] = JSON::Any.new(url)
      end
    end

    # --- Sauvegardes -------------------------------------------------------------

    # `pg_dump -Fc` et archive des pièces jointes (liste de `backup-plan`),
    # préparés dans le répertoire de sauvegarde du serveur puis envoyés au
    # stockage, hors du serveur (D-CHF-024) ; noms figés au premier passage :
    # une reprise réutilise les mêmes fichiers.
    #
    # Chiffrement (`encryption` des paramètres, D-CHF-013 à D-CHF-015) :
    # aucun, clé d'exploitation ou clé du cabinet. Chiffrées, la base et les
    # pièces jointes sont des fichiers `age` pour une clé de sauvegarde tirée
    # pour elle seule et gardée dans une capsule ; le clair ne passe que par
    # un tube. Toute sauvegarde est relue à sa prise (D-CHF-017) et décrite
    # par un manifeste signé par le serveur (D-CHF-018).
    def self.backup(ctx : Context, kind : String, prefix : String = "backup") : JSON::Any
      taking = start_taking(ctx, prefix)
      take_files(ctx, taking)
      # Relue à la prise, la tâche détenant encore la clé de sauvegarde : la
      # base par pg_restore --list, l'archive par tar -t (D-CHF-017).
      ctx.step(taking.step("relecture")) do
        identity = taking.key.try(&.identity)
        unless ctx.system.database_readable?(taking.dump, identity)
          raise StepError.new("sauvegarde illisible à sa prise : #{File.basename(taking.dump)}")
        end
        raise StepError.new("archive des pièces illisible à sa prise") unless ctx.system.media_readable?(taking.media, identity)
      end
      write_capsule(ctx, taking)
      write_manifest(ctx, taking)
      upload(ctx, taking)
      data = backup_result(ctx, taking, kind)
      json = JSON.parse(data.to_json)
      data.each { |key_name, value| ctx.set(key_name, value) } if ctx.task.kind == "backup.run"
      json
    end

    # Sauvegarde en cours de prise : ses fichiers dans le répertoire de
    # sauvegarde du dossier sur ce serveur, son mode et ses clés.
    record Taking, prefix : String, stem : String, dir : String, mode : String,
      key : BackupCrypto::Ephemeral?, cabinet : BackupCrypto::PublicKey? do
      def step(name : String) : String
        "#{prefix} : #{name}"
      end

      def path(extension : String) : String
        File.join(dir, stem + extension)
      end

      def suffix : String
        key ? BackupCrypto::EXTENSION : ""
      end

      def dump : String
        path(".dump#{suffix}")
      end

      def media : String
        path(".media.tar.gz#{suffix}")
      end

      def list : String
        path(".files")
      end

      def capsule : String?
        return unless key
        path(cabinet ? BackupCrypto::CAPSULE_RSA : BackupCrypto::CAPSULE_AGE)
      end

      def taken_at : Time
        Time.parse(stem.lchop("#{prefix}-"), "%Y%m%dT%H%M%SZ", Time::Location::UTC)
      end
    end

    # Horodatage figé au premier passage, mode et clés de la sauvegarde.
    def self.start_taking(ctx : Context, prefix : String) : Taking
      journal = ctx.journal
      settings = ctx.params["encryption"]?
      mode = encryption_mode(settings)
      cabinet = mode == "cabinet" ? cabinet_key(settings) : nil
      # La clé d'abord : une reprise qui l'a perdue repart sous un nouvel
      # horodatage.
      key = sealing_key(ctx, prefix, mode)
      stamp = journal["#{prefix}.stamp"]? || (journal["#{prefix}.stamp"] = Time.utc.to_s("%Y%m%dT%H%M%SZ"))
      Taking.new(prefix, "#{prefix}-#{stamp}", ctx.system.backup_root(ctx.slug), mode, key, cabinet)
    end

    # Base et pièces jointes. Pièces jointes relevées avant ET après
    # pg_dump : l'archive porte l'union des deux listes, donc toute pièce
    # que la base sauvegardée peut citer, même déposée ou supprimée pendant
    # la sauvegarde (D-AFN-012).
    def self.take_files(ctx : Context, taking : Taking) : Nil
      system = ctx.system
      list = taking.list
      key = taking.key
      ctx.step(taking.step("liste des pièces jointes")) do
        system.mkdir(taking.dir)
        ctx.instance!("backup-plan", ["--list-file", "#{list}.before"])
      end
      ctx.step(taking.step("base")) do
        key ? system.pg_dump_sealed(ctx.database, taking.dump, key.recipient) : system.pg_dump(ctx.database, taking.dump)
      end
      ctx.step(taking.step("pièces jointes")) do
        plan = ctx.instance!("backup-plan", ["--list-file", "#{list}.after"])
        root = plan["media_root"]?.try(&.as_s?) || ""
        missing = plan["missing"]?.try(&.as_a?).try(&.size) || 0
        ctx.log("#{missing} pièce(s) jointe(s) manquante(s) à signaler") if missing > 0
        system.merge_lists(["#{list}.before", "#{list}.after"], list)
        if key
          system.tar_create_sealed(ctx.slug, root, list, taking.media, key.recipient)
        else
          system.tar_create(ctx.slug, root, list, taking.media)
        end
      end
    end

    # Capsule de la clé de sauvegarde : pour les clés d'exploitation du
    # serveur, ou pour la clé du cabinet (D-CHF-014).
    def self.write_capsule(ctx : Context, taking : Taking) : Nil
      key = taking.key || return
      capsule = taking.capsule || return
      system = ctx.system
      ctx.step(taking.step("capsule")) do
        if cabinet = taking.cabinet
          system.write_file(capsule, BackupCrypto.capsule_for_cabinet(key.identity, cabinet))
        else
          recipients = system.exploitation_recipients
          system.write_file(capsule, system.capsule_for(key.identity, recipients))
          ctx.journal["#{taking.prefix}.capsule_keys"] = recipients.map { |recipient| BackupCrypto.recipient_fingerprint(recipient) }.join(',')
        end
        ctx.journal["#{taking.prefix}.capsule"] = Base64.strict_encode(system.read_file(capsule).to_slice)
      end
    end

    # Manifeste signé par la clé du serveur (D-CHF-018).
    def self.write_manifest(ctx : Context, taking : Taking) : Nil
      system = ctx.system
      journal = ctx.journal
      ctx.step(taking.step("manifeste")) do
        entries = [taking.dump, taking.media].map do |path|
          BackupCrypto::Entry.new(File.basename(path), system.size(path), system.sha256(path))
        end
        keys = (journal["#{taking.prefix}.capsule_keys"]? || "").split(',', remove_empty: true)
        text = BackupCrypto::Manifest.new(system.config.server, ctx.slug, taking.stem, taking.taken_at, taking.mode,
          taking.key.try(&.recipient) || "", keys, taking.cabinet.try(&.fingerprint) || "", entries).to_s
        signed, public_line = system.sign(text)
        system.write_file(taking.path(BackupCrypto::MANIFEST), text)
        system.write_file(taking.path(BackupCrypto::SIGNATURE), signed)
        journal["#{taking.prefix}.manifest"] = text
        journal["#{taking.prefix}.signature"] = signed
        journal["#{taking.prefix}.signing_key"] = public_line
      end
    end

    # Envoi au stockage, vérifié par le SHA-256 que le stockage calcule ;
    # puis plus rien de la sauvegarde ne reste sur ce serveur.
    def self.upload(ctx : Context, taking : Taking) : Nil
      system = ctx.system
      ctx.step(taking.step("envoi au stockage")) do
        sent = [taking.dump, taking.media, taking.capsule, taking.path(BackupCrypto::MANIFEST),
                taking.path(BackupCrypto::SIGNATURE)].compact
        sent.each do |path|
          locator = Locator.new(system.config.server, ctx.slug, File.basename(path))
          found = system.store.stat(locator)
          # Reprise après l'effacement local : déjà au stockage.
          next if found && !system.exists?(path)
          local = system.sha256(path)
          if found
            raise StepError.new("stockage : #{locator} existe déjà, différent") unless found[1] == local
            next
          end
          raise StepError.new("stockage : #{locator} altéré à l'envoi") unless system.store.put(path, locator) == local
        end
        (sent + [taking.list]).each { |path| system.remove(path) if system.exists?(path) }
      end
    end

    # Compte rendu d'une sauvegarde, d'après son manifeste (journal).
    def self.backup_result(ctx : Context, taking : Taking, kind : String) : Hash(String, String | Int64 | Hash(String, String | Array(String)))
      journal = ctx.journal
      server = ctx.system.config.server
      text = journal["#{taking.prefix}.manifest"]? || raise StepError.new("journal de reprise incomplet : manifeste")
      described = BackupCrypto::Manifest.parse(text)
      dump = described.file?(File.basename(taking.dump)) || raise StepError.new("manifeste incomplet")
      media = described.file?(File.basename(taking.media)) || raise StepError.new("manifeste incomplet")
      {
        "kind"         => kind,
        "path"         => Locator.new(server, ctx.slug, dump.name).to_s,
        "media_path"   => Locator.new(server, ctx.slug, media.name).to_s,
        "size_bytes"   => dump.size + media.size,
        "sha256"       => dump.sha256,
        "media_sha256" => media.sha256,
        "version"      => instance_version(ctx),
        "taken_at"     => described.taken_at.to_rfc3339,
        "server"       => server,
        "encryption"   => {"mode" => taking.mode, "recipient" => described.recipient, "key_fingerprint" => described.cabinet_key,
                         "capsule" => journal["#{taking.prefix}.capsule"]? || "", "capsule_keys" => described.capsule_keys},
        "manifest"    => text,
        "signature"   => journal["#{taking.prefix}.signature"]? || "",
        "signing_key" => journal["#{taking.prefix}.signing_key"]? || "",
      }
    end

    # Version (semver) que rend l'instance (`status`), vide si elle ne
    # répond pas : l'administration garde alors celle qu'elle connaît.
    def self.instance_version(ctx : Context) : String
      reply = ctx.instance("status")
      reply.ok? ? (reply.data["version"]?.try(&.as_s?) || "") : ""
    end

    def self.encryption_mode(settings : JSON::Any?) : String
      mode = settings.try(&.["mode"]?).try(&.as_s?) || "none"
      raise StepError.new("mode de chiffrement inconnu : #{mode}", "usage") unless BackupCrypto::MODES.includes?(mode)
      mode
    end

    # Clé de sauvegarde de la sauvegarde `prefix`, tirée au premier passage
    # et retenue dans le journal : une reprise chiffre la suite avec la même
    # clé. Elle (`secret.*`) est effacée du journal à la fin de la tâche ;
    # une reprise qui ne peut plus la retrouver avant la fin de l'envoi
    # reprend toute la sauvegarde, avec une nouvelle clé et sous un nouvel
    # horodatage : le stockage n'écrase jamais, et des fichiers déjà envoyés
    # sous l'ancien nom (orphelins, sans manifeste) restent à élaguer.
    def self.sealing_key(ctx : Context, prefix : String, mode : String) : BackupCrypto::Ephemeral?
      return if mode == "none"
      journal = ctx.journal
      recipient = journal["#{prefix}.recipient"]?
      identity = journal["#{Keyring::SECRET_PREFIX}#{prefix}.identity"]?
      if recipient && journal["#{prefix}.mode"]? == mode
        return BackupCrypto::Ephemeral.new(identity, recipient) if identity
        # Déjà envoyée : la clé ne sert plus.
        return BackupCrypto::Ephemeral.new("", recipient) if journal.done?("#{prefix} : envoi au stockage")
        ctx.log("#{prefix} : clé de sauvegarde oubliée, sauvegarde reprise depuis la base")
        ["liste des pièces jointes", "base", "pièces jointes", "relecture", "capsule", "manifeste", "envoi au stockage"].each do |step|
          journal.unmark("#{prefix} : #{step}")
        end
        journal["#{prefix}.stamp"] = Time.utc.to_s("%Y%m%dT%H%M%SZ")
      end
      key = ctx.system.keygen
      journal["#{prefix}.mode"] = mode
      journal["#{prefix}.recipient"] = key.recipient
      journal["#{Keyring::SECRET_PREFIX}#{prefix}.identity"] = key.identity
      ctx.log("#{prefix} : chiffrement #{mode == "cabinet" ? "pour la clé du cabinet" : "pour les clés d'exploitation"} " \
              "(clé de sauvegarde #{BackupCrypto.recipient_fingerprint(key.recipient)[0, 16]}…)")
      key
    end

    # Clé publique du cabinet reçue de l'administration ; son empreinte doit
    # être celle annoncée (une clé altérée en chemin est refusée).
    def self.cabinet_key(settings : JSON::Any?) : BackupCrypto::PublicKey
      pem = settings.try(&.["public_key"]?).try(&.as_s?) || ""
      raise StepError.new("clé publique du cabinet manquante", "usage") if pem.empty?
      key = BackupCrypto::PublicKey.new(pem)
      expected = settings.try(&.["key_fingerprint"]?).try(&.as_s?) || ""
      unless expected.empty? || expected == key.fingerprint
        raise StepError.new("clé publique du cabinet : empreinte #{key.fingerprint[0, 16]}… au lieu de #{expected[0, 16]}…", "usage")
      end
      key
    rescue ex : BackupCrypto::Error
      raise StepError.new("clé publique du cabinet : #{ex.message}", "usage")
    end

    # Fichiers du stockage d'une liste de sauvegardes : chaque fichier
    # nommé, et ses voisins de même préfixe (capsule, manifeste, signature).
    def self.backup_files(ctx : Context, locators : Array(Locator)) : Array(Locator)
      return locators if locators.empty?
      stems = locators.map { |locator| {locator.server, locator.stem} }.uniq!
      listed = ctx.system.store.list(ctx.slug).select { |locator| stems.includes?({locator.server, locator.stem}) }
      (locators + listed).uniq
    end

    # Élagage : sauvegardes effacées du stockage. Celles d'un autre serveur
    # (dossier déplacé) ne sont effacées que par lui : gardées et rendues
    # (`kept`), l'administration ne les marque pas élaguées.
    def self.prune(ctx : Context) : Nil
      locators = ctx.list("paths").map { |path| ctx.locator!(path) }
      locators.each { |locator| ctx.system.guard_archive_removal!(locator.name) }
      own, others = locators.partition { |locator| locator.server == ctx.system.config.server }
      backup_files(ctx, own).each do |locator|
        ctx.step("effacer #{locator.name}") { ctx.system.store.delete(locator) }
      end
      others.each { |locator| ctx.log("#{locator} : sauvegarde d'un autre serveur, gardée") }
      ctx.set("pruned", own.size)
      ctx.set("kept", others.map(&.to_s))
    end

    # Sauvegarde lue (restauration, restauration test, archive) : fichiers
    # ramenés du stockage dans le répertoire de sauvegarde de ce serveur le
    # temps de la tâche, manifeste dont la signature est vérifiée par la clé
    # du serveur d'origine (`signers`, D-CHF-018).
    record Source, locator : Locator, dump : String, media : String, manifest : BackupCrypto::Manifest do
      def sealed? : Bool
        manifest.sealed?
      end
    end

    def self.source(ctx : Context) : Source
      system = ctx.system
      locator = ctx.locator!(ctx.param("path"))
      media_value = ctx.param("media_path")
      media_locator = media_value.empty? ? nil : ctx.locator!(media_value)
      if media_locator && (media_locator.server != locator.server || media_locator.stem != locator.stem)
        raise StepError.new("pièces jointes d'une autre sauvegarde : #{media_value}", "usage")
      end
      dump = ctx.fetch!(locator)
      media = media_locator ? ctx.fetch!(media_locator) : ""
      check_digests(ctx, dump, media)
      manifest = verified_manifest(ctx, locator)
      {dump, media}.each do |path|
        next if path.empty?
        entry = manifest.file?(File.basename(path)) || raise StepError.new("#{File.basename(path)} absent du manifeste signé", "refused")
        unless entry.size == system.size(path) && entry.sha256 == system.sha256(path)
          raise StepError.new("empreinte de #{File.basename(path)} altérée : différente du manifeste signé", "refused")
        end
      end
      announced = ctx.params["backup_encryption"]?.try(&.["mode"]?).try(&.as_s?) || "none"
      unless announced == manifest.mode
        raise StepError.new("sauvegarde #{locator.name} : chiffrement annoncé « #{announced} » incohérent avec le manifeste", "usage")
      end
      Source.new(locator, dump, media, manifest)
    end

    # Manifeste d'une sauvegarde, authentifié : signé par le serveur qui l'a
    # prise, valable à sa date de prise, et décrivant bien cette sauvegarde.
    def self.verified_manifest(ctx : Context, locator : Locator) : BackupCrypto::Manifest
      system = ctx.system
      text = system.read_file(ctx.fetch!(locator.sibling(BackupCrypto::MANIFEST)))
      signature = system.read_file(ctx.fetch!(locator.sibling(BackupCrypto::SIGNATURE)))
      signers = ctx.list("signers")
      if signers.empty?
        raise StepError.new("clé de signature du serveur #{locator.server} inconnue de l'administration : " \
                            "sauvegarde non authentifiable", "refused")
      end
      unless system.verify_signature(text, signature, signers, locator.server, locator.taken_at)
        raise StepError.new("signature du manifeste refusée (serveur #{locator.server}) : sauvegarde non authentique", "refused")
      end
      manifest = BackupCrypto::Manifest.parse(text)
      unless manifest.server == locator.server && manifest.dossier == locator.slug && manifest.backup == locator.stem
        raise StepError.new("manifeste d'une autre sauvegarde : #{locator}", "refused")
      end
      manifest
    rescue ex : BackupCrypto::Error
      raise StepError.new("manifeste de #{locator} : #{ex.message}", "refused")
    end

    # Empreintes SHA-256 enregistrées par l'administration (D-CHF-011),
    # calculées sur les fichiers tels que conservés (chiffrés s'ils le sont).
    def self.check_digests(ctx : Context, path : String, media : String) : Nil
      system = ctx.system
      unless ctx.param("sha256").empty? || system.sha256(path) == ctx.param("sha256")
        raise StepError.new("empreinte de la sauvegarde altérée : #{File.basename(path)}")
      end
      unless media.empty? || ctx.param("media_sha256").empty? || system.sha256(media) == ctx.param("media_sha256")
        raise StepError.new("empreinte de l'archive des pièces jointes altérée : #{File.basename(media)}")
      end
    end

    # Clé de la sauvegarde lue : `nil` en clair ; chiffrée, celle que
    # l'administration a remise (capsule ouverte hors du serveur), ou refus.
    def self.source_identity!(ctx : Context, source : Source) : String?
      return unless source.sealed?
      ctx.keyring.identity_for(source.manifest.recipient) ||
        raise StepError.new("sauvegarde chiffrée : la restauration exige sa clé (capsule ouverte par la clé " \
                            "d'exploitation ou par l'admin du cabinet)", "key_required")
    end

    # Restauration test : la sauvegarde est relue dans une base temporaire,
    # l'instance y répond (`status`), puis la base est supprimée. Prouve
    # qu'une sauvegarde se relit (ADR-008 D5).
    #
    # Chiffrée sans que sa clé soit fournie : le serveur ne peut pas la lire
    # (D-CHF-017) ; la signature du manifeste, les empreintes et la
    # structure des fichiers `age` sont vérifiées, et le résultat le dit.
    def self.test_restore(ctx : Context) : Nil
      system = ctx.system
      source = source(ctx)
      identity = source.sealed? ? ctx.keyring.identity_for(source.manifest.recipient) : nil
      if source.sealed? && identity.nil?
        system.check_envelope(source.dump)
        system.check_envelope(source.media) unless source.media.empty?
        ctx.log("contenu vérifiable seulement avec la clé de la sauvegarde : signature, empreintes et structure vérifiées")
        ctx.set("verified", false)
        ctx.set("envelope_verified", true)
        ctx.set("check", "envelope")
        return
      end
      scratch = system.scratch_database(ctx.slug, ctx.task.id)
      begin
        system.dropdb(scratch) if system.database_exists?(scratch)
        system.createdb(scratch)
        system.restore_database(scratch, source.dump, identity)
        status = ctx.instance!("status", database: scratch)
        raise StepError.new("sauvegarde relue mais instance non provisionnée") unless status["provisioned"]?.try(&.as_bool?)
        raise StepError.new("archive des pièces illisible") unless source.media.empty? || system.media_readable?(source.media, identity)
        ctx.set("version", status["version"]? || "")
        ctx.set("verified", true)
        ctx.set("check", "full")
      ensure
        system.dropdb(scratch)
      end
    end

    # Restauration à une date : dans une instance neuve (`new`) ou en
    # remplacement (`replace`, après une sauvegarde de sûreté), sur ce
    # serveur, quel que soit celui qui a pris la sauvegarde (D-CHF-016).
    # Chiffrée, la sauvegarde est d'abord authentifiée en entier : rien
    # n'est remplacé par un fichier altéré ou avec une mauvaise clé.
    def self.restore(ctx : Context) : Nil
      # Instance neuve : sous-domaine et hôte vérifiés avant tout geste.
      new_target(ctx) if ctx.param("target") == "new"
      source = source(ctx)
      identity = source_identity!(ctx, source)
      if identity
        ctx.step("authentification de la sauvegarde") do
          ctx.system.verify_sealed(source.dump, identity)
          ctx.system.verify_sealed(source.media, identity) unless source.media.empty?
        end
      end
      if ctx.param("target") == "new"
        restore_new(ctx, source.dump, source.media, identity)
      else
        restore_replace(ctx, source.dump, source.media, identity)
      end
    end

    # Sous-domaine et hôte de l'instance neuve, vérifiés.
    def self.new_target(ctx : Context) : {String, String}
      new_slug = ctx.param("new_slug")
      raise StepError.new("sous-domaine invalide : #{new_slug}", "usage") unless PartiduoAdmin::Protocol.valid_slug?(new_slug)
      raise StepError.new("instance neuve identique à la source", "usage") if new_slug == ctx.slug
      {new_slug, ctx.host_for(new_slug, "new_host")}
    end

    # Instance neuve : base restaurée, fichiers de service produits par
    # `partiduo-provision --files-only` (nouveau port, nouvelle clé
    # secrète), installation comme à la création (service, vhost,
    # certificat compté dans le quota), pièces jointes (D-AFN-009).
    def self.restore_new(ctx : Context, path : String, media : String, identity : String?) : Nil
      system = ctx.system
      new_slug, host = new_target(ctx)
      database = system.database_for(new_slug)
      ctx.step("base neuve") do
        system.dropdb(database) if system.database_exists?(database)
        system.createdb(database)
        system.restore_database(database, path, identity)
      end
      ctx.step("fichiers de service") do
        system.provision_files(new_slug, ctx.domain, ctx.params, database, connect: system.connect_client(host))
      end
      ctx.step("installation") do
        ctx.journal["certificate"] = system.install_instance(new_slug, host, ctx.package.presence || "app").to_s
      end
      ctx.step("pièces jointes") { system.restore_media(new_slug, media, identity) unless media.empty? }
      ctx.set("database", database)
      status = ctx.instance!("status", package: ctx.package.presence || "app", database: database, slug_override: new_slug)
      ctx.set("version", status["version"]? || "")
      ctx.set("certificate", {"issued" => ctx.journal["certificate"]? == "true", "staging" => system.config.acme_staging})
    end

    # Remplacement : service arrêté AVANT la sauvegarde de sûreté (rien
    # n'est écrit entre les deux), base puis pièces jointes remplacées.
    # Un échec avant le remplacement de la base redémarre le service.
    def self.restore_replace(ctx : Context, path : String, media : String, identity : String?) : Nil
      system = ctx.system
      begin
        ctx.step("arrêt du service") { system.service(ctx.slug, "stop") }
        safety = backup(ctx, "pre_restore", prefix: "pre-restore")
        ctx.result.clear
        ctx.set("safety_backup", safety)
      rescue error
        system.service(ctx.slug, "start")
        raise error
      end
      ctx.step("base remplacée") do
        system.dropdb(ctx.database)
        system.createdb(ctx.database)
        system.restore_database(ctx.database, path, identity)
      end
      ctx.step("pièces jointes") { system.restore_media(ctx.slug, media, identity) unless media.empty? }
      ctx.step("démarrage du service") { system.service(ctx.slug, "start") }
      ctx.set("version", ctx.instance!("status")["version"]? || "")
    end

    # --- Supervision ---------------------------------------------------------------

    # Une entrée mal formée ou dont l'hôte ou la base ne correspondent pas
    # au sous-domaine est ignorée (et journalisée) : elle ne fait pas
    # échouer la supervision des autres dossiers du serveur.
    def self.supervision(ctx : Context) : Nil
      system = ctx.system
      total, free = system.disk(system.config.backup_dir)
      ctx.set("disk", {"total_bytes" => total, "free_bytes" => free})
      entries = (ctx.params["dossiers"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |entry|
        supervise(ctx, entry)
      end
      ctx.set("dossiers", entries)
    end

    def self.supervise(ctx : Context, entry : JSON::Any) : Hash(String, String?)?
      system = ctx.system
      slug = entry.as_h?.try(&.["slug"]?).try(&.as_s?) || ""
      unless PartiduoAdmin::Protocol.valid_slug?(slug)
        ctx.log("supervision : entrée ignorée (sous-domaine invalide)")
        return
      end
      database = system.database_for(slug)
      host = supervised_host(ctx, slug, entry)
      given_database = entry["database"]?.try(&.as_s?) || ""
      if host.nil? || !(given_database.empty? || given_database == database)
        ctx.log("supervision : #{slug} ignoré (hôte ou base sans rapport avec le sous-domaine)")
        return
      end
      reply = system.instance(slug, "status", ["--task", ctx.task.id.to_s], nil, database)
      {
        "slug"            => slug,
        "service"         => system.service(slug, "status"),
        "database"        => database_state(reply),
        "version"         => reply.ok? ? (reply.data["version"]?.try(&.as_s?) || "") : "",
        "cert_expires_at" => (host.empty? ? nil : system.cert_expiry(host)).try(&.to_rfc3339),
      }
    rescue error : StepError
      ctx.log("supervision : #{slug} en erreur (#{error.message})")
      nil
    end

    private def self.database_state(reply : InstanceReply) : String
      return "ok" if reply.ok?
      reply.exit_code == 6 ? "unavailable" : "error"
    end

    # Hôte d'un dossier supervisé : `<sous-domaine>.<domaine>` (domaine de
    # l'exécutant, sinon de la tâche) ; l'hôte reçu doit être celui-là.
    # `nil` si l'entrée désigne un autre hôte ; chaîne vide si aucun n'est
    # connu (pas de relevé de certificat).
    private def self.supervised_host(ctx : Context, slug : String, entry : JSON::Any) : String?
      given = entry["host"]?.try(&.as_s?) || ""
      domain = ctx.system.config.domain.presence || ctx.param("domain").presence
      expected = domain ? "#{slug}.#{domain}" : given
      return unless given.empty? || given == expected
      return expected if expected.empty?
      expected.starts_with?("#{slug}.") && PartiduoAdmin::Protocol.valid_domain?(expected) ? expected : nil
    end
  end
end

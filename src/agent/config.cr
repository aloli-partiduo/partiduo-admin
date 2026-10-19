# SPDX-License-Identifier: AGPL-3.0-or-later

require "marten-mail/client"
require "option_parser"
require "uri"

module PartiduoAgent
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Modes de l'exécutant :
  #
  # * `dry-run` (à blanc) : rien n'est exécuté ; chaque geste est simulé et
  #   inscrit au journal renvoyé à l'admin (specs, répétition) ;
  # * `local` : développement — opère réellement sur des bases
  #   `partiduo_adm_*` de la machine, sans vhost, service rc.d ni Let's
  #   Encrypt : les fichiers de service sont produits dans `work_dir` ;
  # * `production` : serveur d'hébergement FreeBSD (sudo, service(8),
  #   acme.sh), par les enveloppes de `helpers_dir`.
  enum Mode
    DryRun
    Local
    Production

    def label : String
      case self
      in DryRun     then "dry-run"
      in Local      then "local"
      in Production then "production"
      end
    end

    def self.parse(value : String) : Mode
      case value
      when "dry-run", "dry_run", "dryrun" then DryRun
      when "local"                        then Local
      when "production"                   then Production
      else                                     raise ArgumentError.new("mode inconnu : #{value} (dry-run, local, production)")
      end
    end
  end

  class Config
    property admin_url : String = ENV["PARTIDUO_ADMIN_URL"]? || "https://admin.partiduo.app"
    property token : String = ENV["PARTIDUO_AGENT_TOKEN"]? || ""
    property mode : Mode = Mode::DryRun
    property state_dir : String = ENV["PARTIDUO_AGENT_STATE"]? || "/var/db/partiduo-agent"
    property work_dir : String = File.join(Dir.tempdir, "partiduo-agent")
    property backup_dir : String = "/var/db/partiduo-backups"
    # Mode local : outils des paquets `app` (`partiduo-app`) et `devel`
    # (`partiduo-app-devel`). Les deux paquets s'installent aux mêmes
    # emplacements (un seul par serveur) : par défaut, leurs liens de
    # /usr/local/bin ; ceux de `devel` vides : ceux de `app` (à fournir
    # seulement pour essayer deux versions côte à côte hors paquet). En
    # production, les enveloppes prennent ceux du paquet installé
    # (/usr/local/lib/partiduo/bin).
    property manage : String = ENV["PARTIDUO_MANAGE"]? || "/usr/local/bin/partiduo-manage"
    property provision : String = ENV["PARTIDUO_PROVISION"]? || "/usr/local/bin/partiduo-provision"
    property manage_devel : String = ENV["PARTIDUO_MANAGE_DEVEL"]? || ""
    property provision_devel : String = ENV["PARTIDUO_PROVISION_DEVEL"]? || ""
    property system_user : String = "partiduo"
    # Domaine des dossiers de ce serveur (`<sous-domaine>.<domaine>`) : les
    # hôtes reçus de l'administration doivent lui correspondre (D-AFN-004).
    # Obligatoire en production ; ailleurs, celui de la tâche.
    property domain : String = ""
    # Production : scripts enveloppes possédés par root (D-AFN-002).
    property helpers_dir : String = "/usr/local/libexec/partiduo-agent"
    property pg_socket : String = "/tmp"
    property acme_email : String = ""
    property acme_staging : Bool = false
    # Remise des invitations par le serveur (D-CRA-003), par le compte SMTP de
    # Partiduo (marten-mail) : fichier qui contient l'URL du compte
    # (`smtp://notifications%40partiduo.app:secret@hôte:587`, posé par beryl
    # depuis le coffre ; jamais en argument, visible par ps) et expéditeur.
    # Jamais le relais du serveur, réservé aux alertes du système. Vide : le
    # lien est rendu à l'administration, qui l'envoie (D-ADM-009).
    property smtp_url_file : String = ""
    property mail_from : String = ""
    # connect (ADR-012) : émetteur et fichier du jeton de registraire de ce
    # serveur (posé par beryl depuis le coffre). Réglés, chaque dossier créé
    # reçoit son client connect ; vides, les dossiers gardent la connexion
    # locale seule.
    property connect_url : String = ""
    property connect_token_file : String = ""
    # Nom de ce serveur (celui de l'administration) : répertoire des
    # sauvegardes qu'il prend dans le stockage, signataire de leurs
    # manifestes (D-CHF-018, D-CHF-024). Vide : nom court de la machine.
    property server_name : String = ""
    # Stockage des sauvegardes (D-CHF-024, D-CHF-025), l'un ou l'autre :
    # * commande, sans shell, qui parle le protocole de `partiduo-agent
    #   store-serve` (en général `ssh` vers un serveur de sauvegarde) ;
    # * répertoire de cette machine (`store_dir`), quand il n'y a pas de
    #   serveur de sauvegarde ; défaut hors production : `<state_dir>/store`.
    # En production, l'un des deux est obligatoire.
    property store_command : String = ""
    property store_dir : String = ""
    # Clés publiques d'exploitation (`age1pq1…`, une par ligne, D-CHF-015)
    # et clé de signature Ed25519 du serveur (D-CHF-018), posées par beryl en
    # production ; ailleurs, dans `state_dir` (la clé de signature y est
    # créée au premier usage).
    property recipients_file : String = ""
    property signing_key_file : String = ""
    property poll_interval : Time::Span = 15.seconds
    property once : Bool = false
    # À blanc : fait échouer la première opération dont le nom contient
    # cette valeur (specs des échecs et de la reprise).
    property fail_on : String? = nil

    def self.parse(args : Array(String)) : Config
      config = new
      token_file = nil
      OptionParser.parse(args) do |parser|
        parser.banner = "Usage : partiduo-agent [options]\n\nExécutant de partiduo-admin (ADR-008 D4)."
        parser.on("--admin-url URL", "adresse de l'administration (HTTPS)") { |value| config.admin_url = value }
        parser.on("--token-file FICHIER", "fichier du jeton du serveur") { |value| token_file = value }
        parser.on("--mode MODE", "dry-run, local ou production (défaut : dry-run)") { |value| config.mode = Mode.parse(value) }
        parser.on("--state-dir RÉP", "état des tâches en cours (reprise)") { |value| config.state_dir = value }
        parser.on("--work-dir RÉP", "mode local : fichiers produits") { |value| config.work_dir = value }
        parser.on("--backup-dir RÉP", "répertoire des sauvegardes") { |value| config.backup_dir = value }
        parser.on("--manage CHEMIN", "mode local : partiduo-manage du paquet app") { |value| config.manage = value }
        parser.on("--provision CHEMIN", "mode local : partiduo-provision du paquet app") { |value| config.provision = value }
        parser.on("--manage-devel CHEMIN", "mode local : partiduo-manage du paquet devel") { |value| config.manage_devel = value }
        parser.on("--provision-devel CHEMIN", "mode local : partiduo-provision du paquet devel") do |value|
          config.provision_devel = value
        end
        parser.on("--system-user NOM", "compte système des instances") { |value| config.system_user = value }
        parser.on("--domain DOMAINE", "domaine des dossiers de ce serveur (obligatoire en production)") { |value| config.domain = value }
        parser.on("--helpers-dir RÉP", "production : scripts enveloppes de sudo") { |value| config.helpers_dir = value }
        parser.on("--pg-socket RÉP", "socket PostgreSQL") { |value| config.pg_socket = value }
        parser.on("--acme-email ADRESSE", "compte ACME") { |value| config.acme_email = value }
        parser.on("--acme-staging", "autorité de test de Let's Encrypt") { config.acme_staging = true }
        parser.on("--smtp-url-file FICHIER", "remise des invitations par le serveur : fichier contenant l'URL du compte SMTP") do |value|
          config.smtp_url_file = value
        end
        parser.on("--mail-from ADRESSE", "expéditeur des invitations remises par le serveur") { |value| config.mail_from = value }
        parser.on("--connect-url URL", "connect (ADR-012) : émetteur, https://connect.<domaine>") { |value| config.connect_url = value }
        parser.on("--connect-token-file FICHIER", "connect : fichier du jeton de registraire de ce serveur") do |value|
          config.connect_token_file = value
        end
        parser.on("--server-name NOM", "nom de ce serveur dans l'administration (défaut : nom court de la machine)") do |value|
          config.server_name = value
        end
        parser.on("--store-command COMMANDE", "stockage des sauvegardes sur un serveur de sauvegarde " \
                                              "(ex. « /usr/bin/ssh -T partiduo-store@quantas »)") do |value|
          config.store_command = value
        end
        parser.on("--store-dir RÉP", "stockage des sauvegardes dans un répertoire de ce serveur " \
                                     "(sans serveur de sauvegarde ; ex. /var/db/partiduo-store)") do |value|
          config.store_dir = value
        end
        parser.on("--recipients FICHIER", "clés publiques d'exploitation (défaut en production : #{ETC}/exploitation.recipients)") do |value|
          config.recipients_file = value
        end
        parser.on("--signing-key FICHIER", "clé de signature Ed25519 du serveur (défaut en production : #{ETC}/backup-signing.key)") do |value|
          config.signing_key_file = value
        end
        parser.on("--poll SECONDES", "intervalle d'interrogation") { |value| config.poll_interval = value.to_i.seconds }
        parser.on("--once", "traite au plus une tâche puis s'arrête") { config.once = true }
        parser.on("--fail-on TEXTE", "à blanc seulement : fait échouer la première opération qui contient TEXTE " \
                                     "(répétition d'un échec)") { |value| config.fail_on = value }
        parser.on("-h", "--help", "cette aide") do
          puts parser
          exit 0
        end
      end
      if file = token_file
        config.token = File.read(file).strip
      end
      config.validate!
      config
    end

    def validate! : Nil
      raise ArgumentError.new("jeton manquant (--token-file ou PARTIDUO_AGENT_TOKEN)") if token.empty?
      uri = URI.parse(admin_url)
      host = uri.host.to_s
      local = host == "127.0.0.1" || host == "localhost" || host.ends_with?(".localhost")
      # HTTPS obligatoire (ADR-008 D4), sauf vers la machine elle-même.
      raise ArgumentError.new("l'administration doit être jointe en HTTPS : #{admin_url}") unless uri.scheme == "https" || local
      raise ArgumentError.new("le mode production exige HTTPS") if mode.production? && uri.scheme != "https"
      unless domain.empty? || PartiduoAdmin::Protocol.valid_domain?(domain)
        raise ArgumentError.new("domaine invalide : #{domain}")
      end
      raise ArgumentError.new("le mode production exige --domain") if mode.production? && domain.empty?
      validate_fail_on!
      validate_mail!
      validate_store!
      validate_connect!
    end

    # Stockage : un serveur de sauvegarde (D-CHF-024) ou un répertoire de ce
    # serveur (D-CHF-025), jamais les deux ; en production, l'un des deux.
    # Un répertoire ne se confond pas avec celui des sauvegardes en
    # préparation, que l'exécutant vide à chaque tâche.
    private def validate_store! : Nil
      raise ArgumentError.new("nom de serveur invalide : #{server}") unless Locator.valid_server?(server)
      unless store_argv.empty? || store_dir.empty?
        raise ArgumentError.new("--store-command et --store-dir s'excluent : un seul stockage")
      end
      if store_argv.empty?
        store = File.expand_path(store_path)
        backups = File.expand_path(backup_dir)
        if store == backups || store.starts_with?("#{backups}/") || backups.starts_with?("#{store}/")
          raise ArgumentError.new("stockage #{store} refusé : distinct du répertoire des sauvegardes en préparation (#{backups})")
        end
      end
      return unless mode.production?
      if store_argv.empty? && store_dir.empty?
        raise ArgumentError.new("le mode production exige --store-command (serveur de sauvegarde) ou --store-dir " \
                                "(stockage sur ce serveur)")
      end
    end

    # Sauvegardes gardées sur ce serveur (D-CHF-025) : rien ne les copie
    # ailleurs.
    def local_store? : Bool
      store_argv.empty?
    end

    # URL du compte SMTP (contenu de --smtp-url-file), vide sans remise par
    # le serveur. Lue à chaque envoi : un secret changé par beryl est pris
    # sans redémarrage.
    def smtp_url : String
      smtp_url_file.empty? ? "" : File.read(smtp_url_file).strip
    end

    # Remise des invitations par le serveur : fichier lisible, URL valide,
    # expéditeur obligatoire.
    private def validate_mail! : Nil
      return if smtp_url_file.empty?
      raise ArgumentError.new("--smtp-url-file exige --mail-from (adresse de l'expéditeur)") unless InvitationMail.valid_address?(mail_from)
      begin
        MartenMail::Client.from_url(smtp_url)
      rescue ex : File::Error
        raise ArgumentError.new("--smtp-url-file illisible : #{smtp_url_file} (#{ex.message})")
      rescue ex : ArgumentError | URI::Error
        raise ArgumentError.new("--smtp-url-file : URL SMTP invalide (#{ex.message})")
      end
    end

    # connect : les deux réglages ensemble, en HTTPS (sauf vers la machine
    # elle-même), jeton lisible.
    private def validate_connect! : Nil
      return if connect_url.empty? && connect_token_file.empty?
      raise ArgumentError.new("--connect-url et --connect-token-file vont ensemble") if connect_url.empty? || connect_token_file.empty?
      uri = URI.parse(connect_url)
      host = uri.host.to_s
      local = host == "127.0.0.1" || host == "localhost" || host.ends_with?(".localhost")
      allowed = uri.scheme == "https" || (local && !mode.production?)
      raise ArgumentError.new("connect doit être joint en HTTPS : #{connect_url}") unless allowed
      raise ArgumentError.new("--connect-token-file : jeton vide") if connect_token.empty?
    rescue ex : File::Error
      raise ArgumentError.new("--connect-token-file illisible : #{connect_token_file} (#{ex.message})")
    end

    def connect? : Bool
      !connect_url.empty?
    end

    # Jeton de registraire, relu à chaque usage (changé par beryl sans
    # redémarrage).
    def connect_token : String
      connect_token_file.empty? ? "" : File.read(connect_token_file).strip
    end

    # Échec simulé : jamais sur un vrai système.
    private def validate_fail_on! : Nil
      raise ArgumentError.new("--fail-on n'est permis qu'à blanc") if fail_on && !mode.dry_run?
    end

    # Configuration posée par beryl en production.
    ETC = "/usr/local/etc/partiduo-agent"

    def server : String
      server_name.presence || ::System.hostname.split('.').first.downcase
    end

    def store_argv : Array(String)
      store_command.split(' ', remove_empty: true)
    end

    def store_path : String
      store_dir.presence || File.join(state_dir, "store")
    end

    def recipients_path : String
      recipients_file.presence || File.join(production? ? ETC : state_dir, "exploitation.recipients")
    end

    def signing_key_path : String
      signing_key_file.presence || File.join(production? ? ETC : state_dir, "backup-signing.key")
    end

    def local? : Bool
      mode.local?
    end

    def production? : Bool
      mode.production?
    end
  end
end

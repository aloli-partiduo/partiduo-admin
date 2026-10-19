# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoConnect
  module Commands
    # `partiduo-connect-manage client <add|list|rotate|disable|enable> …`
    #
    # Clients OpenID Connect (ADR-012 D3) : un dossier ou l'administration.
    # Le secret n'est affiché qu'une fois, à la création ou au changement ;
    # il va au coffre, d'où beryl le pose chez le client.
    class ClientCommand < Marten::CLI::Manage::Command::Base
      command_name :client
      help "Déclare et gère les clients OpenID Connect (ADR-012 D3)."

      @action = ""
      @client_id = ""
      @name = ""
      @redirect_uris = [] of String
      @post_logout_uris = [] of String
      @backchannel = ""

      def setup
        on_argument(:action, "add, list, rotate, disable ou enable") { |value| @action = value }
        on_option_with_arg("client-id", "id", "identifiant (défaut : tiré au hasard ; nom du dossier conseillé)") { |value| @client_id = value }
        on_option_with_arg("name", "nom", "nom affiché à la connexion") { |value| @name = value }
        on_option_with_arg("redirect-uri", "adresse", "adresse de retour (répétable)") { |value| @redirect_uris << value }
        on_option_with_arg("post-logout-uri", "adresse", "adresse après déconnexion (répétable)") { |value| @post_logout_uris << value }
        on_option_with_arg("backchannel-uri", "adresse", "adresse de déconnexion par canal arrière") { |value| @backchannel = value }
      end

      def run
        case @action
        when "add"     then add
        when "list"    then list
        when "rotate"  then rotate
        when "disable" then toggle(false)
        when "enable"  then toggle(true)
        else                print_error_and_exit("action inconnue : #{@action} (add, list, rotate, disable, enable)")
        end
      end

      private def add
        return print_error_and_exit("--name et au moins une --redirect-uri sont exigés") if @name.empty? || @redirect_uris.empty?
        if !@client_id.empty? && Client.filter(client_id: @client_id).exists?
          return print_error_and_exit("client déjà déclaré : #{@client_id} (rotate pour changer son secret)")
        end
        registered = Clients.register(@name, @redirect_uris, @post_logout_uris, @backchannel, @client_id.presence)
        print("client_id     : #{registered.client.client_id}")
        print("client_secret : #{registered.secret}")
        print("Secret affiché une seule fois : à mettre au coffre.")
      rescue error : ArgumentError
        print_error_and_exit(error.message.to_s)
      end

      private def list
        Client.all.order("client_id").each do |client|
          state = client.active ? "actif" : "désactivé"
          print("#{client.client_id}  #{client.name}  (#{state})")
          client.redirect_uri_list.each { |uri| print("  retour       : #{uri}") }
          client.post_logout_redirect_uri_list.each { |uri| print("  déconnexion  : #{uri}") }
          print("  canal arrière : #{client.backchannel_logout_uri}") unless client.backchannel_logout_uri.to_s.empty?
        end
      end

      private def rotate
        client = Client.filter(client_id: @client_id).first
        return print_error_and_exit("client inconnu : #{@client_id}") if client.nil?
        print("client_secret : #{Clients.rotate_secret(client)}")
        print("Secret affiché une seule fois : à mettre au coffre. L'ancien ne vaut plus.")
      end

      private def toggle(active : Bool) : Nil
        client = Client.filter(client_id: @client_id).first
        return print_error_and_exit("client inconnu : #{@client_id}") if client.nil?
        client.active = active
        client.save!
        Audit.log(nil, active ? "client.enable" : "client.disable", client: client, label: "exploitation")
        print("#{client.client_id} : #{active ? "actif" : "désactivé"}")
      end
    end

    # `partiduo-connect-manage invite --email=… [--name=…] [--locale=fr]`
    #
    # Invitation à créer un compte sans passer par un client (amorçage :
    # premier super-admin de l'administration). Affiche le lien et le code ;
    # le code se transmet par un autre canal que le lien (ADR-012 D6).
    class InviteCommand < Marten::CLI::Manage::Command::Base
      command_name :invite
      help "Invite une personne à créer son compte (lien + code, ADR-012 D6)."

      @email = ""
      @name = ""
      @locale = "fr"

      def setup
        on_option_with_arg("email", "adresse", "adresse de la personne") { |value| @email = value }
        on_option_with_arg("name", "nom", "nom affiché") { |value| @name = value }
        on_option_with_arg("locale", "langue", "fr, en ou nl") { |value| @locale = value }
      end

      def run
        issued = Signup.issue(@email, @name, @locale, created_by: "exploitation")
        print("Lien (valable #{Config::SIGNUP_TTL.days} jours) : #{issued.url}")
        print("Code (à transmettre par un autre canal)  : #{issued.code}")
      rescue error : Signup::Error
        print_error_and_exit(I18n.t(error.key))
      end
    end

    # `partiduo-connect-manage signing-key generate`
    #
    # Nouvelle clé de signature ES256, sur une ligne, pour le coffre
    # (ADR-012 D5). Rien n'est écrit sur le disque.
    class SigningKeyCommand < Marten::CLI::Manage::Command::Base
      command_name :"signing-key"
      help "Tire une clé de signature ES256 pour le coffre (ADR-012 D5)."

      @action = ""

      def setup
        on_argument(:action, "generate ou list") { |value| @action = value }
      end

      def run
        case @action
        when "generate" then print(SigningKeys.generate)
        when "list"
          SigningKeys.keys.each_with_index do |key, index|
            print("#{SigningKeys.kid(key)}#{index.zero? ? "  (signe)" : "  (publiée)"}")
          end
        else
          print_error_and_exit("action inconnue : #{@action} (generate, list)")
        end
      end
    end

    # `partiduo-connect-manage account <show|suspend|reactivate|unlock> --email=…`
    #
    # Exploitation d'un compte : suspension (sessions fermées, clients
    # avisés), réactivation, déblocage après trop d'échecs.
    class AccountCommand < Marten::CLI::Manage::Command::Base
      command_name :account
      help "Montre, suspend, réactive ou débloque un compte (ADR-012 D7)."

      @action = ""
      @email = ""

      def setup
        on_argument(:action, "show, suspend, reactivate ou unlock") { |value| @action = value }
        on_option_with_arg("email", "adresse", "adresse du compte") { |value| @email = value }
      end

      def run
        account = Account.filter(email: @email.strip.downcase).first
        return print_error_and_exit("compte inconnu : #{@email}") if account.nil?
        case @action
        when "show"
          print("#{account.email}  sub=#{account.sub}  #{account.active ? "actif" : "suspendu"}#{account.locked? ? ", bloqué" : ""}")
          print("  passkeys : #{Passkey.filter(account_id: account.pk).count}  TOTP : #{account.totp_enabled? ? "oui" : "non"}  " \
                "codes restants : #{Auth::RecoveryCodes.remaining(account)}")
        when "suspend"
          Auth.suspend(account, Config.now)
          print("#{account.email} : suspendu, sessions fermées.")
        when "reactivate"
          Auth.reactivate(account)
          print("#{account.email} : réactivé.")
        when "unlock"
          Auth::Throttle.unlock(account)
          Audit.log(account, "account.unlock", label: account.email.to_s)
          print("#{account.email} : débloqué.")
        else
          print_error_and_exit("action inconnue : #{@action} (show, suspend, reactivate, unlock)")
        end
      end
    end
  end
end

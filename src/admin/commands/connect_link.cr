# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  module Commands
    # `manage connect-link --email=… --sub=…`
    #
    # Passage à connect (ADR-012 D4) d'un utilisateur qui existait avant :
    # lie son compte à son identité connect, que l'exploitation lit chez
    # connect (`partiduo-connect-manage account show --email=…`). Geste
    # d'exploitation sur le serveur, journalisé ; un compte déjà lié n'est
    # jamais relié à une autre identité (passer par une nouvelle invitation).
    class ConnectLink < Marten::CLI::Manage::Command::Base
      command_name :"connect-link"
      help "Lie un utilisateur existant à son identité connect (ADR-012 D4)."

      @email = ""
      @sub = ""

      def setup
        on_option_with_arg("email", "adresse", "adresse de l'utilisateur") { |value| @email = value }
        on_option_with_arg("sub", "identifiant", "identifiant connect (sub) du compte de la même adresse") { |value| @sub = value }
      end

      def run
        user = User.filter(email: @email.strip.downcase).first
        return print_error_and_exit("utilisateur inconnu : #{@email}") if user.nil?
        return print_error_and_exit("--sub est exigé") if @sub.strip.empty?
        if (current = user.connect_sub) && current != @sub.strip
          return print_error_and_exit("déjà lié à une autre identité : passer par une nouvelle invitation")
        end
        if User.filter(connect_sub: @sub.strip).exclude(id: user.pk).exists?
          return print_error_and_exit("cette identité est déjà liée à un autre utilisateur")
        end
        user.connect_sub = @sub.strip
        user.save!
        Audit.log(nil, "user.connect_link", target: user, actor_label: "exploitation")
        print("#{user.email} : lié à l'identité connect #{@sub.strip}.")
      end
    end
  end
end

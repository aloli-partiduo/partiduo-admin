# SPDX-License-Identifier: AGPL-3.0-or-later

require "../shared/backup_crypto"

module PartiduoAgent
  alias BackupCrypto = PartiduoAdmin::BackupCrypto

  # Clés de sauvegarde dont dispose l'exécutant pour une tâche (D-CHF-014,
  # D-CHF-016) :
  #
  # * celles que la tâche vient de tirer (journal de reprise, clés
  #   `secret.*`, effacées à la fin de la tâche) ;
  # * celles que l'administration remet pour lire une sauvegarde chiffrée :
  #   capsule ouverte sur le poste de l'exploitant (clé d'exploitation) ou
  #   dans le navigateur de l'admin du cabinet (clé du cabinet), remises une
  #   seule fois, gardées en mémoire.
  #
  # Ni la clé privée d'exploitation, ni celle d'un cabinet ne sont jamais
  # ici : le serveur n'a que des clés publiques.
  class Keyring
    SECRET_PREFIX = "secret."

    @given : Array(String)
    @recipients = {} of String => String?

    # `resolve` : destinataire d'une clé de sauvegarde (`age-keygen -y`, ou
    # simulé à blanc).
    def initialize(@journal : Journal, data_keys : Array(String), @resolve : Proc(String, String?))
      @given = data_keys.map(&.strip).select { |value| BackupCrypto.valid_identity?(value) }
    end

    # Clés de sauvegarde connues : remises par l'administration, puis celles
    # du journal de la tâche.
    def identities : Array(String)
      @given + @journal.values.compact_map do |key, value|
        value if key.starts_with?(SECRET_PREFIX) && BackupCrypto.valid_identity?(value)
      end
    end

    # Clé de sauvegarde dont le destinataire est `recipient`, ou `nil`.
    def identity_for(recipient : String) : String?
      return if recipient.empty?
      identities.find { |identity| recipient_of(identity) == recipient }
    end

    private def recipient_of(identity : String) : String?
      return @recipients[identity] if @recipients.has_key?(identity)
      @recipients[identity] = @resolve.call(identity)
    end
  end
end

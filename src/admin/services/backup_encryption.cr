# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "base64"

module PartiduoAdmin
  # Chiffrement des sauvegardes, réglé dans l'administration (DECISIONS
  # D-CHF-001 à D-CHF-024) :
  #
  # [cols="1,3"]
  # |===
  # |Mode |Effet
  # |`none` |aucun chiffrement
  # |`exploitation` |clé d'exploitation (défaut) : le serveur n'a que des clés publiques ; restauration
  #   avec la clé de la sauvegarde, sortie de sa capsule sur le poste de l'exploitant
  # |`cabinet` |clé publique du cabinet : ni le serveur ni l'exploitant ne lisent les sauvegardes ;
  #   restauration avec la clé privée de l'admin du cabinet, utilisée dans son navigateur
  # |===
  #
  # Réglage du cabinet (valeur par défaut), surchargeable par dossier ; un
  # changement vaut pour les sauvegardes suivantes, chacune garde son mode.
  #
  # Droits : le réglage appartient au super-admin et à l'admin du cabinet ;
  # *déposer la clé du cabinet* ou *quitter le mode « clé du cabinet »*
  # appartient à l'admin du cabinet seul — l'exploitant du parc ne peut pas
  # affaiblir le choix d'un cabinet (D-CHF-008).
  module BackupEncryption
    MODES = BackupCrypto::MODES

    alias Outcome = Fleet::Outcome

    # --- Droits -----------------------------------------------------------------

    def self.can_manage?(user : User, firm : Firm) : Bool
      user.super_admin? || (user.firm_admin? && user.firm_id == firm.pk)
    end

    def self.can_deposit_key?(user : User, firm : Firm) : Bool
      user.firm_admin? && user.firm_id == firm.pk
    end

    # Quitter « clé du cabinet » rend les sauvegardes suivantes lisibles par
    # le serveur : réservé à l'admin du cabinet.
    def self.can_leave_cabinet?(user : User, firm : Firm) : Bool
      can_deposit_key?(user, firm)
    end

    # --- Réglages ---------------------------------------------------------------

    def self.set_firm_mode(user : User, firm : Firm, mode : String) : Outcome(Firm)
      return Outcome(Firm).failure("base", "admin.errors.forbidden") unless can_manage?(user, firm)
      return Outcome(Firm).failure("mode", "admin.errors.invalid") unless MODES.includes?(mode)
      previous = firm.backup_encryption.to_s
      return Outcome(Firm).new(firm) if previous == mode
      if refusal = change_refusal(user, firm, previous, mode)
        return Outcome(Firm).failure("mode", refusal)
      end
      firm.backup_encryption = mode
      firm.save!
      Audit.log(user, "backup_encryption.firm", target: firm, detail: {"from" => previous, "to" => mode})
      Outcome(Firm).new(firm)
    end

    # `mode` vide : le dossier reprend le réglage du cabinet.
    def self.set_dossier_mode(user : User, dossier : Dossier, mode : String) : Outcome(Dossier)
      firm = dossier.firm!
      unless can_manage?(user, firm) && Access.can?(user, :restore, dossier)
        return Outcome(Dossier).failure("base", "admin.errors.forbidden")
      end
      return Outcome(Dossier).failure("mode", "admin.errors.invalid") unless mode.empty? || MODES.includes?(mode)
      following = mode.presence || firm.backup_encryption.to_s
      if refusal = change_refusal(user, firm, dossier.effective_encryption, following)
        return Outcome(Dossier).failure("mode", refusal)
      end
      before = dossier.backup_encryption.to_s
      return Outcome(Dossier).new(dossier) if before == mode
      dossier.backup_encryption = mode
      dossier.save!
      Audit.log(user, "backup_encryption.dossier", target: dossier,
        detail: {"from" => before.presence || "firm", "to" => mode.presence || "firm", "effective" => following})
      Outcome(Dossier).new(dossier)
    end

    # Motif de refus d'un passage de `previous` à `following` : « clé du
    # cabinet » sans clé déposée, ou sortie de ce mode par un autre que
    # l'admin du cabinet.
    private def self.change_refusal(user : User, firm : Firm, previous : String, following : String) : String?
      return "admin.errors.encryption.no_key" if following == "cabinet" && firm.backup_key?.nil?
      if previous == "cabinet" && following != "cabinet" && !can_leave_cabinet?(user, firm)
        "admin.errors.encryption.leave_cabinet"
      end
    end

    # Dépôt (ou remplacement) de la clé publique du cabinet. Les sauvegardes
    # déjà prises gardent la clé de leur prise (empreinte affichée).
    def self.deposit_key(user : User, firm : Firm, pem : String) : Outcome(Firm)
      return Outcome(Firm).failure("base", "admin.errors.forbidden") unless can_deposit_key?(user, firm)
      key = begin
        BackupCrypto::PublicKey.new(pem.strip + "\n")
      rescue BackupCrypto::Error
        return Outcome(Firm).failure("public_key", "admin.errors.encryption.public_key")
      end
      previous = firm.backup_key_fingerprint.to_s
      firm.backup_public_key = key.pem
      firm.backup_key_fingerprint = key.fingerprint
      firm.backup_key_set_at = Config.now
      firm.save!
      Audit.log(user, "backup_key.deposit", target: firm,
        detail: {"fingerprint" => key.fingerprint, "previous" => previous, "bits" => key.bits.to_s})
      Outcome(Firm).new(firm)
    end

    # --- Paramètres des tâches --------------------------------------------------

    # Réglage des sauvegardes que prendra une tâche (`encryption`) ; `nil` si
    # le mode « clé du cabinet » est choisi sans clé déposée.
    def self.task_settings(dossier : Dossier) : JSON::Any?
      mode = dossier.effective_encryption
      case mode
      when "cabinet"
        firm = dossier.firm!
        return if firm.backup_key?.nil?
        Tasks.any({"mode" => "cabinet", "public_key" => firm.backup_public_key.to_s,
                   "key_fingerprint" => firm.backup_key_fingerprint.to_s})
      when "exploitation" then Tasks.any({"mode" => "exploitation"})
      else                     Tasks.any({"mode" => "none"})
      end
    end

    # Description de la sauvegarde à lire (`backup_encryption`).
    def self.source(backup : Backup) : JSON::Any
      Tasks.any({"mode" => backup.encryption_mode.to_s, "recipient" => backup.recipient.to_s,
                 "key_fingerprint" => backup.key_fingerprint.to_s})
    end

    # Clé de sauvegarde remise pour une sauvegarde chiffrée : sortie de sa
    # capsule sur le poste de l'exploitant (`age -d`) ou dans le navigateur
    # de l'admin du cabinet. Acceptée si son destinataire est celui de la
    # sauvegarde (une mauvaise clé est refusée tout de suite, sans tâche).
    # Rend la clé normalisée ou `nil`.
    def self.accept_data_key(backup : Backup, value : String) : String?
      return unless backup.sealed
      identity = value.strip
      return unless BackupCrypto.valid_identity?(identity)
      recipient = BackupCrypto.recipient_of(identity) rescue nil
      return if recipient.nil? || backup.recipient.to_s.empty? || recipient != backup.recipient
      identity
    end

    # --- Clés de signature des serveurs (D-CHF-018) ---------------------------

    # Lignes `allowed_signers` du serveur qui a pris la sauvegarde : ses clés,
    # une clé révoquée ne valant que pour les sauvegardes prises avant.
    def self.signers(backup : Backup) : Array(String)
      server = Server.filter(name: backup.origin.to_s).first || return [] of String
      server.signing_keys.map do |key|
        BackupCrypto::Signature.allowed_signer(server.name.to_s, key.public_key.to_s, key.revoked_at)
      end
    end

    def self.add_signing_key(user : User, server : Server, text : String) : Outcome(SigningKey)
      return Outcome(SigningKey).failure("base", "admin.errors.forbidden") unless Access.fleet?(user)
      public_key = BackupCrypto::Signature.normalize(text) || return Outcome(SigningKey).failure("public_key", "admin.errors.signing_key.invalid")
      fingerprint = BackupCrypto::Signature.fingerprint(public_key)
      return Outcome(SigningKey).failure("public_key", "admin.errors.signing_key.taken") if SigningKey.filter(fingerprint: fingerprint).exists?
      key = SigningKey.create!(server: server, public_key: public_key, fingerprint: fingerprint)
      Audit.log(user, "signing_key.add", target: server, detail: {"fingerprint" => fingerprint})
      Outcome(SigningKey).new(key)
    end

    # Révocation (serveur compromis, clé changée) : les sauvegardes prises
    # après ne sont plus authentifiées par cette clé.
    def self.revoke_signing_key(user : User, key : SigningKey) : Bool
      return false unless Access.fleet?(user) && key.revoked_at.nil?
      key.revoked_at = Config.now
      key.save!
      Audit.log(user, "signing_key.revoke", target: key.server!, detail: {"fingerprint" => key.fingerprint.to_s})
      true
    end
  end
end

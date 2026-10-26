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
  #
  # *Affaiblissement soumis à validation* (D-ADM-025). Ordre de protection,
  # du plus protecteur au moins protecteur (D-CHF-001, D-CHF-014, D-CHF-015) :
  #
  # . `cabinet` : ni le serveur ni l'exploitant ne lisent les sauvegardes ;
  # . `exploitation` : le serveur n'a que des clés publiques, l'exploitant
  #   lit avec une clé privée gardée hors ligne ;
  # . `server` (retiré par D-CHF-015, rang gardé pour les données
  #   anciennes) : clé symétrique sur le serveur, qui lit tout ;
  # . `none` : en clair.
  #
  # Passer à un mode de rang inférieur — réglage du cabinet, ou chiffrement
  # *effectif* d'un dossier — est une demande (`Approval` `backup_weaken`),
  # validée par la structure selon son réglage (une ou deux personnes), dès
  # qu'elle a une équipe ; le service refuse lui-même le geste direct. Le
  # changement de clé du cabinet (rotation) et tout renforcement restent
  # immédiats.
  module BackupEncryption
    MODES = BackupCrypto::MODES

    # Rang de protection de chaque mode (plus grand : plus protecteur).
    STRENGTH = {"none" => 0, "server" => 1, "exploitation" => 2, "cabinet" => 3}

    alias Outcome = Fleet::Outcome

    def self.strength(mode : String) : Int32
      STRENGTH[mode]? || 0
    end

    # Passer de `from` à `to` affaiblit-il la protection ?
    def self.weaker?(from : String, to : String) : Bool
      strength(to) < strength(from)
    end

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
      # L'état présent relu en base : un objet ancien ne fait pas passer un
      # affaiblissement pour un renforcement.
      firm.reload
      previous = firm.backup_encryption.to_s
      return Outcome(Firm).new(firm) if previous == mode
      if refusal = change_refusal(user, firm, previous, mode)
        return Outcome(Firm).failure("mode", refusal)
      end
      # Affaiblissement : une demande, jamais le geste direct (D-ADM-025).
      return Outcome(Firm).failure("mode", "admin.errors.encryption.needs_approval") if weaken_gated?(firm, previous, mode)
      apply_firm_mode(user, firm, previous, mode)
    end

    private def self.apply_firm_mode(user : User, firm : Firm, previous : String, mode : String,
                                     approval : Approval? = nil) : Outcome(Firm)
      firm.backup_encryption = mode
      firm.save!
      detail = {"from" => previous, "to" => mode}
      approval.try { |decided| detail["approval"] = decided.reference.to_s }
      Audit.log(user, "backup_encryption.firm", target: firm, detail: detail)
      Outcome(Firm).new(firm)
    end

    # `mode` vide : le dossier reprend le réglage du cabinet.
    def self.set_dossier_mode(user : User, dossier : Dossier, mode : String) : Outcome(Dossier)
      firm = dossier.reload.firm!
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
      # Le chiffrement *effectif* compte : quitter une surcharge forte pour
      # un réglage du cabinet plus faible est aussi un affaiblissement.
      if weaken_gated?(firm, dossier.effective_encryption, following)
        return Outcome(Dossier).failure("mode", "admin.errors.encryption.needs_approval")
      end
      apply_dossier_mode(user, dossier, mode)
    end

    private def self.apply_dossier_mode(user : User, dossier : Dossier, mode : String,
                                        approval : Approval? = nil) : Outcome(Dossier)
      before = dossier.backup_encryption.to_s
      following = mode.presence || dossier.firm!.backup_encryption.to_s
      dossier.backup_encryption = mode
      dossier.save!
      detail = {"from" => before.presence || "firm", "to" => mode.presence || "firm", "effective" => following}
      approval.try { |decided| detail["approval"] = decided.reference.to_s }
      Audit.log(user, "backup_encryption.dossier", target: dossier, detail: detail)
      Outcome(Dossier).new(dossier)
    end

    # --- Affaiblissement soumis à validation (D-ADM-025) ----------------------

    # Le passage de `from` à `to` doit-il passer par une demande ? Un
    # affaiblissement, dans une structure qui a une équipe (avant, rien à
    # protéger : comme D-ADM-023).
    def self.weaken_gated?(firm : Firm, from : String, to : String) : Bool
      weaker?(from, to) && Administrators.firm_gated?(firm)
    end

    # Le réglage du cabinet vers `mode` se demande-t-il ?
    def self.firm_request?(firm : Firm, mode : String) : Bool
      MODES.includes?(mode) && weaken_gated?(firm, firm.reload.backup_encryption.to_s, mode)
    end

    # Le réglage du dossier vers `mode` (vide : celui du cabinet) se
    # demande-t-il ?
    def self.dossier_request?(dossier : Dossier, mode : String) : Bool
      return false unless mode.empty? || MODES.includes?(mode)
      firm = dossier.reload.firm!
      weaken_gated?(firm, dossier.effective_encryption, mode.presence || firm.backup_encryption.to_s)
    end

    # Demande d'affaiblissement du réglage du cabinet.
    def self.request_firm_weaken(user : User, firm : Firm, mode : String, reason : String = "",
                                 now : Time = Config.now) : Outcome(Approval)
      return Outcome(Approval).failure("base", "admin.errors.forbidden") unless can_manage?(user, firm)
      return Outcome(Approval).failure("mode", "admin.errors.invalid") unless firm_request?(firm, mode)
      previous = firm.backup_encryption.to_s
      if refusal = change_refusal(user, firm, previous, mode)
        return Outcome(Approval).failure("mode", refusal)
      end
      params = {"target" => "encryption:firm", "level" => "firm", "from" => previous, "to" => mode,
                "setting" => previous}
      Approvals.request_firm(user, firm, "backup_weaken", reason, params, now)
    end

    # Demande d'affaiblissement du chiffrement effectif d'un dossier
    # (surcharge, ou retour au réglage du cabinet plus faible).
    def self.request_dossier_weaken(user : User, dossier : Dossier, mode : String, reason : String = "",
                                    now : Time = Config.now) : Outcome(Approval)
      unless can_manage?(user, dossier.firm!) && Access.can?(user, :restore, dossier)
        return Outcome(Approval).failure("base", "admin.errors.forbidden")
      end
      return Outcome(Approval).failure("mode", "admin.errors.invalid") unless dossier_request?(dossier, mode)
      firm = dossier.firm!
      effective = dossier.effective_encryption
      following = mode.presence || firm.backup_encryption.to_s
      if refusal = change_refusal(user, firm, effective, following)
        return Outcome(Approval).failure("mode", refusal)
      end
      params = {"target" => "encryption:dossier:#{dossier.pk}", "level" => "dossier", "from" => effective,
                "to" => following, "setting" => dossier.backup_encryption.to_s, "value" => mode,
                "dossier_id" => dossier.pk.to_s, "dossier_slug" => dossier.slug.to_s}
      Approvals.request_firm(user, firm, "backup_weaken", reason, params, now)
    end

    # Le demandeur peut-il encore régler ce chiffrement, à la décision ?
    def self.requester_allowed?(requester : User, firm : Firm, approval : Approval) : Bool
      return false unless requester.active == true && can_manage?(requester, firm)
      approval.param("from") != "cabinet" || can_leave_cabinet?(requester, firm)
    end

    # Exécution d'une demande d'affaiblissement décidée (dans la transaction
    # de la décision) : l'état présent relu en base doit être celui de la
    # demande — réglage inchangé, chiffrement effectif inchangé, dossier
    # toujours dans la structure —, sinon la demande est close.
    def self.apply_weaken(approval : Approval, firm : Firm, requester : User) : Fleet::Errors
      changed = Fleet::Errors{"base" => ["admin.errors.approval.target_changed"]}
      from = approval.param("from")
      to = approval.param("to")
      return changed unless weaker?(from, to)
      if approval.param("level") == "firm"
        return changed unless firm.backup_encryption.to_s == from && approval.param("setting") == from
        apply_firm_mode(requester, firm, from, to, approval).errors
      else
        dossier = Dossier.filter(id: approval.param("dossier_id").to_i64?).first
        return changed if dossier.nil? || dossier.firm_id != firm.pk
        return changed unless dossier.backup_encryption.to_s == approval.param("setting") && dossier.effective_encryption == from
        value = approval.param("value")
        return changed unless (value.presence || firm.backup_encryption.to_s) == to
        apply_dossier_mode(requester, dossier, value, approval).errors
      end
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
    #
    # Immédiat (une clé compromise se remplace sans attendre, D-ADM-025),
    # mais annoncé (D-ADM-029, risque B-CRA-001 : un admin qui déposerait
    # sa propre clé) : les *autres* admins actifs du cabinet reçoivent par
    # courriel, dans leur langue, l'auteur, l'heure, l'ancienne et la
    # nouvelle empreinte, et la marche à suivre si le changement n'est pas
    # légitime. Adresses avisées au journal d'audit (`backup_key.deposit`) ;
    # un échec d'envoi ne défait pas le dépôt.
    def self.deposit_key(user : User, firm : Firm, pem : String) : Outcome(Firm)
      return Outcome(Firm).failure("base", "admin.errors.forbidden") unless can_deposit_key?(user, firm)
      key = begin
        BackupCrypto::PublicKey.new(pem.strip + "\n")
      rescue BackupCrypto::Error
        return Outcome(Firm).failure("public_key", "admin.errors.encryption.public_key")
      end
      previous = firm.reload.backup_key_fingerprint.to_s
      now = Config.now
      firm.backup_public_key = key.pem
      firm.backup_key_fingerprint = key.fingerprint
      firm.backup_key_set_at = now
      firm.save!
      detail = {"fingerprint" => key.fingerprint, "previous" => previous, "bits" => key.bits.to_s}
      announce_key(user, firm, previous, key.fingerprint, now, detail) unless previous == key.fingerprint
      Audit.log(user, "backup_key.deposit", target: firm, detail: detail)
      Outcome(Firm).new(firm)
    end

    # Annonce de la nouvelle empreinte aux autres admins actifs du cabinet
    # (jamais à l'auteur) ; le contact donné est l'adresse de support de
    # l'instance (D-ADM-031), jamais celle d'un super-admin.
    private def self.announce_key(user : User, firm : Firm, previous : String, current : String, now : Time,
                                  detail : Hash(String, String)) : Nil
      others = User.filter(firm_id: firm.pk, role: Config::FIRM_ADMIN, active: true).exclude(id: user.pk).order("email").to_a
      change = Mailer::KeyChange.new(firm, user, previous, current, now)
      notified, failed = Mailer.backup_key(change, others)
      detail["notified"] = notified.join(',')
      detail["notice_failed"] = failed.join(',') unless failed.empty?
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

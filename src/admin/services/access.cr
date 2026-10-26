# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Droits par rôle (ADR-008 D2), en un seul endroit : handlers et services
  # passent tous par ici.
  #
  # [cols="2,1,1,1"]
  # |===
  # |Action |Super-admin |Admin de cabinet |Gestionnaire
  # |voir un dossier, ses tâches et sauvegardes |tous |son cabinet |confiés
  # |modules et extensions, sauvegarde, restauration test |tous |son cabinet |confiés
  # |demander un recours d'accès |tous |son cabinet |confiés
  # |relire les administrateurs d'un dossier |tous |son cabinet |confiés
  # |ajouter, retirer, remplacer un administrateur d'un dossier |tous |son cabinet |—
  # |créer, suspendre, réactiver, archiver, restaurer |tous |son cabinet |—
  # |demander une suppression définitive |tous |son cabinet |—
  # |valider une demande d'un autre (validation à deux) |tous |son cabinet |—
  # |confirmer seul sa demande (structure « une personne ») |tous |son cabinet |—
  # |régler la validation à deux |parc sans cabinet |sa structure |—
  # |demander ou valider une action de structure (D-ADM-023) |toutes |la sienne |—
  # |valider un affaiblissement du chiffrement (D-ADM-025) |dernier recours, jamais hors clé du cabinet |la sienne |—
  # |utilisateurs, affectations, donneurs d'ordre |tous |son cabinet |—
  # |administrateurs d'une structure |toutes |la sienne |—
  # |demander le transfert d'un dossier vers une autre structure (D-ADM-027) |oui |— |—
  # |donner l'accord de sa structure à un transfert |parc sans cabinet |la sienne |—
  # |cabinets, serveurs |oui |— |—
  # |désactiver, réactiver une structure, changer sa nature (D-ADM-026) |oui, soumis à validation |— |—
  # |journal d'audit |tout |son cabinet |—
  # |===
  module Access
    class Denied < Exception
    end

    # Actions sur un dossier ouvertes au gestionnaire de dossiers.
    MANAGER_ACTIONS = %i[view modules backup test_restore request_admin_invite refresh_administrators]

    # Actions sur un dossier réservées aux admins (cabinet ou parc).
    ADMIN_ACTIONS = %i[suspend resume archive restore_archive restore request_delete approve administrators]

    def self.dossiers(user : User) : Marten::DB::Query::Set(Dossier)
      case user.role
      when Config::SUPER_ADMIN then Dossier.all
      when Config::FIRM_ADMIN  then Dossier.filter(firm_id: user.firm_id)
      else
        Dossier.filter(id__in: Assignment.filter(user_id: user.pk).compact_map { |row| PartiduoAdmin.id?(row.dossier_id) })
      end
    end

    def self.in_scope?(user : User, dossier : Dossier) : Bool
      case user.role
      when Config::SUPER_ADMIN then true
      when Config::FIRM_ADMIN  then !user.firm_id.nil? && dossier.firm_id == user.firm_id
      else                          Assignment.filter(user_id: user.pk, dossier_id: dossier.pk).exists?
      end
    end

    def self.can?(user : User, action : Symbol, dossier : Dossier) : Bool
      return false unless in_scope?(user, dossier)
      return true if MANAGER_ACTIONS.includes?(action)
      return !user.file_manager? if ADMIN_ACTIONS.includes?(action)
      false
    end

    def self.authorize!(user : User, action : Symbol, dossier : Dossier) : Nil
      raise Denied.new("#{action} #{dossier.slug}") unless can?(user, action, dossier)
    end

    # Créer un dossier dans ce cabinet.
    def self.can_create_dossier?(user : User, firm_id) : Bool
      return true if user.super_admin?
      user.firm_admin? && !firm_id.nil? && user.firm_id == firm_id
    end

    # Actions sur le parc lui-même.
    def self.fleet?(user : User) : Bool
      user.super_admin?
    end

    def self.firms(user : User) : Marten::DB::Query::Set(Firm)
      user.super_admin? ? Firm.all : Firm.filter(id: user.firm_id)
    end

    def self.users(user : User) : Marten::DB::Query::Set(User)
      case user.role
      when Config::SUPER_ADMIN then User.all
      when Config::FIRM_ADMIN  then User.filter(firm_id: user.firm_id)
      else                          User.filter(id: user.pk)
      end
    end

    # Rôles qu'un utilisateur peut attribuer : le super-admin tous, l'admin de
    # cabinet ceux de son cabinet.
    def self.assignable_roles(user : User) : Array(String)
      case user.role
      when Config::SUPER_ADMIN then Config::ROLES
      when Config::FIRM_ADMIN  then [Config::FIRM_ADMIN, Config::FILE_MANAGER]
      else                          [] of String
      end
    end

    def self.can_manage_user?(user : User, target : User) : Bool
      return false if user.file_manager?
      return true if user.super_admin?
      !target.super_admin? && target.firm_id == user.firm_id
    end

    def self.payers(user : User) : Marten::DB::Query::Set(Payer)
      case user.role
      when Config::SUPER_ADMIN then Payer.all
      when Config::FIRM_ADMIN  then Payer.filter(firm_id: user.firm_id)
      else                          Payer.filter(id__in: dossiers(user).compact_map { |dossier| PartiduoAdmin.id?(dossier.payer_id) })
      end
    end

    def self.can_manage_payer?(user : User, firm_id) : Bool
      return true if user.super_admin?
      user.firm_admin? && !firm_id.nil? && firm_id == user.firm_id
    end

    def self.can_view_audit?(user : User) : Bool
      !user.file_manager?
    end

    def self.audit(user : User) : Marten::DB::Query::Set(AuditEntry)
      user.super_admin? ? AuditEntry.all : AuditEntry.filter(firm_id: user.firm_id)
    end

    # Valider la demande de double validation : une *autre* personne,
    # admin du cabinet du dossier ou super-admin (ADR-008 D3) ; pour une
    # demande propre à une structure (D-ADM-023), un autre admin actif de
    # la structure ou un super-admin — un super-admin seulement si elle
    # touche un compte de super-admin.
    def self.can_approve?(user : User, approval : Approval) : Bool
      return false if approval.requested_by_id == user.pk
      # Transfert (D-ADM-027) : une personne habilitée de l'une des deux
      # structures (son accord se donne sur la page du transfert).
      return !Transfers.side_of(user, approval).nil? if approval.transfer?
      if dossier = approval.dossier
        return can?(user, :approve, dossier)
      end
      firm = approval.firm
      return false if firm.nil?
      # Affaiblissement du chiffrement (D-ADM-025) : la structure ; le
      # super-admin en dernier recours, jamais pour quitter la clé du
      # cabinet (D-CHF-008).
      if Approval::MEMBER_KINDS.includes?(approval.kind)
        return true if Approvals.member?(user, firm)
        return user.super_admin? && user.active == true && approval.param("from") != "cabinet"
      end
      Administrators.can_request_firm?(user, firm, approval.super_scope?)
    end

    def self.tasks(user : User) : Marten::DB::Query::Set(Task)
      return Task.all if user.super_admin?
      Task.filter(dossier_id__in: dossiers(user).map(&.pk!.as(Int64)))
    end
  end
end

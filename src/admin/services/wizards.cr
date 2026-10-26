# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAdmin
  # Assistants des parcours courants (D-ADM-018) : déclarer un cabinet,
  # créer un entrepreneur, créer un foyer ; ajouter un serveur, restaurer,
  # déplacer, archiver un dossier, inviter un utilisateur (D-ADM-022,
  # `wizard_operations.cr`). Étapes numérotées, saisies gardées côté
  # serveur (`WizardDraft`), contrôles et création par les services des
  # formulaires (`Directory`, `Fleet`) : aucune règle n'est écrite ici. Rien
  # n'est créé avant la validation finale.
  module Wizards
    alias Errors = Fleet::Errors

    KINDS = %w[firm company household server restore move archive transfer user]

    # Étapes de chaque parcours. Serveur : la validation est au
    # récapitulatif (le jeton de l'exécutant n'existe qu'une fois le serveur
    # déclaré), le raccordement, la vérification et les capacités suivent.
    # Restauration : l'étape de la clé n'existe que pour une sauvegarde
    # chiffrée (`steps(draft)`).
    STEPS = {
      "firm"      => %w[identity admins options summary],
      "company"   => %w[identity activity modules attachment admins summary],
      "household" => %w[identity modules attachment admins summary],
      "server"    => %w[identity summary connect check capabilities],
      "restore"   => %w[dossier backup target check summary key],
      "move"      => %w[dossier server consequences summary],
      "archive"   => %w[dossier consequences summary],
      "transfer"  => %w[dossier firm payer consequences summary],
      "user"      => %w[identity role dossiers language summary],
    }

    # Profils d'un entrepreneur (étape « activité ») : modules proposés au
    # départ, modifiables à l'étape suivante.
    PROFILES = {
      "micro"   => %w[micro invoicing],
      "liberal" => %w[liberal invoicing],
      "company" => %w[accounting invoicing],
    }

    # Natures de structure proposées (le parc sans cabinet se crée par le
    # formulaire de la liste).
    FIRM_KINDS = %w[cabinet independent]

    # Chiffrement des sauvegardes proposé à la déclaration : la clé du
    # cabinet se dépose ensuite par l'admin du cabinet (D-CHF-002).
    FIRM_ENCRYPTIONS = %w[exploitation none]

    # Champs de chaque étape : saisies gardées et erreurs des services
    # rangées sous leur étape (le reste va au récapitulatif).
    SCALARS = {
      "firm"    => {"identity" => %w[kind name siren email], "options" => %w[encryption]},
      "dossier" => {
        "identity"   => %w[label slug regime locale siren vat_number],
        "activity"   => %w[profile],
        "attachment" => %w[firm_id payer_mode payer_id payer_street payer_postcode payer_city payer_country
          payer_contact_email server_id backup_schedule backup_retention_days],
        "admins" => %w[admin_email],
      },
      "server"   => {"identity" => %w[name hostname domain]},
      "restore"  => {"dossier" => %w[dossier_id], "backup" => %w[backup_id], "target" => %w[target new_slug]},
      "move"     => {"dossier" => %w[dossier_id], "server" => %w[server_id], "consequences" => %w[reason]},
      "archive"  => {"dossier" => %w[dossier_id], "consequences" => %w[reason]},
      "transfer" => {"dossier" => %w[dossier_id], "firm" => %w[firm_id], "payer" => %w[payer_id],
                     "consequences" => %w[reason]},
      "user" => {"identity" => %w[email first_name last_name], "role" => %w[role firm_id], "language" => %w[locale]},
    }

    LISTS = {
      "firm"    => {"admins" => %w[admin_email admin_first_name admin_last_name admin_locale]},
      "dossier" => {"modules" => %w[modules extensions], "admins" => %w[extra_admins]},
      "user"    => {"dossiers" => %w[dossier_ids]},
    }

    def self.family(kind : String) : String
      case kind
      when "firm"                 then "firm"
      when "company", "household" then "dossier"
      else                             kind
      end
    end

    def self.steps(kind : String) : Array(String)
      STEPS[kind]
    end

    # Étapes de ce brouillon : sans celle de la clé pour la restauration
    # d'une sauvegarde en clair.
    def self.steps(draft : WizardDraft) : Array(String)
      kind = draft.kind!.to_s
      return STEPS[kind] unless kind == "restore"
      sealed = restore_dossier_of(draft).try { |dossier| restore_backup(draft, dossier) }.try(&.sealed) || false
      sealed ? STEPS[kind] : STEPS[kind] - %w[key]
    end

    # Assistant ouvert à l'utilisateur : déclarer un cabinet, le
    # super-admin ; créer un dossier, qui peut en créer dans une structure.
    def self.allowed?(user : User, kind : String) : Bool
      case kind
      when "firm", "server"             then Access.fleet?(user)
      when "company", "household"       then !user.file_manager? && Access.firms(user).filter(active: true).exists?
      when "restore", "archive", "user" then !user.file_manager?
      when "move"                       then user.super_admin?
      when "transfer"                   then Transfers.can_request?(user)
      else                                   false
      end
    end

    # Brouillon de l'utilisateur pour ce parcours (non enregistré tant
    # qu'aucune saisie n'est gardée).
    def self.draft(user : User, kind : String) : WizardDraft
      WizardDraft.filter(user_id: user.pk, kind: kind).first || WizardDraft.new(user: user, kind: kind, data: "{}")
    end

    def self.drafts(user : User) : Array(WizardDraft)
      WizardDraft.filter(user_id: user.pk).order("-updated_at").to_a
    end

    # Garde les saisies d'une étape (texte, listes) dans le brouillon.
    def self.store(draft : WizardDraft, values : Hash(String, String | Array(String))) : Nil
      data = draft.values
      values.each { |key, value| data[key] = Tasks.any(value) }
      draft.data = data.to_json
      draft.save!
    end

    def self.discard(draft : WizardDraft) : Nil
      draft.delete unless draft.new_record?
    end

    # Étape où se range une erreur d'un service.
    def self.step_of(kind : String, field : String) : String
      group = family(kind)
      if special = operation_step_of(kind, field)
        return special
      end
      return "modules" if group == "dossier" && (field.starts_with?("family.") || field == "kind")
      return "admins" if field.starts_with?("admins") || field == "extra_admins"
      return "attachment" if group == "dossier" && field.starts_with?("payer")
      SCALARS[group].each { |step, names| return step if names.includes?(field) }
      LISTS[group]?.try(&.each { |step, names| return step if names.includes?(field) })
      "summary"
    end

    # Erreurs de la saisie entière (services des formulaires), sans rien
    # créer.
    def self.errors(user : User, draft : WizardDraft) : Errors
      case draft.kind!
      when "firm"                 then firm_errors(user, draft)
      when "company", "household" then dossier_errors(user, draft)
      else                             operation_errors(user, draft)
      end
    end

    # Erreurs des étapes jusqu'à `step` compris.
    def self.errors_until(user : User, draft : WizardDraft, step : String) : Errors
      order = steps(draft)
      limit = order.index(step) || 0
      errors(user, draft).select { |field, _| (order.index(step_of(draft.kind!, field)) || order.size) <= limit }
    end

    # --- Cabinet ----------------------------------------------------------------

    record FirmAdminRow, email : String, first_name : String, last_name : String, locale : String

    def self.firm_admin_rows(draft : WizardDraft) : Array(FirmAdminRow)
      emails = draft.list("admin_email")
      firsts = draft.list("admin_first_name")
      lasts = draft.list("admin_last_name")
      locales = draft.list("admin_locale")
      emails.each_with_index.compact_map do |email, index|
        next if email.strip.empty?
        FirmAdminRow.new(email.strip.downcase, firsts[index]? || "", lasts[index]? || "", locales[index]?.presence || "fr")
      end.to_a
    end

    private def self.firm_errors(user : User, draft : WizardDraft) : Errors
      kind = draft.text("kind").presence || "cabinet"
      errors = Directory.firm_errors(user, draft.text("name"), draft.text("siren"), draft.text("email"), kind)
      (errors["kind"] ||= [] of String) << "admin.errors.invalid" unless FIRM_KINDS.includes?(kind)
      rows = firm_admin_rows(draft)
      add(errors, "admins", "admin.errors.administrators.at_least_one") if rows.empty?
      add(errors, "admins", "admin.errors.firm.independent_single") if kind == "independent" && rows.size > 1
      add(errors, "admins", "admin.errors.administrators.too_many") if rows.size > Administrators::LIMIT
      seen = Set(String).new
      rows.each_with_index do |row, index|
        add(errors, "admins.#{index}", "admin.errors.administrators.duplicate") unless seen.add?(row.email)
        Directory.invite_errors(user, firm_admin_input(row, nil)).each do |field, keys|
          keys.each { |key| add(errors, "admins.#{index}", key) } unless field == "firm_id"
        end
      end
      add(errors, "encryption", "admin.errors.invalid") unless FIRM_ENCRYPTIONS.includes?(draft.text("encryption").presence || "exploitation")
      errors
    end

    private def self.firm_admin_input(row : FirmAdminRow, firm_id : Int64?) : Directory::UserInput
      Directory::UserInput.new(email: row.email, first_name: row.first_name, last_name: row.last_name,
        role: Config::FIRM_ADMIN, firm_id: firm_id, locale: row.locale)
    end

    # Création : la structure, ses admins invités, le chiffrement de ses
    # sauvegardes. Codes de création des comptes connect rendus pour être
    # montrés une fois (ADR-012 D6).
    def self.finish_firm(user : User, draft : WizardDraft) : {Errors, Firm?, Array(String)}
      errors = firm_errors(user, draft)
      return {errors, nil, [] of String} unless errors.empty?
      codes = [] of String
      firm : Firm? = nil
      Marten::DB::Connection.default.transaction do
        created = Directory.create_firm(user, draft.text("name"), draft.text("siren"), draft.text("email"),
          draft.text("kind").presence || "cabinet")
        raise Marten::DB::Errors::Rollback.new unless created.ok?
        record = created.value!
        # Chiffrement réglé avant l'arrivée de l'équipe : la création est la
        # décision (un affaiblissement se demanderait ensuite, D-ADM-025).
        mode = draft.text("encryption").presence || "exploitation"
        unless record.backup_encryption == mode || BackupEncryption.set_firm_mode(user, record, mode).ok?
          raise Marten::DB::Errors::Rollback.new
        end
        firm_admin_rows(draft).each do |row|
          invited = Directory.invite_user(user, firm_admin_input(row, PartiduoAdmin.id?(record.pk)))
          raise Marten::DB::Errors::Rollback.new unless invited.ok?
          invited.signup_code.try { |code| codes << "#{row.email} : #{code}" }
        end
        Audit.log(user, "wizard.finish", target: record, detail: {"wizard" => "firm"})
        firm = record
      end
      return {Errors{"base" => ["admin.errors.wizards.failed"]}, nil, [] of String} if firm.nil?
      discard(draft)
      {Errors.new, firm, codes}
    end

    # --- Entrepreneur et foyer ----------------------------------------------------

    def self.dossier_kind(draft : WizardDraft) : String
      draft.kind! == "household" ? "household" : "company"
    end

    # Modules au départ : ceux du profil choisi, ou la Comptabilité d'un
    # foyer.
    def self.preset(draft : WizardDraft) : Array(String)
      return %w[accounting] if draft.kind! == "household"
      PROFILES[draft.text("profile")]? || PROFILES["company"]
    end

    def self.new_payer?(draft : WizardDraft) : Bool
      draft.text("payer_mode") == "new"
    end

    def self.firm_id(user : User, draft : WizardDraft) : Int64?
      user.firm_admin? ? PartiduoAdmin.id?(user.firm_id) : draft.text("firm_id").to_i64?
    end

    def self.dossier_input(user : User, draft : WizardDraft, payer_id : Int64? = nil) : Fleet::DossierInput
      modules, extensions = PieceForm.split(draft.list("modules"), draft.list("extensions"))
      Fleet::DossierInput.new(
        slug: draft.text("slug"), label: draft.text("label"), regime: draft.text("regime").presence || "fr",
        locale: draft.text("locale").presence || "fr", siren: draft.text("siren").gsub(/\s/, ""),
        vat_number: draft.text("vat_number"), modules: modules, extensions: extensions,
        admin_email: draft.text("admin_email"), server_id: draft.text("server_id").to_i64?,
        firm_id: firm_id(user, draft), payer_id: payer_id || (new_payer?(draft) ? nil : draft.text("payer_id").to_i64?),
        package: Config.dossier_package, backup_schedule: draft.text("backup_schedule").presence || "daily",
        backup_retention_days: draft.text("backup_retention_days").to_i? || 30, kind: dossier_kind(draft),
        extra_admins: draft.list("extra_admins").map(&.strip).reject(&.empty?))
    end

    # Donneur d'ordre nouveau : l'entrepreneur lui-même (société), ou le
    # foyer (autre payeur), à son adresse.
    def self.payer_input(user : User, draft : WizardDraft) : Directory::PayerInput
      Directory::PayerInput.new(kind: draft.kind! == "household" ? "other" : "company", firm_id: firm_id(user, draft),
        name: draft.text("label"), siren: draft.kind! == "household" ? "" : draft.text("siren").gsub(/\s/, ""),
        vat_number: draft.kind! == "household" ? "" : draft.text("vat_number"), street: draft.text("payer_street"),
        postcode: draft.text("payer_postcode"), city: draft.text("payer_city"),
        country: draft.text("payer_country").upcase.presence || "FR", contact_email: draft.text("payer_contact_email"))
    end

    private def self.dossier_errors(user : User, draft : WizardDraft) : Errors
      errors = Fleet.dossier_errors(user, dossier_input(user, draft))
      add(errors, "profile", "admin.errors.invalid") if draft.kind! == "company" && !PROFILES.has_key?(draft.text("profile"))
      return errors unless new_payer?(draft)
      # Donneur d'ordre à créer : ses propres contrôles remplacent ceux du
      # donneur d'ordre choisi.
      errors.delete("payer_id")
      input = payer_input(user, draft)
      Directory.payer_errors(user, input, nil, input.firm_id).each do |field, keys|
        next if field == "firm_id" || field == "base"
        keys.each { |key| add(errors, "payer_#{field}", key) }
      end
      errors
    end

    # Création : le donneur d'ordre nouveau puis le dossier, dans une même
    # transaction ; le dossier invite ses administrateurs (D-ADM-017).
    def self.finish_dossier(user : User, draft : WizardDraft) : {Errors, Dossier?}
      errors = dossier_errors(user, draft)
      return {errors, nil} unless errors.empty?
      failure = Errors.new
      dossier : Dossier? = nil
      Marten::DB::Connection.default.transaction do
        payer_id = nil
        if new_payer?(draft)
          payer = Directory.save_payer(user, payer_input(user, draft))
          failure = payer.errors
          raise Marten::DB::Errors::Rollback.new unless payer.ok?
          payer_id = PartiduoAdmin.id?(payer.value!.pk)
        end
        created = Fleet.create_dossier(user, dossier_input(user, draft, payer_id))
        failure = created.errors
        raise Marten::DB::Errors::Rollback.new unless created.ok?
        Audit.log(user, "wizard.finish", target: created.value!, detail: {"wizard" => draft.kind!.to_s})
        dossier = created.value!
      end
      return {failure.empty? ? Errors{"base" => ["admin.errors.wizards.failed"]} : failure, nil} if dossier.nil?
      discard(draft)
      {Errors.new, dossier}
    end

    private def self.add(errors : Errors, field : String, key : String) : Nil
      list = (errors[field] ||= [] of String)
      list << key unless list.includes?(key)
    end
  end
end

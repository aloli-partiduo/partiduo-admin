# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Assistants ouverts à l'utilisateur (D-ADM-018, D-ADM-022), avec le
  # brouillon à reprendre.
  class WizardsHandler < ScreenHandler
    def get
      drafts = Wizards.drafts(user).to_h { |draft| {draft.kind!.to_s, draft} }
      items = Wizards::KINDS.select { |kind| Wizards.allowed?(user, kind) }.map do |kind|
        draft = drafts[kind]?
        steps = draft ? Wizards.steps(draft) : Wizards.steps(kind)
        {"kind" => kind, "title_key" => "admin.wizards.#{kind}.title", "help_key" => "admin.wizards.#{kind}.help",
         "draft" => !draft.nil?, "step" => Math.min(draft.try(&.current) || 1, steps.size).to_s, "steps" => steps.size.to_s}
      end
      page("admin/wizards.html", {"items" => items})
    end
  end

  # Un assistant : une étape par page, numérotée, Précédent et Suivant,
  # récapitulatif avant la validation. Chaque envoi garde les saisies de
  # l'étape dans le brouillon ; Suivant ne passe que sans erreur à l'étape
  # (contrôles des services) ; la validation finale appelle les services
  # des formulaires. Sans JavaScript : formulaire classique et redirection ;
  # avec HTMX, l'étape remplace le contenu et le focus se place sur son
  # titre (`wizard.js`).
  class WizardHandler < ScreenHandler
    # Gestes d'une étape sans quitter l'assistant (serveur déclaré) :
    # régénérer le jeton, vérifier la connexion, demander un premier
    # contrôle, déclarer la clé de signature.
    ACTIONS = {"rotate" => "connect", "refresh" => "check", "probe" => "capabilities", "signing" => "capabilities"}

    def get
      kind = kind!
      draft = Wizards.draft(user, kind)
      query("dossier").to_i64?.try { |id| Wizards.preselect(user, draft, id) }
      requested = query("step").to_i?
      number = requested && requested >= 1 && requested <= draft.furthest ? requested : draft.current
      number = Math.max(number, Wizards.locked(draft) + 1)
      render_step(draft, number.clamp(1, Wizards.steps(draft).size))
    end

    def post
      kind = kind!
      draft = Wizards.draft(user, kind)
      steps = Wizards.steps(draft)
      number = (field("step").to_i? || draft.current).clamp(1, Math.min(draft.furthest, steps.size))
      number = Math.min(Math.max(number, Wizards.locked(draft) + 1), steps.size)
      step = steps[number - 1]
      nav = field("nav")
      return cancel(draft) if nav == "cancel"
      # Clé déposée par le script du navigateur sans le bouton : validation.
      nav = "finish" if nav.empty? && step == "key" && !field("data_key").empty?
      before = draft.text("dossier_id")
      keep(draft, step)
      Wizards.dossier_changed(draft, before) if step == "dossier"
      case nav
      when "previous"
        move(draft, Math.max(Wizards.locked(draft) + 1, number - 1))
      when "more"
        Wizards.store(draft, {"slots_#{step}" => (draft.text("slots_#{step}").to_i? || 1).succ.to_s})
        move(draft, number)
      when "finish"
        finish(draft, number)
      when .in?(ACTIONS.keys)
        act(draft, step, number, nav)
      else
        advance(draft, step, number)
      end
    end

    private def kind! : String
      kind = params["kind"].to_s
      raise Access::Denied.new("wizard") unless Wizards::KINDS.includes?(kind) && Wizards.allowed?(user, kind)
      kind
    end

    private def cancel(draft : WizardDraft)
      Wizards.discard(draft)
      flash["info"] = I18n.t("admin.wizards.cancelled")
      go("/wizards")
    end

    private def move(draft : WizardDraft, number : Int32)
      draft.step = number
      draft.save!
      go("/wizards/#{draft.kind!}")
    end

    # Saisies de l'étape envoyée, gardées même pour revenir en arrière.
    private def keep(draft : WizardDraft, step : String) : Nil
      group = Wizards.family(draft.kind!)
      values = {} of String => String | Array(String)
      Wizards::SCALARS[group][step]?.try(&.each { |name| values[name] = field(name) })
      Wizards::LISTS[group]?.try(&.[step]?).try(&.each { |name| values[name] = raw_list(name) })
      if step == "modules"
        modules, extensions = PieceForm.split(fields("modules"), fields("extensions"))
        values["modules"] = modules
        values["extensions"] = extensions
      end
      Wizards.store(draft, values) unless values.empty?
    end

    # Valeurs d'un champ répété, vides comprises : les lignes d'un tableau
    # restent alignées (adresse, prénom, nom, langue).
    private def raw_list(name : String) : Array(String)
      request.data.fetch_all(name, nil).try(&.map(&.to_s.strip)) || [] of String
    end

    private def advance(draft : WizardDraft, step : String, number : Int32)
      apply_profile(draft) if step == "activity"
      errors = Wizards.errors_until(user, draft, step).select { |field, _| Wizards.step_of(draft.kind!, field) == step }
      return render_step(draft, number, errors, 422) unless errors.empty?
      following = Math.min(number + 1, Wizards.steps(draft).size)
      draft.reached = Math.max(draft.furthest, following)
      move(draft, following)
    end

    # Profil d'un entrepreneur changé : ses modules au départ remplacent le
    # choix précédent.
    private def apply_profile(draft : WizardDraft) : Nil
      return if draft.text("profile") == draft.text("profile_applied")
      Wizards.store(draft, {"modules" => Wizards.preset(draft), "extensions" => [] of String,
                            "profile_applied" => draft.text("profile")})
    end

    private def finish(draft : WizardDraft, number : Int32)
      step = Wizards.steps(draft)[number - 1]
      return finish_operation(draft, step, number) if operation?(draft)
      return render_step(draft, number) unless step == "summary"
      if draft.kind! == "firm"
        errors, firm, codes = Wizards.finish_firm(user, draft)
        if firm
          flash["success"] = I18n.t("admin.wizards.firm.done", name: firm.name.to_s)
          flash["info"] = I18n.t("admin.users.signup_code", code: codes.join(" ; ")) unless codes.empty?
          return go("/firms/#{firm.pk}/admins")
        end
      else
        errors, dossier = Wizards.finish_dossier(user, draft)
        if dossier
          flash["success"] = I18n.t("admin.dossiers.created", slug: dossier.slug.to_s)
          return go("/dossiers/#{dossier.pk}")
        end
      end
      render_step(draft, number, errors, 422)
    end

    # --- Opérations (D-ADM-022) -----------------------------------------------------

    private def operation?(draft : WizardDraft) : Bool
      !%w[firm company household].includes?(draft.kind!)
    end

    private def confirmed? : Bool
      fields("confirm").includes?("yes")
    end

    # Validation d'un parcours d'opération, par le service du formulaire ;
    # seulement à son étape de validation.
    private def finish_operation(draft : WizardDraft, step : String, number : Int32)
      return render_step(draft, number) unless finishing?(draft, step)
      case draft.kind!
      when "server"  then finish_server(draft, step, number)
      when "restore" then finish_restore(draft, number)
      when "move"    then finish_move(draft, number)
      when "archive" then finish_archive(draft, number)
      else                finish_user(draft, number)
      end
    end

    # Serveur : déclaré au récapitulatif (jeton montré dans la réponse),
    # assistant terminé à l'étape des capacités.
    private def finish_server(draft : WizardDraft, step : String, number : Int32)
      if step == "summary"
        errors, server, token = Wizards.finish_server(user, draft)
        return render_step(draft, 3, token: token) if server
        return render_step(draft, number, errors, 422)
      end
      name = Wizards.created_server(draft).try(&.name.to_s) || ""
      Wizards.discard(draft)
      flash["success"] = I18n.t("admin.wizards.server.completed", name: name)
      go("/servers")
    end

    private def finish_restore(draft : WizardDraft, number : Int32)
      errors, task = Wizards.finish_restore(user, draft, field("data_key"), confirmed?)
      return render_step(draft, number, errors, 422) if task.nil?
      flash["success"] = I18n.t("admin.tasks.enqueued")
      go("/tasks/#{task.pk}")
    end

    private def finish_move(draft : WizardDraft, number : Int32)
      errors, dossier = Wizards.finish_move(user, draft, confirmed?)
      return render_step(draft, number, errors, 422) if dossier.nil?
      failed = dossier.dns_state == "error"
      flash[failed ? "warning" : "success"] = I18n.t(failed ? "admin.move.done_dns_error" : "admin.move.done")
      flash["info"] = I18n.t("admin.wizards.move.next")
      go("/wizards/restore")
    end

    private def finish_archive(draft : WizardDraft, number : Int32)
      errors, task = Wizards.finish_archive(user, draft, confirmed?)
      return render_step(draft, number, errors, 422) if task.nil?
      flash["success"] = I18n.t("admin.tasks.enqueued")
      go("/dossiers/#{task.dossier_id}")
    end

    private def finish_user(draft : WizardDraft, number : Int32)
      errors, invited, code = Wizards.finish_user(user, draft)
      return render_step(draft, number, errors, 422) if invited.nil?
      flash["success"] = I18n.t("admin.users.invited", email: invited.email.to_s)
      flash["info"] = I18n.t("admin.users.signup_code", code: code) if code
      go("/users")
    end

    # Geste d'une étape d'un serveur déclaré.
    private def act(draft : WizardDraft, step : String, number : Int32, nav : String)
      server = Wizards.created_server(draft)
      return render_step(draft, number) unless server && draft.kind! == "server" && ACTIONS[nav] == step
      case nav
      when "rotate"
        token = Directory.rotate_token(user, server) || raise Access::Denied.new("server")
        render_step(draft, number, token: token)
      when "probe"
        Supervision.enqueue(server)
        flash["info"] = I18n.t("admin.wizards.server.probe_enqueued")
        move(draft, number)
      when "signing"
        outcome = BackupEncryption.add_signing_key(user, server, field("public_key"))
        return render_step(draft, number, outcome.errors, 422) unless outcome.ok?
        flash["success"] = I18n.t("admin.servers.signing_key_added", fingerprint: outcome.value!.fingerprint.to_s)
        move(draft, number)
      else
        move(draft, number)
      end
    end

    # --- Rendu -------------------------------------------------------------------

    private def finish_key(draft : WizardDraft, step : String) : String
      kind = draft.kind!.to_s
      return "admin.wizards.finish" unless operation?(draft)
      return "admin.wizards.server.done_label" if kind == "server" && step != "summary"
      "admin.wizards.#{kind}.finish"
    end

    # Étape où se trouve le bouton de validation : la dernière, et le
    # récapitulatif d'un serveur (qui le déclare).
    private def finishing?(draft : WizardDraft, step : String) : Bool
      step == Wizards.steps(draft).last || (draft.kind! == "server" && step == "summary")
    end

    # Étape servie : champs du parcours de création (`WizardForm`) ou
    # d'opération (`WizardOperationForm` : blocs d'information, gestes de
    # l'étape, clé de la sauvegarde, jeton montré une fois, attente de
    # l'exécutant rafraîchie par HTMX).
    private def render_step(draft : WizardDraft, number : Int32, errors : Fleet::Errors = Fleet::Errors.new,
                            status : Int32 = 200, token : String? = nil)
      steps = Wizards.steps(draft)
      step = steps[number - 1]
      t = translate(errors)
      creation = operation?(draft) ? nil : WizardForm.new(self, draft, t)
      operation = WizardOperationForm.new(self, draft, t) unless creation
      fields = creation.try(&.fields(step)) || operation.try(&.fields(step)) || [] of FormField
      modules = modules_values(draft, t) if creation && step == "modules"
      page("admin/wizard.html", {
        "kind"         => draft.kind!,
        "title_key"    => "admin.wizards.#{draft.kind!}.title",
        "step"         => step,
        "number"       => number.to_s,
        "total"        => steps.size.to_s,
        "step_key"     => "admin.wizards.steps.#{step}",
        "step_help"    => "admin.wizards.#{draft.kind!}.help_#{step}",
        "first"        => number - 1 <= Math.max(Wizards.locked(draft), 0),
        "finishing"    => finishing?(draft, step),
        "finish_key"   => finish_key(draft, step),
        "track"        => track(draft, number),
        "fields"       => fields,
        "base_errors"  => step_errors(draft, step, t, fields),
        "boost"        => !%w[modules key].includes?(step),
        "admin_rows"   => admin_rows(creation, draft, step),
        "extra_admins" => extra_admins(creation, draft, step),
        "admin_errors" => errs(t, "admins") + errs(t, "extra_admins"),
        "summary"      => summary(creation, operation, step),
        "families"     => modules.try(&.[:families]),
        "other"        => modules.try(&.[:other]),
        "pieces"       => modules.try(&.[:pieces]),
        "piece_errors" => modules.try(&.[:piece_errors]),
        "sections"     => operation.try(&.sections(step)),
        "actions"      => operation.try(&.actions(step)),
        "unlock"       => operation.try(&.unlock(step)),
        "token"        => token,
        "poll"         => poll(draft, step, number),
      }, status: status)
    end

    # Erreurs hors des champs de l'étape : au récapitulatif, à la validation
    # et dans les parcours d'opération, toutes, avec leur étape ; sinon
    # celles de la saisie entière (`base`).
    private def step_errors(draft : WizardDraft, step : String, t : Hash(String, Array(String)), fields : Array(FormField)) : Array(String)
      return errs(t, "base") unless step == "summary" || finishing?(draft, step) || operation?(draft)
      summary_errors(draft, t, fields.map(&.name) + %w[data_key], step)
    end

    private def admin_rows(form : WizardForm?, draft : WizardDraft, step : String) : Array(WizardForm::AdminRow)?
      form.admin_rows if form && step == "admins" && draft.kind! == "firm"
    end

    private def extra_admins(form : WizardForm?, draft : WizardDraft, step : String) : Array(WizardForm::ExtraAdmin)?
      form.extra_admins if form && step == "admins" && draft.kind! != "firm"
    end

    private def summary(creation : WizardForm?, operation : WizardOperationForm?, step : String)
      return unless step == "summary"
      creation.try(&.summary) || operation.try(&.summary)
    end

    # Attente de l'exécutant d'un serveur déclaré : l'étape se rafraîchit.
    private def poll(draft : WizardDraft, step : String, number : Int32) : String?
      return unless draft.kind! == "server" && step == "check"
      server = Wizards.created_server(draft)
      "/wizards/server?step=#{number}" if server && !Wizards.connected?(server)
    end

    # Erreurs du récapitulatif : celles des étapes précédentes (la saisie a
    # pu devenir fausse depuis : sous-domaine pris entre-temps), avec leur
    # étape, puis les autres.
    private def summary_errors(draft : WizardDraft, t : Hash(String, Array(String)), inline : Array(String),
                               current : String) : Array(String)
      t.reject { |field, _| inline.includes?(field) }.flat_map do |field, messages|
        step = Wizards.step_of(draft.kind!, field)
        prefix = step == "summary" || step == current ? "" : "#{I18n.t("admin.wizards.steps.#{step}")} : "
        messages.map { |message| prefix + message }
      end
    end

    private def modules_values(draft : WizardDraft, t : Hash(String, Array(String)))
      kind = Wizards.dossier_kind(draft)
      regime = draft.text("regime").presence || "fr"
      chosen = draft.values.has_key?("modules") ? draft.list("modules") + draft.list("extensions") : Wizards.preset(draft)
      {families: PieceForm.families(kind, regime, chosen, t), other: other_field(draft.list("extensions"), t),
       pieces: picker(kind, [] of String, regime), piece_errors: piece_errors(t)}
    end

    # Fil des étapes : numéro, titre, lien vers une étape déjà atteinte.
    private def track(draft : WizardDraft, number : Int32) : Array(Hash(String, String | Bool))
      locked = Wizards.locked(draft)
      Wizards.steps(draft).each_with_index.map do |code, index|
        position = index + 1
        open = position <= draft.furthest && position != number && position > locked
        {"number" => position.to_s, "key" => "admin.wizards.steps.#{code}", "current" => position == number,
         "done" => position < number, "link" => open ? "/wizards/#{draft.kind!}?step=#{position}" : ""}
      end.to_a
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Assistants proposés (D-ADM-018) : ceux ouverts à l'utilisateur, avec un
  # brouillon à reprendre, et ceux envisagés.
  class WizardsHandler < ScreenHandler
    PROPOSED = %w[server restore move archive user]

    def get
      drafts = Wizards.drafts(user).to_h { |draft| {draft.kind!.to_s, draft} }
      items = Wizards::KINDS.select { |kind| Wizards.allowed?(user, kind) }.map do |kind|
        draft = drafts[kind]?
        {"kind" => kind, "title_key" => "admin.wizards.#{kind}.title", "help_key" => "admin.wizards.#{kind}.help",
         "draft" => !draft.nil?, "step" => (draft.try(&.current) || 1).to_s, "steps" => Wizards.steps(kind).size.to_s}
      end
      page("admin/wizards.html", {"items" => items, "proposed" => PROPOSED.map { |code| "admin.wizards.proposed.#{code}" }})
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
    def get
      kind = kind!
      draft = Wizards.draft(user, kind)
      requested = query("step").to_i?
      number = requested && requested >= 1 && requested <= draft.furthest ? requested : draft.current
      render_step(draft, number.clamp(1, Wizards.steps(kind).size))
    end

    def post
      kind = kind!
      draft = Wizards.draft(user, kind)
      steps = Wizards.steps(kind)
      number = (field("step").to_i? || draft.current).clamp(1, Math.min(draft.furthest, steps.size))
      step = steps[number - 1]
      return cancel(draft) if field("nav") == "cancel"
      keep(draft, step)
      case field("nav")
      when "previous"
        move(draft, Math.max(1, number - 1))
      when "more"
        Wizards.store(draft, {"slots_#{step}" => (draft.text("slots_#{step}").to_i? || 1).succ.to_s})
        move(draft, number)
      when "finish"
        finish(draft, number)
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
      Wizards::LISTS[group][step]?.try(&.each { |name| values[name] = raw_list(name) })
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
      following = Math.min(number + 1, Wizards.steps(draft.kind!).size)
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
      return render_step(draft, number) unless Wizards.steps(draft.kind!)[number - 1] == "summary"
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

    # --- Rendu -------------------------------------------------------------------

    private def render_step(draft : WizardDraft, number : Int32, errors : Fleet::Errors = Fleet::Errors.new,
                            status : Int32 = 200)
      steps = Wizards.steps(draft.kind!)
      step = steps[number - 1]
      t = translate(errors)
      form = WizardForm.new(self, draft, t)
      modules = step == "modules" ? modules_values(draft, t) : nil
      page("admin/wizard.html", {
        "kind"         => draft.kind!,
        "title_key"    => "admin.wizards.#{draft.kind!}.title",
        "step"         => step,
        "number"       => number.to_s,
        "total"        => steps.size.to_s,
        "step_key"     => "admin.wizards.steps.#{step}",
        "step_help"    => "admin.wizards.#{draft.kind!}.help_#{step}",
        "first"        => number == 1,
        "last"         => step == "summary",
        "track"        => track(draft, number),
        "fields"       => form.fields(step),
        "base_errors"  => step == "summary" ? summary_errors(draft, t) : errs(t, "base"),
        "boost"        => step != "modules",
        "admin_rows"   => step == "admins" && draft.kind! == "firm" ? form.admin_rows : nil,
        "extra_admins" => step == "admins" && draft.kind! != "firm" ? form.extra_admins : nil,
        "admin_errors" => errs(t, "admins") + errs(t, "extra_admins"),
        "summary"      => step == "summary" ? form.summary : nil,
        "families"     => modules.try(&.[:families]),
        "other"        => modules.try(&.[:other]),
        "pieces"       => modules.try(&.[:pieces]),
        "piece_errors" => modules.try(&.[:piece_errors]),
      }, status: status)
    end

    # Erreurs du récapitulatif : celles des étapes précédentes (la saisie a
    # pu devenir fausse depuis : sous-domaine pris entre-temps), avec leur
    # étape, puis les autres.
    private def summary_errors(draft : WizardDraft, t : Hash(String, Array(String))) : Array(String)
      t.flat_map do |field, messages|
        step = Wizards.step_of(draft.kind!, field)
        prefix = step == "summary" ? "" : "#{I18n.t("admin.wizards.steps.#{step}")} : "
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
      Wizards.steps(draft.kind!).each_with_index.map do |code, index|
        position = index + 1
        {"number" => position.to_s, "key" => "admin.wizards.steps.#{code}", "current" => position == number,
         "done" => position < number, "link" => position <= draft.furthest && position != number ? "/wizards/#{draft.kind!}?step=#{position}" : ""}
      end.to_a
    end
  end
end

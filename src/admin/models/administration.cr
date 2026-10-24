# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAdmin
  # Administrateur d'un dossier (D-ADM-017) : un compte au profil
  # administrateur *dans l'instance* du dossier, que la console déclare et
  # dont elle garde la liste. La liste est ordonnée par date d'ajout : le
  # premier est l'administrateur invité à la création (`Dossier#admin_email`).
  #
  # États : `pending`, déclaré, pas encore dans l'instance (création en
  # cours, ajout en attente de l'exécutant) ; `active`, présent dans
  # l'instance d'après la dernière tâche ou la dernière relecture.
  class DossierAdmin < Marten::Model
    STATES = %w[pending active]

    field :id, :big_int, primary_key: true, auto: true
    field :dossier, :many_to_one, to: PartiduoAdmin::Dossier, on_delete: :cascade
    field :email, :string, max_size: 254
    field :state, :string, max_size: 16, default: "pending"
    # Moyen d'authentification enrôlé dans l'instance, d'après la dernière
    # relecture (`instance.admins`) ; `nil` si jamais relu.
    field :usable, :bool, null: true, blank: true
    field :checked_at, :date_time, null: true, blank: true
    field :created_at, :date_time, auto_now_add: true
    field :updated_at, :date_time, auto_now: true

    db_unique_constraint :admin_dossier_admin_unique, field_names: [:dossier, :email]

    def state_key : String
      "admin.administrators.states.#{state}"
    end

    def usable_key : String
      case usable
      when true  then "admin.administrators.usable.ready"
      when false then "admin.administrators.usable.waiting"
      else            "admin.administrators.usable.unknown"
      end
    end
  end

  # Brouillon d'un assistant (D-ADM-018) : étape en cours, étape la plus
  # avancée atteinte, saisies (JSON). Un par utilisateur et par parcours :
  # un assistant interrompu reprend où il en était. Rien d'autre n'est créé
  # avant la validation finale ; le brouillon est effacé ensuite.
  class WizardDraft < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :user, :many_to_one, to: PartiduoAdmin::User, on_delete: :cascade
    field :kind, :string, max_size: 16
    field :step, :int, default: 1
    field :reached, :int, default: 1
    field :data, :text, default: "{}"
    field :created_at, :date_time, auto_now_add: true
    field :updated_at, :date_time, auto_now: true

    db_unique_constraint :admin_wizard_draft_unique, field_names: [:user, :kind]

    # Étape en cours et étape la plus avancée atteinte, en entiers.
    def current : Int32
      (step || 1).to_i32
    end

    def furthest : Int32
      (reached || 1).to_i32
    end

    def values : Hash(String, JSON::Any)
      JSON.parse(data.presence || "{}").as_h? || {} of String => JSON::Any
    rescue JSON::ParseException
      {} of String => JSON::Any
    end

    def text(key : String) : String
      value = values[key]?
      return "" if value.nil?
      value.as_s? || (value.raw.nil? ? "" : value.to_json)
    end

    def list(key : String) : Array(String)
      values[key]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
    end
  end
end

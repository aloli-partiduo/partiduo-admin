# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  # Filtres et pagination de la file des tâches : une valeur par colonne du
  # tableau (numéro, type, dossier, état, demandeur, date de création). Les
  # supervisions (une par serveur tous les quarts d'heure) noient le reste :
  # le type « tous sauf supervision » les écarte. Les valeurs viennent de la
  # requête (GET) : toute valeur inconnue ou mal formée est ignorée, jamais
  # une erreur.
  class TaskFilter
    include Marten::Template::Object::Auto

    PAGE_SIZE           = 50
    WITHOUT_SUPERVISION = "-supervision"
    SUPERVISION         = "supervision.check"

    getter id : String
    getter kind : String
    getter dossier : String
    getter state : String
    getter requested_by : String
    getter from : String
    getter to : String

    def initialize(id = "", kind = "", dossier = "", state = "", requested_by = "", from = "", to = "")
      @id = id.strip
      @kind = kind.strip
      @dossier = dossier.strip
      @state = state.strip
      @requested_by = requested_by.strip
      @from = from.strip
      @to = to.strip
    end

    # Filtres lus par `query` (paramètres GET de la page).
    def self.from_query(&query : String -> String) : TaskFilter
      new(id: query.call("id"), kind: query.call("kind"), dossier: query.call("dossier"), state: query.call("state"),
        requested_by: query.call("requested_by"), from: query.call("from"), to: query.call("to"))
    end

    def apply(scope : Marten::DB::Query::Set(Task)) : Marten::DB::Query::Set(Task)
      if number = id.lchop('#').to_i64?
        scope = scope.filter(id: number)
      end
      if kind == WITHOUT_SUPERVISION
        scope = scope.exclude(kind: SUPERVISION)
      elsif Protocol.valid_kind?(kind)
        scope = scope.filter(kind: kind)
      end
      scope = scope.filter(dossier__slug__icontains: dossier) unless dossier.empty?
      scope = scope.filter(state: state) if Protocol::STATES.includes?(state)
      scope = scope.filter(requested_by_label__icontains: requested_by) unless requested_by.empty?
      # Dates du formulaire (AAAA-MM-JJ), en UTC comme l'affichage du tableau ;
      # « au » inclut toute la journée.
      if day = date(from)
        scope = scope.filter(created_at__gte: day)
      end
      if day = date(to)
        scope = scope.filter(created_at__lt: day + 1.day)
      end
      scope
    end

    # Au moins un filtre actif (lien « réinitialiser »).
    def active : Bool
      !to_params.empty?
    end

    # Paramètres non vides, pour les liens de pagination.
    def to_params : Hash(String, String)
      {"id" => id, "kind" => kind, "dossier" => dossier, "state" => state, "requested_by" => requested_by,
       "from" => from, "to" => to}.reject { |_, value| value.empty? }
    end

    # Adresse d'une page de la liste filtrée.
    def url(page : Int32) : String
      params = to_params
      params["page"] = page.to_s if page > 1
      params.empty? ? "/tasks" : "/tasks?#{URI::Params.encode(params)}"
    end

    private def date(value : String) : Time?
      return unless value.matches?(/\A\d{4}-\d{2}-\d{2}\z/)
      Time.parse_utc(value, "%F")
    rescue Time::Format::Error | ArgumentError
      nil
    end
  end
end

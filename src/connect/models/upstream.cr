# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoConnect
  # Fournisseur d'identité d'un cabinet (ADR-012 D9) : connect s'appuie sur
  # lui pour les adresses de ses domaines, et pour elles seules. Déclaré par
  # l'exploitation (commande `upstream`). OpenID Connect, client
  # confidentiel, PKCE.
  class Upstream < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :code, :string, max_size: 64, unique: true
    field :name, :string, max_size: 200
    field :issuer, :string, max_size: 500
    field :authorization_endpoint, :string, max_size: 500
    field :token_endpoint, :string, max_size: 500
    field :jwks_uri, :string, max_size: 500
    field :client_id, :string, max_size: 255
    field :client_secret, :string, max_size: 500
    # Domaines de courriel couverts, séparés par des virgules.
    field :domains, :text
    # Niveau le plus haut reconnu à une connexion par ce fournisseur (1 à 3) :
    # le niveau attesté (MFA) y est plafonné.
    field :ceiling, :int, default: 2
    field :active, :bool, default: true
    field :created_at, :date_time, auto_now_add: true
    field :updated_at, :date_time, auto_now: true

    def domain_list : Array(String)
      domains.to_s.split(/[\s,]+/).map(&.strip.downcase).reject(&.empty?)
    end

    def covers?(email : String) : Bool
      domain = email.strip.downcase.partition('@')[2]
      !domain.empty? && domain_list.includes?(domain)
    end

    def callback_uri : String
      "#{Config.base_url}/login/sso/#{code}/callback"
    end
  end
end

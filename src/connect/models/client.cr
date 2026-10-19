# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoConnect
  # Client OpenID Connect (ADR-012 D3, D4) : un dossier ou l'administration.
  # Client confidentiel (secret conservé en empreinte) et PKCE obligatoire.
  # Les adresses admises sont comparées à l'identique, une par ligne.
  class Client < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :client_id, :string, max_size: 64, unique: true
    field :name, :string, max_size: 200
    field :secret_digest, :string, max_size: 64
    field :redirect_uris, :text
    field :post_logout_redirect_uris, :text, blank: true, default: ""
    field :backchannel_logout_uri, :string, max_size: 1000, blank: true, default: ""
    field :active, :bool, default: true
    field :created_at, :date_time, auto_now_add: true
    field :updated_at, :date_time, auto_now: true

    def redirect_uri_list : Array(String)
      split(redirect_uris.to_s)
    end

    def post_logout_redirect_uri_list : Array(String)
      split(post_logout_redirect_uris.to_s)
    end

    def redirect_uri_allowed?(uri : String) : Bool
      redirect_uri_list.includes?(uri)
    end

    def post_logout_redirect_uri_allowed?(uri : String) : Bool
      post_logout_redirect_uri_list.includes?(uri)
    end

    # Origines des adresses de retour : un retour après création de compte
    # (`return_to`) doit en être une.
    def origin_allowed?(url : String) : Bool
      target = URI.parse(url)
      redirect_uri_list.any? do |uri|
        allowed = URI.parse(uri)
        allowed.scheme == target.scheme && allowed.host == target.host && allowed.port == target.port
      end
    rescue URI::Error
      false
    end

    private def split(value : String) : Array(String)
      value.split(/[\s,]+/).map(&.strip).reject(&.empty?)
    end
  end
end

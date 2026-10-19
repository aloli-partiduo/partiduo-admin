# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoConnect
  # Code d'autorisation (flux « code » avec PKCE) : usage unique, une
  # minute, lié au client, à l'adresse de retour et au défi PKCE.
  class AuthorizationCode < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :code_digest, :string, max_size: 64, unique: true
    field :client, :many_to_one, to: PartiduoConnect::Client, on_delete: :cascade
    field :account, :many_to_one, to: PartiduoConnect::Account, on_delete: :cascade
    field :session, :many_to_one, to: PartiduoConnect::Session, on_delete: :cascade
    field :redirect_uri, :string, max_size: 1000
    field :code_challenge, :string, max_size: 128
    field :nonce, :string, max_size: 255, blank: true, default: ""
    field :scope, :string, max_size: 255, default: "openid"
    field :created_at, :date_time, auto_now_add: true
    field :expires_at, :date_time
    field :used_at, :date_time, null: true, blank: true
  end

  # Jeton d'accès opaque : lecture de `userinfo` seulement.
  class AccessToken < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :token_digest, :string, max_size: 64, unique: true
    field :client, :many_to_one, to: PartiduoConnect::Client, on_delete: :cascade
    field :account, :many_to_one, to: PartiduoConnect::Account, on_delete: :cascade
    field :scope, :string, max_size: 255, default: "openid"
    field :created_at, :date_time, auto_now_add: true
    field :expires_at, :date_time
  end

  # Clients auxquels une session a ouvert l'accès : ce sont eux qu'avise la
  # déconnexion unique (ADR-012 D8).
  class ClientSession < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :session, :many_to_one, to: PartiduoConnect::Session, on_delete: :cascade
    field :client, :many_to_one, to: PartiduoConnect::Client, on_delete: :cascade
    field :created_at, :date_time, auto_now_add: true
    field :notified_at, :date_time, null: true, blank: true
  end
end

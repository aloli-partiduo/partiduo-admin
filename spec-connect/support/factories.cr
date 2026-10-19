# SPDX-License-Identifier: AGPL-3.0-or-later

require "totp"

module ConnectSpec
  PASSWORD = "Cheval-Agrafe-Batterie-Correcte-42"

  @@sequence = 0

  def self.next_number : Int32
    @@sequence += 1
  end

  # Compte complet : mot de passe + TOTP confirmé (niveau 2).
  def self.account(email : String? = nil) : PartiduoConnect::Account
    number = next_number
    account = PartiduoConnect::Account.create!(sub: PartiduoConnect::Secrets.token(24),
      email: email || "personne#{number}@example.net", display_name: "Personne #{number}")
    account.password_digest = PartiduoConnect::Auth::Passwords.hash(PASSWORD)
    account.totp_secret = TOTP.generate_secret_base32
    account.totp_enabled_at = SPEC_NOW - 1.day
    account.save!
    account
  end

  # Code TOTP de l'instant figé des specs : le même d'un appel à l'autre ;
  # le dernier compteur accepté (anti-rejeu) est donc effacé avant.
  def self.totp(account : PartiduoConnect::Account) : String
    account.reload
    account.last_otp_counter = nil
    account.save!
    TOTP::Authenticator.from_base32(account.totp_secret.to_s).at(SPEC_NOW)
  end

  record Registered, client : PartiduoConnect::Client, secret : String

  def self.client(name : String = "pipo", backchannel : Bool = true) : Registered
    number = next_number
    base = "https://#{name}#{number}.partiduo.localhost"
    registered = PartiduoConnect::Clients.register("#{name}.partiduo.localhost",
      ["#{base}/auth/callback"], ["#{base}/"], backchannel ? "#{base}/auth/backchannel-logout" : "",
      client_id: "#{name}#{number}")
    Registered.new(registered.client, registered.secret)
  end

  # Connexion par mot de passe + TOTP ; rend le navigateur.
  def self.signed_in(account : PartiduoConnect::Account, browser : Browser = Browser.new) : Browser
    browser.post("/login", {"email" => account.email.to_s, "password" => PASSWORD, "next" => "/account"})
    browser.post("/login/second-factor", {"code" => totp(account), "next" => "/account"})
    browser
  end

  def self.verifier : String
    PartiduoConnect::Secrets.token(48)
  end

  def self.authorize_path(client : PartiduoConnect::Client, verifier : String, extra = {} of String => String) : String
    params = {
      "response_type"         => "code",
      "client_id"             => client.client_id.to_s,
      "redirect_uri"          => client.redirect_uri_list.first,
      "scope"                 => "openid email profile",
      "state"                 => "etat-123",
      "nonce"                 => "nonce-456",
      "code_challenge"        => PartiduoConnect::Oidc.pkce(verifier),
      "code_challenge_method" => "S256",
    }.merge(extra)
    "/authorize?#{URI::Params.encode(params)}"
  end

  def self.query(location : String) : URI::Params
    URI.parse(location).query_params
  end

  def self.basic(registered : Registered) : Hash(String, String)
    {"Authorization" => "Basic #{Base64.strict_encode("#{registered.client.client_id}:#{registered.secret}")}"}
  end
end

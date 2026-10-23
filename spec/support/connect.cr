# SPDX-License-Identifier: AGPL-3.0-or-later

require "jose"

# connect simulé pour l'administration (ADR-012 D4) : environnement réglé le
# temps d'un exemple, transport remplacé, clé ES256, jetons forgés.
module AdminConnectSpec
  URL       = "https://connect.partiduo.localhost"
  CLIENT_ID = "admin"

  KEY = Jose::JWK::ECKey.generate(Jose::JWK::Curve::P256)

  class Transport < PartiduoAdmin::Connect::Transport
    getter posts = [] of {String, Hash(String, String)}
    property id_token = ""
    property ticket = {"account" => false, "url" => "#{URL}/signup/jeton", "code" => "WXYZ-2345"}.to_json

    def post_form(url : String, form : Hash(String, String)) : {Int32, String}
      posts << {url, form}
      return {200, ticket} if url.ends_with?("/api/v1/signup-tickets")
      {200, {"access_token" => "a", "token_type" => "Bearer", "id_token" => id_token}.to_json}
    end

    def get(url : String) : {Int32, String}
      public = AdminConnectSpec::KEY.public_key.to_jwk_hash
      public["kid"] = "k1"
      {200, {"keys" => [public]}.to_json}
    end
  end

  def self.with_connect(&)
    previous = PartiduoAdmin::Connect.transport
    transport = Transport.new
    PartiduoAdmin::Connect.transport = transport
    ENV["PARTIDUO_ADMIN_CONNECT_URL"] = URL
    ENV["PARTIDUO_ADMIN_CONNECT_CLIENT_ID"] = CLIENT_ID
    ENV["PARTIDUO_ADMIN_CONNECT_CLIENT_SECRET"] = "secret-admin"
    begin
      yield transport
    ensure
      %w[URL CLIENT_ID CLIENT_SECRET].each { |name| ENV.delete("PARTIDUO_ADMIN_CONNECT_#{name}") }
      PartiduoAdmin::Connect.transport = previous
    end
  end

  def self.sign(claims : Hash(String, JSON::Any)) : String
    Jose::JWS.sign(claims.to_json, Jose::JWS::Algorithm::ES256, KEY, {"kid" => "k1"})
  end

  # `locale` : claim de la langue du compte connect, absent si `nil`.
  def self.id_token(nonce : String, subject : String, email : String, acr : String = "2", sid : String = "sid-a",
                    locale : String? = nil) : String
    claims = {"iss" => JSON::Any.new(URL), "aud" => JSON::Any.new(CLIENT_ID), "sub" => JSON::Any.new(subject),
              "nonce" => JSON::Any.new(nonce), "exp" => JSON::Any.new((Time.utc + 5.minutes).to_unix),
              "iat" => JSON::Any.new(Time.utc.to_unix), "email" => JSON::Any.new(email), "acr" => JSON::Any.new(acr),
              "sid" => JSON::Any.new(sid)}
    claims["locale"] = JSON::Any.new(locale) if locale
    sign(claims)
  end

  # Aller-retour complet par connect dans `browser` : rend la réponse du
  # retour.
  def self.login(browser : AdminSpec::Browser, transport : Transport, subject : String, email : String,
                 acr : String = "2", start : String = "/login/connect", locale : String? = nil) : Marten::HTTP::Response
    location = browser.get(start).headers["Location"]
    query = URI.parse(location).query_params
    transport.id_token = id_token(query["nonce"], subject, email, acr, locale: locale)
    browser.get("/login/connect/callback?#{URI::Params.encode({"code" => "c1", "state" => query["state"]})}")
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "jose"

module PartiduoConnect
  # Clés de signature des jetons (ES256, ADR-012 D3, D5). Elles sont
  # partagées par tous les serveurs `connect` : gardées au coffre, posées par
  # beryl dans le fichier `PARTIDUO_CONNECT_SIGNING_KEYS` (JWK privées, une
  # liste ou `{"keys": […]}`). La *première* signe ; toutes sont publiées.
  #
  # Rotation : ajouter la nouvelle clé en *seconde* position (publiée, pas
  # encore utilisée), attendre que les clients aient relu les clés, puis la
  # passer en première ; retirer l'ancienne après la durée de vie des
  # jetons.
  #
  # Sans fichier, hors production, une clé éphémère est tirée au démarrage
  # (développement, specs).
  module SigningKeys
    class Error < Exception
    end

    @@keys : Array(Jose::JWK::ECKey)?

    def self.keys : Array(Jose::JWK::ECKey)
      @@keys ||= load
    end

    def self.active : Jose::JWK::ECKey
      keys.first
    end

    def self.kid(key : Jose::JWK::ECKey) : String
      key.kid || key.thumbprint_base64url
    end

    # Clés publiques au format JWK Set (`/jwks.json`).
    def self.jwks : String
      {"keys" => keys.map { |key| public_jwk(key) }}.to_json
    end

    def self.public_jwk(key : Jose::JWK::ECKey) : Hash(String, String)
      jwk = key.to_jwk_hash(include_private: false)
      jwk["kid"] = kid(key)
      jwk["use"] = "sig"
      jwk["alg"] = "ES256"
      jwk
    end

    def self.sign(claims : Hash, typ : String = "JWT") : String
      key = active
      Jose::JWS.sign(claims.to_json, Jose::JWS::Algorithm::ES256, key, {"kid" => kid(key), "typ" => typ})
    end

    # Vérifie un jeton émis par `connect` (indice `id_token_hint`) et rend
    # ses revendications, expiré ou non ; `nil` si la signature est fausse.
    def self.verify(token : String) : Hash(String, JSON::Any)?
      header = Jose::JWS.decode(token)[:header]
      kid = header["kid"]?.try(&.as_s?)
      candidates = kid ? keys.select { |key| self.kid(key) == kid } : keys
      candidates.each do |key|
        payload = Jose::JWS.verify(token, key.public_key)
        return Hash(String, JSON::Any).from_json(String.new(payload))
      rescue Jose::JWS::VerificationError
        next
      end
      nil
    rescue Jose::JWS::Error | JSON::ParseException | ArgumentError | IndexError | Base64::Error
      nil
    end

    # Nouvelle clé privée, sur une ligne (pour `secrets set` du coffre).
    def self.generate : String
      key = Jose::JWK::ECKey.generate(Jose::JWK::Curve::P256)
      jwk = key.to_jwk_hash(include_private: true)
      jwk["kid"] = key.thumbprint_base64url
      jwk.to_json
    end

    # Specs : remplace les clés (ou les relit).
    def self.reset(keys : Array(Jose::JWK::ECKey)? = nil) : Nil
      @@keys = keys
    end

    private def self.load : Array(Jose::JWK::ECKey)
      if path = Config.signing_keys_path
        raise Error.new("Clés de signature introuvables : #{path}") unless File.exists?(path)
        parsed = JSON.parse(File.read(path))
        list = parsed.as_a? || parsed["keys"]?.try(&.as_a?) || raise Error.new("#{path} : liste de JWK attendue")
        keys = list.map { |item| Jose::JWK::ECKey.from_jwk_hash(item.as_h) }
        raise Error.new("#{path} : aucune clé") if keys.empty?
        keys.each do |key|
          raise Error.new("#{path} : clé sans partie privée") unless key.private?
          raise Error.new("#{path} : courbe P-256 attendue (ES256)") unless key.curve == Jose::JWK::Curve::P256
        end
        return keys
      end
      raise Error.new("PARTIDUO_CONNECT_SIGNING_KEYS non réglée : aucune clé de signature") if Marten.env.production?
      [Jose::JWK::ECKey.generate(Jose::JWK::Curve::P256)]
    end
  end
end

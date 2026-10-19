# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "crypto/subtle"
require "openssl"

module PartiduoConnect
  # Jetons aléatoires et empreintes : un jeton remis (session, code,
  # invitation, défi) n'est jamais stocké en clair.
  module Secrets
    # Alphabet des codes lus ou dictés (sans 0/O, 1/I/L).
    ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

    def self.token(bytes : Int32 = 32) : String
      base64url(Random::Secure.random_bytes(bytes))
    end

    def self.digest(value : String) : String
      OpenSSL::Digest.new("SHA256").update(value).final.hexstring
    end

    def self.base64url(bytes : Bytes) : String
      Base64.urlsafe_encode(bytes, padding: false)
    end

    def self.decode64?(value : String) : Bytes?
      normalized = value.strip.tr("-_", "+/").delete('=')
      return Bytes.empty if normalized.empty?
      normalized += "=" * ((4 - normalized.size % 4) % 4)
      Base64.decode(normalized)
    rescue Base64::Error
      nil
    end

    def self.equal?(a : String, b : String) : Bool
      Crypto::Subtle.constant_time_compare(a, b)
    end

    # Code lisible par groupes de quatre (`XXXX-XXXX`).
    def self.readable_code(length : Int32) : String
      String.build do |io|
        length.times do |index|
          io << '-' if index > 0 && index % 4 == 0
          io << ALPHABET[Random::Secure.rand(ALPHABET.size)]
        end
      end
    end

    def self.normalize_code(code : String) : String
      code.upcase.gsub(/[^A-Z0-9]/, "")
    end
  end
end

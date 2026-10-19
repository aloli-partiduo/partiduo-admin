# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/client"
require "json"
require "uri"

module PartiduoAgent
  # connect (ADR-012) : client d'un dossier, déclaré par cet exécutant
  # (registraire) à la création du dossier. Le secret ne passe que de connect
  # à l'environnement du dossier : jamais par l'administration, jamais en
  # argument d'une commande.
  record ConnectClient, url : String, client_id : String, secret : String

  module Connect
    TIMEOUT = 10.seconds

    # Déclare (ou redéclare, nouveau secret) le client du dossier `host`.
    def self.register(url : String, token : String, host : String) : ConnectClient
      json = post(url, token, {"host" => host})
      client_id = json["client_id"]?.try(&.as_s?)
      secret = json["client_secret"]?.try(&.as_s?)
      raise StepError.new("connect : réponse incomplète", "connect") if client_id.nil? || secret.nil?
      ConnectClient.new(url, client_id, secret)
    end

    # Dossier supprimé : client désactivé chez connect (sans effet s'il n'y
    # en a pas).
    def self.disable(url : String, token : String, host : String) : Nil
      post(url, token, {"host" => host, "action" => "disable"})
    end

    private def self.post(url : String, token : String, form : Hash(String, String)) : JSON::Any
      uri = URI.parse("#{url.rchop('/')}/api/v1/clients")
      http = HTTP::Client.new(uri)
      http.connect_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      begin
        response = http.post(uri.request_target, form: form, headers: HTTP::Headers{"Authorization" => "Bearer #{token}"})
        unless response.success?
          detail = (JSON.parse(response.body)["error_description"]?.try(&.as_s?) rescue nil) || "HTTP #{response.status_code}"
          raise StepError.new("connect refuse le client #{form["host"]} : #{detail}", "connect")
        end
        JSON.parse(response.body)
      ensure
        http.close
      end
    rescue ex : IO::Error | Socket::Error | OpenSSL::SSL::Error | JSON::ParseException
      raise StepError.new("connect injoignable (#{url}) : #{ex.message}", "connect")
    end
  end
end

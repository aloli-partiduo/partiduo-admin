# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/client"
require "log"

module PartiduoConnect
  # Déconnexion unique (ADR-012 D8) : à la fermeture d'une session, chaque
  # client qu'elle avait ouvert reçoit un jeton de déconnexion à son adresse
  # `backchannel_logout_uri` (OpenID Connect Back-Channel Logout 1.0).
  # Envoi en tâche de fond ; un échec est journalisé, la session reste
  # fermée chez `connect` (le client la perdra au plus tard à son échéance).
  module Backchannel
    Log = ::Log.for("connect.backchannel")

    # Envoi remplaçable dans les specs : (adresse, jeton) → réussite.
    class_property sender : Proc(String, String, Bool) = ->(uri : String, token : String) { post(uri, token) }
    # Les specs envoient sans tâche de fond.
    class_property synchronous : Bool = false

    def self.logout(session : Session, now : Time = Time.utc) : Nil
      account = session.account
      return if account.nil?
      ClientSession.filter(session_id: session.pk, notified_at__isnull: true).to_a.each do |link|
        client = link.client
        next if client.nil? || client.backchannel_logout_uri.to_s.empty?
        link.notified_at = now
        link.save!
        uri = client.backchannel_logout_uri.to_s
        token = Oidc.logout_token(client, account, session.sid.to_s, now)
        if synchronous
          deliver(uri, token, client)
        else
          spawn { deliver(uri, token, client) }
        end
      end
    end

    private def self.deliver(uri : String, token : String, client : Client) : Nil
      Log.warn { "Déconnexion refusée par #{client.client_id} (#{uri})" } unless sender.call(uri, token)
    rescue ex
      Log.warn { "Déconnexion non transmise à #{client.client_id} (#{uri}) : #{ex.message}" }
    end

    def self.post(uri : String, token : String) : Bool
      parsed = URI.parse(uri)
      client = HTTP::Client.new(parsed)
      client.connect_timeout = Config::BACKCHANNEL_TIMEOUT
      client.read_timeout = Config::BACKCHANNEL_TIMEOUT
      response = client.post(parsed.request_target, form: {"logout_token" => token},
        headers: HTTP::Headers{"Cache-Control" => "no-store"})
      response.success?
    ensure
      client.try(&.close)
    end
  end
end

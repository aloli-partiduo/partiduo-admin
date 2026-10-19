# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoConnect
  # Journal en ajout seul (ADR-012 D7) : connexions, élévations,
  # enrôlements, récupérations, changements de facteur. La personne lit le
  # sien sur la page de son compte.
  module Audit
    def self.log(account : Account?, action : String, detail = {} of String => String, outcome : String = "ok",
                 ip : String = "", client : Client? = nil, label : String? = nil) : AuditEntry
      AuditEntry.create!(
        account_id: account.try(&.pk).as?(Int64),
        account_label: (label || account.try(&.email.to_s) || "")[0, 255]? || "",
        action: action,
        client_id: client.try(&.client_id.to_s) || "",
        outcome: outcome,
        ip: ip[0, 64]? || "",
        detail: detail.to_json,
      )
    end

    def self.for(account : Account, limit : Int32 = Config::AUDIT_PAGE) : Array(AuditEntry)
      AuditEntry.filter(account_id: account.pk).order("-created_at", "-id")[0...limit].to_a
    end
  end
end

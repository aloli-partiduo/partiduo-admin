# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAdmin
  module Tasks
    # Effets d'une tâche terminée sur l'inventaire : état et version du
    # dossier, sauvegardes, certificats, supervision.
    module Effects
      # Clés du résultat jamais conservées : le lien d'invitation et son
      # jeton ne sont écrits nulle part ailleurs que dans le courriel envoyé
      # à l'adresse invitée (instance-cli, `admin-invite`).
      SECRET_KEYS = %w[url token invitation_url]

      # Envoi du lien d'invitation en échec : `Tasks.finish` annule alors
      # tout (état, résultat expurgé, effets) et répond une erreur à
      # l'exécutant, qui garde le lien dans son journal de reprise et rend
      # compte de nouveau à la reprise de la tâche (D-AFN-008).
      class DeliveryError < Exception
      end

      def self.deliver_invitation(dossier : Dossier, email : String, url : String) : Nil
        Mailer.invitation_to_dossier(dossier, email, url)
      rescue ex
        raise DeliveryError.new("#{email} : #{ex.class} #{ex.message}")
      end

      def self.sanitize(task : Task, result : JSON::Any) : JSON::Any
        hash = result.as_h?
        return result if hash.nil?
        JSON::Any.new(hash.reject { |key, _| SECRET_KEYS.includes?(key) })
      end

      alias Handler = Proc(Task, Dossier, Bool, JSON::Any, Time, Nil)

      # Effet de chaque type de tâche portant sur un dossier.
      HANDLERS = {
        "instance.create"          => Handler.new { |task, dossier, success, result, now| created(task, dossier, success, result, now) },
        "instance.modules"         => Handler.new { |task, dossier, success, _, _| modules(dossier, success, task) },
        "instance.suspend"         => Handler.new { |_, dossier, success, _, now| state(dossier, success, "suspended", now) },
        "instance.resume"          => Handler.new { |_, dossier, success, _, now| state(dossier, success, "active", now) },
        "instance.restore_archive" => Handler.new { |_, dossier, success, _, now| state(dossier, success, "active", now) },
        "instance.archive"         => Handler.new { |task, dossier, success, result, now| archived(task, dossier, success, result, now) },
        "instance.delete"          => Handler.new { |task, dossier, success, _, now| deleted(task, dossier, success, now) },
        "instance.admin_invite"    => Handler.new { |task, dossier, success, result, _| invited(task, dossier, success, result) },
        "instance.admin_add"       => Handler.new { |task, dossier, success, result, _| admin_added(task, dossier, success, result) },
        "instance.admin_remove"    => Handler.new { |task, dossier, success, result, _| Administrators.removed(task, dossier, result) if success },
        "instance.admins"          => Handler.new { |task, dossier, success, result, now| Administrators.refreshed(task, dossier, result, now) if success },
        "backup.run"               => Handler.new { |task, dossier, success, result, now| backed_up(task, dossier, success, result, now) },
        "backup.prune"             => Handler.new { |task, _, success, _, now| pruned(task, success, now) },
        "backup.test_restore"      => Handler.new { |task, _, success, _, now| test_restored(task, success, now) },
        "backup.restore"           => Handler.new { |task, dossier, success, result, now| restored(task, dossier, success, result, now) },
      }

      def self.apply(task : Task, ok : Bool, result : JSON::Any, now : Time) : Nil
        if task.kind == "supervision.check"
          Supervision.apply(task.server!, ok, result, now)
          return
        end
        dossier = task.dossier
        return if dossier.nil?
        HANDLERS[task.kind]?.try(&.call(task, dossier, ok, result, now))
      end

      def self.created(task : Task, dossier : Dossier, ok : Bool, result : JSON::Any, now : Time) : Nil
        unless ok
          dossier.state = "error"
          dossier.save!
          return
        end
        dossier.state = "active"
        dossier.database = result["database"]?.try(&.as_s?) || dossier.database
        dossier.version = result["version"]?.try(&.as_s?) || dossier.version
        dossier.save!
        record_certificate(dossier, result, now)
        Administrators.after_creation(task, dossier)
        if url = result["invitation_url"]?.try(&.as_s?)
          deliver_invitation(dossier, dossier.admin_email.to_s, url)
        end
      end

      # Administrateur ajouté (D-ADM-017) : liste à jour, lien remis par
      # l'administration quand le serveur ne l'a pas envoyé lui-même.
      def self.admin_added(task : Task, dossier : Dossier, ok : Bool, result : JSON::Any) : Nil
        return unless ok
        Administrators.added(task, dossier, result)
        if url = result["url"]?.try(&.as_s?)
          deliver_invitation(dossier, result["email"]?.try(&.as_s?) || task.params_json["email"]?.try(&.as_s?) || "", url)
        end
      end

      def self.modules(dossier : Dossier, ok : Bool, task : Task) : Nil
        return unless ok
        params = task.params_json
        dossier.modules = params["target_modules"]?.try(&.as_a.map(&.as_s).join(',')) || dossier.modules
        dossier.extensions = params["target_extensions"]?.try(&.as_a.map(&.as_s).join(',')) || dossier.extensions
        dossier.save!
      end

      def self.state(dossier : Dossier, ok : Bool, state : String, now : Time) : Nil
        return unless ok
        dossier.state = state
        dossier.suspended_at = state == "suspended" ? now : nil
        if state == "active"
          dossier.archived_at = nil
          dossier.retention_until = nil
        end
        dossier.save!
      end

      def self.archived(task : Task, dossier : Dossier, ok : Bool, result : JSON::Any, now : Time) : Nil
        return unless ok
        backup = record_backup(task, dossier, "archive", result["backup"]? || result, now)
        backup.frozen = true
        backup.keep_until = now.shift(years: Config::ARCHIVE_RETENTION_YEARS)
        backup.state = result["backup"]?.try(&.["verified"]?).try(&.as_bool?) ? "verified" : backup.state
        backup.verified_at = now if backup.state == "verified"
        backup.save!
        dossier.state = "archived"
        dossier.archived_at = now
        dossier.retention_until = now.shift(years: Config::ARCHIVE_RETENTION_YEARS)
        dossier.save!
      end

      def self.deleted(task : Task, dossier : Dossier, ok : Bool, now : Time) : Nil
        return unless ok
        # Archives d'un dossier d'essai encore dans leur durée légale : gardées
        # par le stockage (D-CRA-007), pas marquées élaguées.
        kept = task.result_json["kept"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
        scope = Backup.filter(dossier_id: dossier.pk).exclude(state: "pruned")
        scope = scope.exclude(path__in: kept) unless kept.empty?
        scope.update(state: "pruned", pruned_at: now)
        dossier.state = "deleted"
        dossier.deleted_at = now
        dossier.save!
        # Le dossier d'abord, le nom ensuite (ADR-013 D6).
        Dns.request(dossier, nil, now)
      end

      def self.invited(task : Task, dossier : Dossier, ok : Bool, result : JSON::Any) : Nil
        return unless ok
        if url = result["url"]?.try(&.as_s?)
          email = result["email"]?.try(&.as_s?) || task.params_json["email"]?.try(&.as_s?) || dossier.admin_email.to_s
          deliver_invitation(dossier, email, url)
        end
      end

      def self.backed_up(task : Task, dossier : Dossier, ok : Bool, result : JSON::Any, now : Time) : Nil
        kind = task.params_json["kind"]?.try(&.as_s?) || "manual"
        if ok
          record_backup(task, dossier, kind, result, now)
        else
          Backup.create!(dossier: dossier, task: task, kind: kind, state: "failed", taken_at: now)
        end
      end

      def self.pruned(task : Task, ok : Bool, now : Time) : Nil
        return unless ok
        ids = task.params_json["backup_ids"]?.try(&.as_a.map(&.as_i64)) || [] of Int64
        # Sauvegardes d'un autre serveur (dossier déplacé) : gardées par
        # l'exécutant, pas marquées élaguées (D-CHF-024).
        kept = task.result_json["kept"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
        scope = Backup.filter(id__in: ids, frozen: false)
        scope = scope.exclude(path__in: kept) unless kept.empty?
        scope.update(state: "pruned", pruned_at: now)
      end

      def self.test_restored(task : Task, ok : Bool, now : Time) : Nil
        id = task.params_json["backup_id"]?.try(&.as_i64?)
        return if id.nil?
        backup = Backup.filter(id: id).first
        return if backup.nil?
        # Restauration test réussie : l'alerte d'un échec précédent du dossier
        # n'a plus lieu d'être.
        Alerts.resolve("test_restore_failed", dossier: backup.dossier, now: now) if ok
        if ok && task.result_json["check"]?.try(&.as_s?) == "envelope"
          # Clé du cabinet absente : empreinte et enveloppe vérifiées, le
          # contenu ne l'est qu'avec la clé du cabinet (D-CHF-007).
          backup.test_restored_at = now
          backup.test_check = "envelope"
          backup.save!
        elsif ok
          backup.test_restored_at = now
          backup.test_check = "full"
          backup.state = "verified"
          backup.verified_at = now
          backup.save!
        else
          Alerts.open("test_restore_failed", "danger", dossier: backup.dossier, detail: "backup #{id}", now: now)
        end
      end

      def self.restored(task : Task, dossier : Dossier, ok : Bool, result : JSON::Any, now : Time) : Nil
        if safety = result["safety_backup"]?
          record_backup(task, dossier, "pre_restore", safety, now) if safety.as_h?
        end
        copy = if task.params_json["target"]?.try(&.as_s?) == "new"
                 task.params_json["new_slug"]?.try(&.as_s?).try { |slug| Dossier.filter(slug: slug).first }
               end
        unless ok
          # Copie non installée : en erreur, comme une création échouée.
          if copy && copy.state == "creating"
            copy.state = "error"
            copy.save!
          end
          return
        end
        if task.params_json["target"]?.try(&.as_s?) == "new"
          installed_copy(copy, result, now) if copy
        else
          dossier.state = "active"
          dossier.version = result["version"]?.try(&.as_s?) || dossier.version
          dossier.save!
          # Déplacement : instance installée sur le nouveau serveur, son
          # certificat compté dans le quota (ADR-013 D7).
          record_certificate(dossier, result, now) if task.params_json["target"]?.try(&.as_s?) == "move"
        end
      end

      # Copie installée comme à la création (service, vhost, certificat) :
      # active, certificat compté dans le quota (D-AFN-009).
      private def self.installed_copy(copy : Dossier, result : JSON::Any, now : Time) : Nil
        copy.state = "active"
        copy.database = result["database"]?.try(&.as_s?) || copy.database
        copy.version = result["version"]?.try(&.as_s?) || copy.version
        copy.save!
        Administrators.after_restored_copy(copy)
        record_certificate(copy, result, now)
      end

      def self.record_backup(task : Task, dossier : Dossier, kind : String, data : JSON::Any, now : Time) : Backup
        taken = data["taken_at"]?.try(&.as_s?).try { |value| Time.parse_rfc3339(value) rescue nil } || now
        text = ->(key : String, limit : Int32) { data[key]?.try(&.as_s?).try(&.[0, limit]?) || "" }
        sealing = sealing_fields(data["encryption"]?)
        Backup.create!(
          encryption_mode: sealing[:mode], key_fingerprint: sealing[:key_fingerprint], recipient: sealing[:recipient],
          capsule: sealing[:capsule], capsule_keys: sealing[:capsule_keys],
          origin: text.call("server", 64).presence || dossier.server.try(&.name.to_s) || "",
          manifest: text.call("manifest", 16_384),
          manifest_signature: text.call("signature", 4096),
          signing_key: signing_fingerprint(data),
          media_sha256: text.call("media_sha256", 64),
          dossier: dossier, task: task, kind: kind, state: "done",
          path: text.call("path", 512),
          media_path: text.call("media_path", 512),
          size_bytes: data["size_bytes"]?.try(&.as_i64?),
          sha256: text.call("sha256", 64),
          version: data["version"]?.try(&.as_s?) || dossier.version.to_s,
          taken_at: taken,
          keep_until: taken + (dossier.backup_retention_days || 30).days,
        )
      end

      # Chiffrement rendu par l'exécutant : mode, empreinte de la clé du
      # cabinet, destinataire de la clé de sauvegarde, capsule et empreintes
      # des clés d'exploitation qu'elle vise (D-CHF-014).
      def self.sealing_fields(encryption : JSON::Any?)
        text = ->(key : String, limit : Int32) { encryption.try(&.[key]?).try(&.as_s?).try(&.[0, limit]?) || "" }
        mode = text.call("mode", 16)
        mode = "none" unless BackupEncryption::MODES.includes?(mode)
        sealed = mode != "none"
        keys = encryption.try(&.["capsule_keys"]?).try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
        {mode:            mode,
         key_fingerprint: mode == "cabinet" ? text.call("key_fingerprint", 64) : "",
         recipient:       sealed ? text.call("recipient", 4096) : "",
         capsule:         sealed ? text.call("capsule", 65_536) : "",
         capsule_keys:    keys.select(&.matches?(/\A[0-9a-f]{64}\z/)).join(',')}
      end

      # Empreinte de la clé qui a signé le manifeste (`SHA256:…`).
      def self.signing_fingerprint(data : JSON::Any) : String
        line = data["signing_key"]?.try(&.as_s?).try { |value| BackupCrypto::Signature.normalize(value) }
        line ? BackupCrypto::Signature.fingerprint(line) : ""
      end

      def self.record_certificate(dossier : Dossier, result : JSON::Any, now : Time) : Nil
        certificate = result["certificate"]?
        return if certificate.nil? || certificate["issued"]?.try(&.as_bool?) != true
        CertificateIssue.create!(dossier: dossier, host: dossier.host, domain: dossier.server.try(&.domain) || Config.domain,
          staging: certificate["staging"]?.try(&.as_bool?) || false, issued_at: now)
      end
    end
  end
end

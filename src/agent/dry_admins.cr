# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoAgent
  # Mode à blanc : administrateurs simulés de chaque instance (contrat
  # d'instance 1.4.0, D-ADM-017) — l'adresse de provisionnement, puis celles
  # que les tâches ajoutent ou retirent, avec les refus de l'instance
  # (dernier administrateur, adresse inconnue) ; avis aux administrateurs
  # actuels (contrat 1.5.0, D-ADM-020), rédigés comme une instance sans
  # transport de courriel : à remettre par l'exécutant.
  class DrySystem < System
    # Base → adresses des administrateurs actifs.
    getter admins = {} of String => Array(String)

    def provision(slug : String, domain : String, params : JSON::Any, database : String, skip_createdb : Bool,
                  connect : ConnectClient? = nil) : String
      output = previous_def
      email = params["admin_email"]?.try(&.as_s?).to_s
      admins[database] = email.empty? ? [] of String : [email]
      output
    end

    def instance(slug : String, action : String, args : Array(String), package : String? = nil,
                 database : String? = nil) : InstanceReply
      return previous_def unless %w[admins admin-add admin-remove].includes?(action)
      op("instance #{action}", ([slug] + args.reject(&.starts_with?("--requested-by"))).join(' '))
      list = admins[database || database_for(slug)] ||= [] of String
      case action
      when "admins"
        entries = list.map do |email|
          {"email" => email, "full_name" => "", "active" => true, "revoked" => false, "usable" => true, "last_login_at" => nil}
        end
        dry_reply(action, {"admins" => entries, "usable_admins" => list.size})
      when "admin-add"
        email = args.first? || ""
        created = !list.includes?(email)
        notices = created ? dry_notices(list, "add", email, args) : [] of Hash(String, String | Bool)
        list << email if created
        dry_reply(action, {"email" => email, "user_created" => created, "promoted" => false,
                           "token" => "DRYADD", "url" => "https://dry-run/invitation/DRYADD",
                           "expires_at" => "2026-10-05T00:00:00Z", "usable_admins" => list.size - (created ? 1 : 0),
                           "approval_mode" => option(args, "--approval-mode") || "dual", "signup_code" => "",
                           "connect_account" => false, "notices" => notices})
      else
        dry_remove(list, args)
      end
    end

    private def dry_remove(list : Array(String), args : Array(String)) : InstanceReply
      email = args.first? || ""
      return dry_refusal("instance.admin_remove.unknown") unless list.includes?(email)
      return dry_refusal("instance.admin_remove.last") if list.size <= 1
      notices = dry_notices(list, option(args, "--removal") || "revoke", email, args)
      list.delete(email)
      dry_reply("admin-remove", {"email" => email, "removal" => option(args, "--removal") || "", "changed" => true,
                                 "remaining_admins" => list.size, "approval_mode" => option(args, "--approval-mode") || "dual",
                                 "notices" => notices})
    end

    # Avis simulés : un par administrateur actuel, sauf celui qu'on ajoute.
    private def dry_notices(list : Array(String), gesture : String, email : String,
                            args : Array(String)) : Array(Hash(String, String | Bool))
      by = [option(args, "--firm"), option(args, "--requester")].compact.join(", ")
      list.reject { |admin| gesture == "add" && admin == email }.map do |admin|
        {"email" => admin, "locale" => "fr", "delivered" => false, "subject" => "[à blanc] #{gesture} #{email}",
         "body" => "[à blanc] #{gesture} #{email} par #{by}\n"} of String => String | Bool
      end
    end

    private def option(args : Array(String), name : String) : String?
      args.index(name).try { |index| args[index + 1]? }
    end

    private def dry_reply(action : String, data) : InstanceReply
      InstanceReply.new(0, JSON.parse({"contract" => contract, "action" => action, "ok" => true, "data" => data}.to_json))
    end

    private def dry_refusal(reason : String) : InstanceReply
      InstanceReply.new(4, JSON.parse({"contract" => contract, "ok" => false,
                                       "error" => {"code" => "refused", "reason" => reason, "message" => reason}}.to_json))
    end
  end
end

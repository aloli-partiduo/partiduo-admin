# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Administrateurs d'un dossier, côté exécutant (D-ADM-017, contrat
# d'instance 1.4.0) : relecture, ajout, remplacement et retrait, trace de
# la validation transmise, instance trop ancienne refusée avant tout geste.

private def params(**extra) : Hash(String, JSON::Any)
  base = JSON.parse({"slug" => "garde", "host" => "garde.partiduo.localhost", "domain" => "partiduo.localhost",
                     "database" => "", "modules" => ["accounting"], "extensions" => [] of String,
                     "package" => "app", "locale" => "fr", "reason" => "nouvelle gérante", "approval_ref" => "DV-9",
                     "approval_mode" => "single", "approvers" => ["seule@cabinet.fr"]}.to_json).as_h
  extra.each { |key, value| base[key.to_s] = JSON.parse(value.to_json) }
  base
end

# Exécute une tâche à blanc sur une instance qui a déjà `admins`.
private def run(admin : AdminSpec::FakeAdmin, id : Int64, kind : String, task_params : Hash,
                admins = ["patron@garde.fr"], contract = "1.4.0") : {JSON::Any, PartiduoAgent::DrySystem}
  admin.push(id, kind, task_params)
  runner = PartiduoAgent::Runner.new(admin.config)
  dry = runner.build_system(->(_line : String) { nil }).as(PartiduoAgent::DrySystem)
  dry.contract = contract
  dry.databases << "partiduo_adm_garde"
  dry.provisioned << "partiduo_adm_garde"
  dry.admins["partiduo_adm_garde"] = admins.dup
  runner.run_once.should be_true
  {admin.finished[id], dry}
end

private def with_admin(&)
  admin = AdminSpec::FakeAdmin.new
  begin
    yield admin
  ensure
    admin.close
  end
end

describe "partiduo-agent : administrateurs d'un dossier (D-ADM-017)" do
  it "ajoute un administrateur avec la trace de la validation et rend le lien d'invitation" do
    with_admin do |admin|
      report, dry = run(admin, 950_i64, "instance.admin_add", params(email: "gerante@garde.fr"))
      report["ok"].as_bool.should be_true
      call = dry.calls.find!(&.starts_with?("instance admin-add"))
      call.should contain("gerante@garde.fr --reason nouvelle gérante --approval-ref DV-9 --approval-mode single --approvers seule@cabinet.fr")
      dry.admins["partiduo_adm_garde"].should eq(["patron@garde.fr", "gerante@garde.fr"])
      report["result"]["url"].should eq("https://dry-run/invitation/DRYADD")
      report["result"]["user_created"].should be_true
      admin.logs[950_i64].join('\n').should contain("administrateur ajouté — validation à une personne DV-9 par seule@cabinet.fr")
    end
  end

  it "remplace : ajoute le nouveau, puis retire l'ancien" do
    with_admin do |admin|
      report, dry = run(admin, 951_i64, "instance.admin_add",
        params(email: "nouveau@garde.fr", replaces: "patron@garde.fr", replace_removal: "demote"))
      report["ok"].as_bool.should be_true
      calls = dry.calls.select(&.starts_with?("instance admin-"))
      calls.size.should eq(2)
      calls.first.should start_with("instance admin-add garde nouveau@garde.fr")
      calls.last.should contain("admin-remove garde patron@garde.fr --removal demote")
      report["result"]["removed"].should eq("patron@garde.fr")
      dry.admins["partiduo_adm_garde"].should eq(["nouveau@garde.fr"])
    end
  end

  it "retire un administrateur, et rend le refus de l'instance pour le dernier" do
    with_admin do |admin|
      report, dry = run(admin, 952_i64, "instance.admin_remove", params(email: "patron@garde.fr", removal: "revoke"),
        admins: ["patron@garde.fr", "gerante@garde.fr"])
      report["ok"].as_bool.should be_true
      dry.calls.find!(&.starts_with?("instance admin-remove")).should contain("--removal revoke")
      report["result"]["remaining_admins"].should eq(1)

      report, _ = run(admin, 953_i64, "instance.admin_remove", params(email: "patron@garde.fr", removal: "revoke"))
      report["ok"].as_bool.should be_false
      report.to_json.should contain("instance.admin_remove.last")
      report, dry = run(admin, 954_i64, "instance.admin_remove", params(email: "patron@garde.fr", removal: "effacer"))
      report["ok"].as_bool.should be_false
      dry.calls.none?(&.starts_with?("instance admin-remove")).should be_true
    end
  end

  it "relit la liste des administrateurs" do
    with_admin do |admin|
      report, _ = run(admin, 955_i64, "instance.admins", params, admins: ["patron@garde.fr", "gerante@garde.fr"])
      report["ok"].as_bool.should be_true
      report["result"]["admins"].as_a.map(&.["email"].as_s).should eq(["patron@garde.fr", "gerante@garde.fr"])
    end
  end

  it "refuse avant tout geste une instance au contrat antérieur à 1.4.0 (paquet à mettre à jour)" do
    with_admin do |admin|
      %w[instance.admins instance.admin_add instance.admin_remove].each_with_index do |kind, index|
        report, dry = run(admin, 960_i64 + index, kind, params(email: "x@garde.fr", removal: "revoke"), contract: "1.3.0")
        report["ok"].as_bool.should be_false
        report.to_json.should contain("exigent le contrat 1.4.0")
        dry.calls.none?(&.starts_with?("instance admin")).should be_true
      end
    end
  end

  it "laisse passer les nouvelles actions par l'enveloppe d'instance de production" do
    script = File.read(File.expand_path("../../deploy/libexec/partiduo-agent-instance", __DIR__))
    %w[admins admin-add admin-remove].each { |action| script.should contain(" #{action} ") }
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.routes.draw do
  path "/", PartiduoAdmin::DashboardHandler, name: "dashboard"

  # Authentification (ADR-002, ADR-008 D2).
  path "/login", PartiduoAdmin::LoginHandler, name: "login"
  path "/login/second-factor", PartiduoAdmin::SecondFactorHandler, name: "second_factor"
  path "/login/passkey/options", PartiduoAdmin::PasskeyLoginOptionsHandler, name: "login_passkey_options"
  path "/login/passkey", PartiduoAdmin::PasskeyLoginHandler, name: "login_passkey"
  path "/logout", PartiduoAdmin::LogoutHandler, name: "logout"
  path "/invitation/<token:str>", PartiduoAdmin::InvitationHandler, name: "invitation"
  path "/invitation/<token:str>/connect", PartiduoAdmin::InvitationConnectHandler, name: "invitation_connect"
  # connect (ADR-012 D4).
  path "/login/connect", PartiduoAdmin::ConnectLoginHandler, name: "login_connect"
  path "/login/connect/callback", PartiduoAdmin::ConnectCallbackHandler, name: "login_connect_callback"
  path "/login/connect/backchannel-logout", PartiduoAdmin::ConnectBackchannelHandler, name: "login_connect_logout"
  path "/language", PartiduoAdmin::LanguageHandler, name: "language"
  path "/licences", PartiduoAdmin::LicencesHandler, name: "licences"
  path "/account", PartiduoAdmin::AccountHandler, name: "account"
  path "/account/password", PartiduoAdmin::AccountPasswordHandler, name: "account_password"
  path "/account/totp", PartiduoAdmin::AccountTotpHandler, name: "account_totp"
  path "/account/recovery-codes", PartiduoAdmin::RecoveryCodesHandler, name: "account_recovery_codes"
  path "/account/passkey/options", PartiduoAdmin::PasskeyRegisterOptionsHandler, name: "passkey_register_options"
  path "/account/passkey", PartiduoAdmin::PasskeyRegisterHandler, name: "passkey_register"
  path "/account/elevate/options", PartiduoAdmin::ElevateOptionsHandler, name: "elevate_options"
  path "/account/elevate", PartiduoAdmin::ElevateHandler, name: "elevate"

  # Dossiers (ADR-008 D3, D5).
  path "/dossiers", PartiduoAdmin::DossiersHandler, name: "dossiers"
  path "/dossiers/new", PartiduoAdmin::DossierNewHandler, name: "dossier_new"
  path "/dossiers/<id:int>", PartiduoAdmin::DossierHandler, name: "dossier"
  path "/dossiers/<id:int>/modules", PartiduoAdmin::DossierModulesHandler, name: "dossier_modules"
  path "/dossiers/<id:int>/actions/<action:str>", PartiduoAdmin::DossierActionHandler, name: "dossier_action"
  path "/dossiers/<id:int>/restore", PartiduoAdmin::DossierRestoreHandler, name: "dossier_restore"
  path "/dossiers/<id:int>/move", PartiduoAdmin::DossierMoveHandler, name: "dossier_move"
  path "/dossiers/<id:int>/requests/<kind:str>", PartiduoAdmin::DossierApprovalRequestHandler, name: "dossier_request"
  path "/dossiers/<id:int>/assign", PartiduoAdmin::DossierAssignHandler, name: "dossier_assign"
  path "/dossiers/<id:int>/encryption", PartiduoAdmin::DossierEncryptionHandler, name: "dossier_encryption"
  # Administrateurs d'un dossier (D-ADM-017).
  path "/dossiers/<id:int>/admins", PartiduoAdmin::DossierAdminsHandler, name: "dossier_admins"
  path "/dossiers/<id:int>/admins/<command:str>", PartiduoAdmin::DossierAdminCommandHandler, name: "dossier_admin_command"
  path "/backups/<id:int>/test", PartiduoAdmin::BackupTestHandler, name: "backup_test"
  path "/backups/<id:int>/unlock", PartiduoAdmin::BackupUnlockHandler, name: "backup_unlock"
  path "/backups/<id:int>/capsule", PartiduoAdmin::BackupCapsuleHandler, name: "backup_capsule"
  path "/approvals", PartiduoAdmin::ApprovalsHandler, name: "approvals"
  path "/approvals/<id:int>/confirm", PartiduoAdmin::ApprovalConfirmHandler, name: "approval_confirm"
  path "/approvals/<id:int>/<decision:str>", PartiduoAdmin::ApprovalDecisionHandler, name: "approval_decision"
  path "/reauth/totp", PartiduoAdmin::ReauthTotpHandler, name: "reauth_totp"
  path "/tasks", PartiduoAdmin::TasksHandler, name: "tasks"
  path "/tasks/<id:int>", PartiduoAdmin::TaskHandler, name: "task"
  path "/tasks/<id:int>/<command:str>", PartiduoAdmin::TaskCommandHandler, name: "task_command"
  path "/alerts", PartiduoAdmin::AlertsHandler, name: "alerts"
  path "/alerts/<id:int>/close", PartiduoAdmin::AlertCloseHandler, name: "alert_close"
  path "/audit", PartiduoAdmin::AuditHandler, name: "audit"

  # Assistants des parcours courants (D-ADM-018).
  path "/wizards", PartiduoAdmin::WizardsHandler, name: "wizards"
  path "/wizards/<kind:str>", PartiduoAdmin::WizardHandler, name: "wizard"

  # Référentiels.
  path "/payers", PartiduoAdmin::PayersHandler, name: "payers"
  path "/payers/new", PartiduoAdmin::PayerFormHandler, name: "payer_new"
  path "/payers/dossiers", PartiduoAdmin::PayerDossiersHandler, name: "payer_dossiers"
  path "/payers/<id:int>/edit", PartiduoAdmin::PayerFormHandler, name: "payer_edit"
  path "/firms", PartiduoAdmin::FirmsHandler, name: "firms"
  path "/firms/<id:int>/backups", PartiduoAdmin::FirmBackupsHandler, name: "firm_backups"
  path "/firms/<id:int>/backups/key", PartiduoAdmin::FirmBackupKeyHandler, name: "firm_backup_key"
  path "/firms/<id:int>/approval-mode", PartiduoAdmin::FirmApprovalModeHandler, name: "firm_approval_mode"
  # Fiche d'une structure : activité et nature (D-ADM-026).
  path "/firms/<id:int>/settings", PartiduoAdmin::FirmSettingsHandler, name: "firm_settings"
  # Administrateurs d'une structure (D-ADM-017).
  path "/firms/<id:int>/admins", PartiduoAdmin::FirmAdminsHandler, name: "firm_admins"
  path "/firms/<id:int>/admins/<user_id:int>/<command:str>", PartiduoAdmin::FirmAdminCommandHandler, name: "firm_admin_command"
  path "/users", PartiduoAdmin::UsersHandler, name: "users"
  path "/users/new", PartiduoAdmin::UserNewHandler, name: "user_new"
  path "/users/<id:int>/<command:str>", PartiduoAdmin::UserCommandHandler, name: "user_command"
  path "/servers", PartiduoAdmin::ServersHandler, name: "servers"
  path "/servers/<id:int>/rotate", PartiduoAdmin::ServerRotateHandler, name: "server_rotate"
  path "/servers/<id:int>/signing-keys", PartiduoAdmin::ServerSigningKeyHandler, name: "server_signing_key"
  path "/servers/<id:int>/signing-keys/<key_id:int>/revoke", PartiduoAdmin::ServerSigningKeyRevokeHandler, name: "server_signing_key_revoke"

  # API de l'exécutant (ADR-008 D4).
  path "/api/agent/v1/claim", PartiduoAdmin::AgentClaimHandler, name: "agent_claim"
  path "/api/agent/v1/tasks/<id:int>/log", PartiduoAdmin::AgentLogHandler, name: "agent_log"
  path "/api/agent/v1/tasks/<id:int>/finish", PartiduoAdmin::AgentFinishHandler, name: "agent_finish"

  # Fichiers statiques : servis depuis l'application en développement et en
  # test ; en production, après `collectassets`, par Marten::Middleware::AssetServing.
  if Marten.env.development? || Marten.env.test?
    path "#{Marten.settings.assets.url}<path:path>", Marten::Handlers::Defaults::Development::ServeAsset, name: "asset"
  end
end

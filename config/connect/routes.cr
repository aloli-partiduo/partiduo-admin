# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.routes.draw do
  path "/", PartiduoConnect::HomeHandler, name: "home"

  # OpenID Connect (ADR-012 D3).
  path "/.well-known/openid-configuration", PartiduoConnect::DiscoveryHandler, name: "discovery"
  path "/jwks.json", PartiduoConnect::JwksHandler, name: "jwks"
  path "/authorize", PartiduoConnect::AuthorizeHandler, name: "authorize"
  path "/token", PartiduoConnect::TokenHandler, name: "token"
  path "/userinfo", PartiduoConnect::UserinfoHandler, name: "userinfo"
  path "/logout", PartiduoConnect::LogoutHandler, name: "logout"
  path "/step-up", PartiduoConnect::StepUpHandler, name: "step_up"

  # Connexion (ADR-002).
  path "/login", PartiduoConnect::LoginHandler, name: "login"
  path "/login/second-factor", PartiduoConnect::SecondFactorHandler, name: "second_factor"
  path "/login/passkey/options", PartiduoConnect::PasskeyLoginOptionsHandler, name: "login_passkey_options"
  path "/login/passkey", PartiduoConnect::PasskeyLoginHandler, name: "login_passkey"
  path "/language", PartiduoConnect::LanguageHandler, name: "language"
  path "/licences", PartiduoConnect::LicencesHandler, name: "licences"

  # Relais de l'authentification d'un cabinet (ADR-012 D9).
  path "/login/sso", PartiduoConnect::SsoStartHandler, name: "login_sso"
  path "/login/sso/<code:str>/callback", PartiduoConnect::SsoCallbackHandler, name: "login_sso_callback"
  path "/login/sso/<code:str>/backchannel-logout", PartiduoConnect::SsoBackchannelHandler, name: "login_sso_logout"

  # Création d'un compte (ADR-012 D6).
  path "/signup/<token:str>", PartiduoConnect::SignupHandler, name: "signup"
  path "/api/v1/signup-tickets", PartiduoConnect::SignupTicketHandler, name: "api_signup_tickets"
  path "/api/v1/clients", PartiduoConnect::RegistrarClientHandler, name: "api_clients"

  # Compte.
  path "/account", PartiduoConnect::AccountHandler, name: "account"
  path "/account/continue", PartiduoConnect::ContinueHandler, name: "account_continue"
  path "/account/profile", PartiduoConnect::AccountProfileHandler, name: "account_profile"
  path "/account/password", PartiduoConnect::AccountPasswordHandler, name: "account_password"
  path "/account/totp", PartiduoConnect::AccountTotpHandler, name: "account_totp"
  path "/account/recovery-codes", PartiduoConnect::RecoveryCodesHandler, name: "account_recovery_codes"
  path "/account/passkey/options", PartiduoConnect::PasskeyRegisterOptionsHandler, name: "passkey_register_options"
  path "/account/passkey", PartiduoConnect::PasskeyRegisterHandler, name: "passkey_register"
  path "/account/passkeys/<id:int>/delete", PartiduoConnect::PasskeyDeleteHandler, name: "passkey_delete"
  path "/account/elevate/options", PartiduoConnect::ElevateOptionsHandler, name: "elevate_options"
  path "/account/elevate", PartiduoConnect::ElevateHandler, name: "elevate"
  path "/account/email", PartiduoConnect::AccountEmailHandler, name: "account_email"
  path "/account/email/<token:str>", PartiduoConnect::AccountEmailConfirmHandler, name: "account_email_confirm"

  if Marten.env.development? || Marten.env.test?
    path "#{Marten.settings.assets.url}<path:path>", Marten::Handlers::Defaults::Development::ServeAsset, name: "asset"
  end
end

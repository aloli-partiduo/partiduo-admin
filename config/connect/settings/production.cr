# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :production do |config|
  config.debug = false
  config.secret_key = ENV.fetch("MARTEN_SECRET_KEY")
  config.host = "127.0.0.1"
  config.port = PartiduoConnect::Config.port

  # Derrière le serveur mandataire de `connect.<domaine>`, qui termine TLS
  # et pose `X-Forwarded-Proto`.
  config.use_x_forwarded_proto = true
  config.sessions.cookie_secure = true
  config.sessions.cookie_http_only = true
  config.csrf.cookie_secure = true
  config.csrf.cookie_http_only = true
  config.templates.cached = true
  # Avis et liens par le compte SMTP de Partiduo (PARTIDUO_CONNECT_SMTP_URL,
  # marten-mail) : jamais par le relais du serveur.
  config.emailing.backend = PartiduoConnect::MailBackend.build

  # Gabarits, traductions et fichiers statiques collectés par le paquet
  # dans `share/partiduo-connect/` (même principe que l'administration).
  share = Process.executable_path.try { |path| File.expand_path(File.join(File.dirname(path), "..", "share", "partiduo-connect")) }

  artifacts = ENV["PARTIDUO_CONNECT_ARTIFACTS_ROOT"]? || share.try { |dir| File.join(dir, "artifacts") }
  config.root_path = artifacts if artifacts && Dir.exists?(artifacts)

  config.assets.root = ENV["PARTIDUO_CONNECT_ASSETS_ROOT"]? ||
                       share.try { |dir| File.join(dir, "assets") }.try { |dir| Dir.exists?(dir) ? dir : nil } ||
                       "assets"
  config.middleware = [Marten::Middleware::AssetServing] + config.middleware
end

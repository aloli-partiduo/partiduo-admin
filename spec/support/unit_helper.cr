# SPDX-License-Identifier: AGPL-3.0-or-later

# Specs sans base ni réseau (chiffrement des sauvegardes, stockage) :
# lançables seules, sans PostgreSQL ni administration simulée,
# `crystal spec spec/agent/backup_crypto_spec.cr` ; requise aussi, sans
# effet, par `spec_helper` (`support/**`).
require "spec"
require "../../src/agent/lib"
require "./keys"

module AdminSpec
  # Emplacement d'un fichier de sauvegarde, valide (sinon la spec échoue).
  def self.locator(value : String) : PartiduoAgent::Locator
    PartiduoAgent::Locator.parse?(value) || raise "emplacement refusé : #{value}"
  end

  # Ligne `allowed_signers` d'un serveur, d'après la clé publique de
  # signature qu'un exécutant rend avec une sauvegarde.
  def self.signer(server : String, public_line : String) : String
    key = PartiduoAdmin::BackupCrypto::Signature.normalize(public_line) || raise "clé de signature illisible : #{public_line}"
    PartiduoAdmin::BackupCrypto::Signature.allowed_signer(server, key)
  end
end

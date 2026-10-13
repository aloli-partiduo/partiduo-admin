# SPDX-License-Identifier: AGPL-3.0-or-later

# Chiffrement des sauvegardes (DECISIONS D-CHF-013 à D-CHF-025) : le format
# vit dans le shard partiduo-backup, partagé avec la commande partiduo de
# partiduo-dist (dossiers locaux) ; l'exécutant et l'administration
# l'appellent ici `BackupCrypto`.
require "partiduo-backup"

module PartiduoAdmin
  alias BackupCrypto = PartiduoBackup::Crypto
end

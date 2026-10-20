# SPDX-License-Identifier: AGPL-3.0-or-later

require "html"
require "./qr_code"

module PartiduoAdmin
  module Qr
    # Dessin SVG d'un `QrCode`, avec la zone de silence de quatre modules.
    # Noir sur blanc quel que soit le thème : les lecteurs l'exigent. Même
    # rendu que `PartiduoUi::QrSvg` de partiduo-ui-bulma (classe `pd-qr`).
    module Svg
      QUIET_ZONE = 4

      def self.render(qr : QrCode, label : String) : String
        side = qr.size + 2 * QUIET_ZONE
        path = String.build do |io|
          qr.modules.each_with_index do |row, y|
            row.each_with_index do |dark, x|
              io << 'M' << (x + QUIET_ZONE) << ' ' << (y + QUIET_ZONE) << "h1v1h-1z" if dark
            end
          end
        end
        %(<svg class="pd-qr" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{side} #{side}" role="img" ) +
          %(aria-label="#{HTML.escape(label)}" shape-rendering="crispEdges">) +
          %(<rect width="#{side}" height="#{side}" fill="#fff"/><path fill="#000" d="#{path}"/></svg>)
      end

      # URI `otpauth://` d'un enrôlement, dessinée et prête pour un gabarit.
      def self.enrollment(uri : String, label : String) : Marten::Template::SafeString
        Marten::Template::SafeString.new(render(QrCode.encode(uri), label))
      end

      # Secret base32 par groupes de quatre caractères, pour la saisie manuelle.
      def self.group(secret : String) : String
        secret.chars.each_slice(4).map(&.join).join(' ')
      end
    end
  end
end

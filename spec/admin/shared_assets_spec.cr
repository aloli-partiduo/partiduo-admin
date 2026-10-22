# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "digest/sha256"

# Pages d'accès communes avec partiduo-ui-bulma, interface de référence :
# ces fichiers en sont des copies octet pour octet (pas de dépendance de
# l'administration vers l'interface), vérifiées par les mêmes empreintes que
# dans son `spec/ui/shared_assets_spec.cr`. Ne pas les modifier ici :
# modifier partiduo-ui-bulma, recopier, puis mettre à jour l'empreinte dans
# les deux specs.
private SHARED_ASSETS = {
  "css/theme.css"        => "78f0c25498197e16a3bb2ff62fcbf13ca8e263cc6dbaebe823799e59b074b5f2",
  "css/access.css"       => "7dd4e486308843f0cbfe8ff66867aa92df3e13cbe563dd15311dc8ecf5e19ab5",
  "css/bulma.min.css"    => "67fa26df1ca9e95d8f2adc7c04fa1b15fa3d24257470ebc10cc68b9aab914bee",
  "css/fonts.css"        => "28df0b5dad4409d1418e5b85a8c66d213cb8b7d38ccf01580017fac9d1967a1b",
  "icons/sprite.svg"     => "7e1ea6fe359c74727610d12f8c6d42877196bd987304c528b60054583a94277d",
  "brand/logo.svg"       => "5363f214ca835500e709a9385be2a544504aabd5f419d4fa73f26341a8426d49",
  "brand/aloli-logo.svg" => "b4860a1ff076eefaf1762a74ba3366ede980728c04a8216d2248f2ad75b8d042",
}

private ASSETS = File.join(__DIR__, "../../src/admin/assets/admin")

describe "Fichiers communs avec partiduo-ui-bulma (pages d'accès)" do
  SHARED_ASSETS.each do |file, digest|
    it "garde #{file} identique à celui de partiduo-ui-bulma (empreinte SHA-256)" do
      Digest::SHA256.hexdigest(File.read(File.join(ASSETS, file))).should eq(digest)
    end
  end

  it "les compare octet pour octet à la copie de travail voisine de partiduo-ui-bulma, si elle est là" do
    ui = File.join(__DIR__, "../../../partiduo-ui-bulma/src/ui/assets/ui")
    next unless Dir.exists?(ui)
    SHARED_ASSETS.each_key do |file|
      {file, File.read(File.join(ASSETS, file))}.should eq({file, File.read(File.join(ui, file))})
    end
  end

  it "sert la feuille commune et la planche d'icônes, chacune avec son type" do
    {"css/access.css" => "text/css", "icons/sprite.svg" => "image/svg+xml", "brand/aloli-logo.svg" => "image/svg+xml"}.each do |file, content_type|
      response = AdminSpec::Browser.new.get("/assets/admin/#{file}")
      response.status.should eq(200), file
      response.content_type.should contain(content_type)
      response.content.bytesize.should eq(File.size(File.join(ASSETS, file)))
    end
  end
end

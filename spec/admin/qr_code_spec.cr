# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "digest/sha256"

# Encodeur QR code recopié de partiduo-app (pas de dépendance de
# l'administration vers l'application) : le bloc `class QrCode … end` de
# `src/shared/qr_code.cr` doit rester identique à celui de
# `partiduo-app/src/auth/services/qr_code.cr`. Ne pas le modifier ici :
# modifier partiduo-app, recopier, puis mettre à jour les empreintes.
private QR_CODE_BLOCK_SHA256 = "93fd0be58f2bea9ed69fcb820859eda13c898e02bd788025edbb46adbd939b87"

# URI d'enrôlement réelle de l'administration (émetteur « Partiduo
# administration ») et empreinte de la matrice (`QrCode#to_s`) qu'en tire
# l'encodeur de partiduo-app : version 10, masque 2.
private QR_URI    = "otpauth://totp/Partiduo%20administration:claire.expert%40cabinet-comptable.example?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Partiduo%20administration&algorithm=SHA1&digits=6&period=30"
private QR_MATRIX = "81fb6fec49d2ccab7573243a2500b707f1aec6604b1dc70333457c1108199567"

private def qr_code_class_block(source : String) : String
  start = source.index!("\n    class QrCode\n") + 1
  finish = source.index!("\n    end\n", start) + "\n    end\n".size
  source[start...finish]
end

private def qr_copy : String
  File.read(File.join(__DIR__, "../../src/shared/qr_code.cr"))
end

describe PartiduoAdmin::Qr::QrCode do
  it "garde le bloc de l'encodeur identique à celui de partiduo-app (empreinte SHA-256)" do
    Digest::SHA256.hexdigest(qr_code_class_block(qr_copy)).should eq(QR_CODE_BLOCK_SHA256)
  end

  it "le compare à la copie de travail voisine de partiduo-app, si elle est là" do
    source = File.join(__DIR__, "../../../partiduo-app/src/auth/services/qr_code.cr")
    next unless File.exists?(source)
    qr_code_class_block(qr_copy).should eq(qr_code_class_block(File.read(source)))
  end

  it "produit pour une URI otpauth:// réelle la même matrice que la source" do
    qr = PartiduoAdmin::Qr::QrCode.encode(QR_URI)
    {qr.version, qr.mask}.should eq({10, 2})
    Digest::SHA256.hexdigest(qr.to_s).should eq(QR_MATRIX)
  end

  it "refuse un contenu trop long" do
    expect_raises(PartiduoAdmin::Qr::QrCode::TooLong) { PartiduoAdmin::Qr::QrCode.encode("x" * 413) }
  end
end

describe PartiduoAdmin::Qr::Svg do
  it "dessine noir sur blanc, zone de silence de quatre modules, avec un libellé" do
    qr = PartiduoAdmin::Qr::QrCode.encode(QR_URI)
    svg = PartiduoAdmin::Qr::Svg.render(qr, %(QR code « test » & <libellé>))
    side = qr.size + 8
    svg.should start_with(%(<svg class="pd-qr" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{side} #{side}" role="img" ))
    svg.should contain(%(aria-label="QR code « test » &amp; &lt;libellé&gt;"))
    svg.should contain(%(<rect width="#{side}" height="#{side}" fill="#fff"/><path fill="#000" d="M4 4h1v1h-1z))
    svg.scan(/M(\d+) (\d+)h1v1h-1z/).size.should eq(qr.to_s.count('#'))
  end

  it "groupe le secret par quatre caractères" do
    PartiduoAdmin::Qr::Svg.group("JBSWY3DPEHPK3PXPAB").should eq("JBSW Y3DP EHPK 3PXP AB")
  end
end

describe "Enrôlement de l'application d'authentification (page du compte)" do
  it "affiche le QR code de l'URI otpauth://, puis le secret groupé" do
    user = AdminSpec.user(totp: false)
    browser = AdminSpec::Browser.new
    browser.post("/login", {"email" => user.email.to_s, "password" => AdminSpec::PASSWORD, "next" => "/"})
    browser.post("/account/totp", {"command" => "begin"})
    secret = user.reload.totp_pending_secret.to_s
    response = browser.get("/account")
    html = response.html

    qr = html.index!(%(<svg class="pd-qr" ))
    html.should contain(%(<figure class="pd-qr-box"><svg class="pd-qr" ))
    html.should contain(%(aria-label="#{I18n.t("admin.account.totp_qr_label")}"))
    grouped = PartiduoAdmin::Qr::Svg.group(secret)
    grouped.should contain(' ')
    html.index!(%(<code>#{grouped}</code>)).should be > qr
    html.should_not contain("otpauth://")

    uri = PartiduoAdmin::Auth::Totp.provisioning_uri(user, secret)
    # Contenu brut : `html` décode les entités, l'apostrophe du libellé comprise.
    response.content.should contain(PartiduoAdmin::Qr::Svg.render(PartiduoAdmin::Qr::QrCode.encode(uri), I18n.t("admin.account.totp_qr_label")))
  end
end

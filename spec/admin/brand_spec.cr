# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "json"

# Identité visuelle (partiduo-docs/identite) : favicons, manifeste web,
# couleur du navigateur, marque de la barre et des pages d'accès.

private BRAND = File.join(__DIR__, "../../src/admin/assets/admin/brand")

private def check_head(html : String) : Nil
  html.should contain(%(<link rel="icon" href="/assets/admin/brand/favicon.ico" sizes="32x32">))
  html.should contain(%(<link rel="icon" href="/assets/admin/brand/favicon.svg" type="image/svg+xml">))
  html.should contain(%(<link rel="apple-touch-icon" href="/assets/admin/brand/apple-touch-icon.png">))
  html.should contain(%(<link rel="manifest" href="/assets/admin/brand/manifest.webmanifest">))
  html.should contain(%(<meta name="theme-color" content="#0f5d70" media="(prefers-color-scheme: light)">))
  html.should_not contain(%(href="data:,"))
end

# Le symbole est décoratif (alt vide) : le nom, en texte, nomme la marque une
# seule fois pour les lecteurs d'écran ; la mention de l'administration suit.
private def check_auth_brand(html : String) : Nil
  check_head(html)
  brand = html.match!(/<div class="pd-auth-brand">.*?<\/div>/m)[0]
  brand.should contain(%(<img class="pd-logo" src="/assets/admin/brand/logo.svg" alt="" width="56" height="56">))
  brand.should contain(%(<b class="pd-name">Parti<span>duo</span></b><small>administration des dossiers</small>))
  html.index!(brand).should be > html.index!(%(<header class="pd-auth-top">))
  html.index!(brand).should be < html.index!(%(<main class="pd-auth"))
end

describe "Identité visuelle de l'administration" do
  it "sert les favicons, les icônes et le manifeste, chacun avec son type" do
    {
      "favicon.svg"          => "image/svg+xml",
      "favicon.ico"          => "image/x-icon",
      "apple-touch-icon.png" => "image/png",
      "icon-192.png"         => "image/png",
      "icon-512.png"         => "image/png",
      "logo.svg"             => "image/svg+xml",
      "manifest.webmanifest" => "application/manifest+json",
    }.each do |file, content_type|
      response = AdminSpec::Browser.new.get("/assets/admin/brand/#{file}")
      response.status.should eq(200), file
      response.content_type.should contain(content_type)
      response.content.bytesize.should eq(File.size(File.join(BRAND, file)))
    end
  end

  it "décrit la console dans le manifeste web, avec des icônes présentes" do
    manifest = JSON.parse(File.read(File.join(BRAND, "manifest.webmanifest")))
    manifest["name"].as_s.should eq("Partiduo Administration")
    manifest["icons"].as_a.each do |icon|
      File.exists?(File.join(BRAND, icon["src"].as_s)).should be_true
    end
  end

  it "centre le logo, le nom et la mention en haut de la page de connexion" do
    check_auth_brand(AdminSpec::Browser.new.get("/login").html)
  end

  it "pose favicons et marque dans la barre, lien vers l'accueil, et sur les pages d'erreur" do
    root = AdminSpec.super_admin
    browser = AdminSpec::Browser.new(token: AdminSpec.session(root))
    html = browser.get("/account").html
    check_head(html)
    html.should contain(%(<a class="pd-brand" href="/"><img class="pd-logo" src="/assets/admin/brand/favicon.svg" alt="" width="32" height="32"><b class="pd-name">Parti<span>duo</span></b><small>administration des dossiers</small></a>))

    # Page d'erreur (403 ou 404 selon le niveau de la session) : même en-tête
    # que la connexion.
    refused = browser.get("/dossiers/999999")
    {403, 404}.should contain(refused.status)
    check_auth_brand(refused.html)
  end
end

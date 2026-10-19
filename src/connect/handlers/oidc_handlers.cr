# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoConnect
  class DiscoveryHandler < ApiHandler
    def get
      response = json(Oidc.discovery)
      response.headers["Cache-Control"] = "public, max-age=3600"
      response
    end
  end

  # Clés publiques : relues par les clients au plus toutes les heures, ce
  # qui fixe le délai entre la publication d'une clé et son usage.
  class JwksHandler < ApiHandler
    def get
      response = json(SigningKeys.jwks)
      response.headers["Cache-Control"] = "public, max-age=3600"
      response
    end
  end

  # Point d'autorisation : valide la demande, fait passer par la connexion
  # ou l'élévation s'il le faut, puis renvoie un code au client.
  class AuthorizeHandler < BaseHandler
    def get
      values = query_hash
      request_ = begin
        Oidc.parse(values)
      rescue error : Oidc::AuthorizeError
        return error.redirectable ? redirect(Oidc.error_redirect(values, error)) : error_page(400, "connect.errors.oidc.#{error.code}")
      end
      session = session_record
      now = Config.now
      if session.nil? || Oidc.needs_login?(request_, session, now)
        if request_.prompt.includes?("none")
          return redirect(Oidc.error_redirect(values, Oidc::AuthorizeError.new("login_required")))
        end
        # Sans `prompt=login` au retour : la connexion vient d'avoir lieu.
        retry = values.reject { |key, _| key == "prompt" || key == "max_age" }
        login = "/login?next=#{URI.encode_www_form(authorize_path(retry))}"
        login += "&login_hint=#{URI.encode_www_form(request_.login_hint)}" unless request_.login_hint.empty?
        return redirect(login)
      end
      here = authorize_path(values)
      unless elevated?
        return redirect(Oidc.error_redirect(values, Oidc::AuthorizeError.new("interaction_required"))) if request_.prompt.includes?("none")
        return redirect("/account?next=#{URI.encode_www_form(here)}")
      end
      if level < request_.acr
        return redirect(Oidc.error_redirect(values, Oidc::AuthorizeError.new("interaction_required"))) if request_.prompt.includes?("none")
        return redirect("/step-up?acr=#{request_.acr}&next=#{URI.encode_www_form(here)}")
      end
      redirect(Oidc.issue_code(request_, session, now))
    end

    private def authorize_path(values : Hash(String, String)) : String
      "/authorize?#{URI::Params.encode(values)}"
    end
  end

  class TokenHandler < ApiHandler
    def post
      client = Oidc.authenticate_client(request.headers["Authorization"]?, form)
      no_store(json(Oidc.exchange(client, form, Config.now)))
    rescue error : Oidc::TokenError
      response = json({"error" => error.code, "error_description" => error.message}.to_json, status: error.status)
      response.headers["WWW-Authenticate"] = %(Basic realm="#{Config.host}") if error.status == 401
      no_store(response)
    end
  end

  class UserinfoHandler < ApiHandler
    def get
      answer
    end

    def post
      answer
    end

    private def answer
      if body = Oidc.userinfo(request.headers["Authorization"]?, Config.now)
        no_store(json(body))
      else
        response = json({"error" => "invalid_token"}.to_json, status: 401)
        response.headers["WWW-Authenticate"] = %(Bearer error="invalid_token")
        no_store(response)
      end
    end
  end

  # Invitation à créer un compte, demandée par un client (dossier,
  # administration ; ADR-012 D6) authentifié par son secret. Rend le lien et
  # le code, ou `account: true` si l'adresse a déjà un compte (le client
  # invite alors à se connecter).
  class SignupTicketHandler < ApiHandler
    def post
      values = form
      client = Oidc.authenticate_client(request.headers["Authorization"]?, values)
      issued = Signup.issue(values["email"]? || "", values["name"]? || "", values["locale"]? || "fr", client,
        values["return_to"]? || "", values["by"]? || client.name.to_s, Config.now)
      no_store(json({"account" => false, "url" => issued.url, "code" => issued.code,
                     "expires_at" => issued.ticket.expires_at.try(&.to_rfc3339)}.to_json))
    rescue error : Oidc::TokenError
      no_store(json({"error" => error.code}.to_json, status: error.status))
    rescue error : Signup::Error
      return no_store(json({"account" => true}.to_json)) if error.key == "connect.errors.signup.exists"
      no_store(json({"error" => "invalid_request", "error_description" => error.key}.to_json, status: 400))
    end
  end
end

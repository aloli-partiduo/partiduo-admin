# SPDX-License-Identifier: AGPL-3.0-or-later

module ConnectSpec
  ORIGIN = "http://connect.partiduo.localhost:8300"

  # Navigateur de test : garde les cookies d'une requête à l'autre, envoie
  # les formulaires encodés comme un navigateur.
  class Browser
    FORM = "application/x-www-form-urlencoded"

    getter jar = {} of String => String
    getter headers = {} of String => String

    def initialize(locale : String = "fr")
      @headers["Accept-Language"] = locale
      @headers["Host"] = "127.0.0.1"
    end

    def get(path : String, headers = {} of String => String) : Marten::HTTP::Response
      perform { |client| client.get(path, headers: @headers.merge(headers)) }
    end

    def post(path : String, data = {} of String => String, headers = {} of String => String) : Marten::HTTP::Response
      body = URI::Params.build { |form| data.each { |key, value| form.add(key, value) } }
      perform { |client| client.post(path, data: body, content_type: FORM, headers: @headers.merge(headers)) }
    end

    # Corps déjà encodé (champs répétés, formulaires relevés par
    # spec/support/translations.cr).
    def perform_raw(path : String, body : String, headers = {} of String => String) : Marten::HTTP::Response
      perform { |client| client.post(path, data: body, content_type: FORM, headers: @headers.merge(headers)) }
    end

    def cookie(name : String) : String?
      @jar[name]?
    end

    private def perform(& : Marten::Spec::Client -> Marten::HTTP::Response) : Marten::HTTP::Response
      client = Marten::Spec::Client.new
      @jar.each { |name, value| client.cookies[name] = value }
      response = yield client
      client.cookies.each do |(name, value)|
        value.empty? ? @jar.delete(name) : (@jar[name] = value)
      end
      response
    end
  end
end

class Marten::HTTP::Response
  def html : String
    HTML.unescape(content)
  end

  def location : String
    headers["Location"]? || ""
  end
end

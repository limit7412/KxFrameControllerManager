require "http/server"
require "log"
require "uri"
require "../config/models"
require "./usecase"

module WebUI
  # 設定画面の HTTP サーバー。
  #
  # 127.0.0.1 だけで待ち受け、認証は持たない。そのため、ヘッドセットの中で動く別のページから
  # 操作されないよう、次の 2 つで要求を絞る。
  #
  # - Host がループバックの名前とこのポートであること。DNS rebinding で外のページが
  #   127.0.0.1 へ届いても、Host は外の名前のままなので弾ける
  # - /api/ への要求に X-KxFCM ヘッダーが付いていること。別のオリジンのページがこのヘッダーを付けると
  #   ブラウザは事前の確認（preflight）を送る。ここは CORS に応えないため、本番の要求は送られない
  class Server
    Log = ::Log.for("web_ui")

    HTML = {{ read_file("#{__DIR__}/assets/index.html") }}

    # 画面が /api/ への要求に付けるヘッダー。
    REQUEST_HEADER = "X-KxFCM"

    # 要求の本文の上限。画面が送るのは設定の一部だけで、数百バイトに収まる。
    MAX_BODY = 64 * 1024

    LOOPBACK_HOSTS = %w[127.0.0.1 localhost [::1]]

    # 待ち受けているポート。止まっていれば nil。
    getter port : Int32? = nil

    def initialize(@usecase : Usecase, @host : String = "127.0.0.1")
      @server = nil.as(HTTP::Server?)
      @section = nil.as(Config::UISection?)
    end

    def running? : Bool
      !@server.nil?
    end

    # 設定を受け取り、変わっていれば待ち受けを止めて開き直す。
    def apply(section : Config::UISection) : Nil
      previous = @section
      return if previous && previous.enabled == section.enabled && previous.port == section.port && running? == section.enabled
      @section = section

      stop
      start(section.port) if section.enabled
    end

    # 待ち受けを始める。port に 0 を渡すと空いているポートを使う（spec 用）。
    # 開けなくても例外にはしない。設定画面が使えないだけで、長押しの切断は続ける。
    def start(port : Int32) : Bool
      server = HTTP::Server.new { |context| handle(context) }
      address = server.bind_tcp(@host, port)
      @server = server
      @port = address.port
      # listen が走る前に stop されることがある。閉じたサーバーの listen は例外になるため確かめる。
      spawn(name: "web_ui") { server.listen unless server.closed? }
      Log.info { "設定画面を開いた: http://#{@host}:#{address.port}/" }
      true
    rescue exception : Socket::Error
      Log.error(exception: exception) { "設定画面のポート #{port} を開けなかった" }
      false
    end

    def stop : Nil
      if server = @server
        server.close
        Log.info { "設定画面を閉じた" }
      end
      @server = nil
      @port = nil
    end

    # 1 件の要求を処理する。
    def handle(context : HTTP::Server::Context) : Nil
      request = context.request
      response = context.response
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"

      unless allowed_host?(request.headers["Host"]?)
        return reply(response, 421, {errors: ["Host が許されていない"]}.to_json)
      end

      path = request.path
      if path == "/" || path == "/index.html"
        return reply(response, 405, "") unless request.method == "GET"
        response.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        response.headers["X-Frame-Options"] = "DENY"
        response.content_type = "text/html; charset=utf-8"
        response.print HTML
        return
      end

      return reply(response, 404, {errors: ["見つからない"]}.to_json) unless path.starts_with?("/api/")

      unless request.headers[REQUEST_HEADER]? == "1"
        return reply(response, 403, {errors: ["#{REQUEST_HEADER} ヘッダーが無い"]}.to_json)
      end
      unless allowed_origin?(request.headers["Origin"]?, request.headers["Host"]?)
        return reply(response, 403, {errors: ["Origin が許されていない"]}.to_json)
      end

      result = route(request.method, path, request)
      reply(response, result.status, result.body)
    rescue exception
      Log.error(exception: exception) { "設定画面の要求の処理に失敗した" }
      reply(context.response, 500, {errors: ["内部の誤り"]}.to_json)
    end

    private def route(method : String, path : String, request : HTTP::Request) : Response
      case {method, path}
      when {"GET", "/api/state"}       then @usecase.state
      when {"GET", "/api/config"}      then @usecase.config
      when {"PUT", "/api/config"}      then with_body(request) { |body| @usecase.save(body) }
      when {"POST", "/api/disconnect"} then with_body(request) { |body| @usecase.disconnect(body) }
      when {"GET", "/api/controllers"} then @usecase.controllers
      else
        Response.new(404, {errors: ["見つからない"]}.to_json)
      end
    end

    # 本文を読んで渡す。JSON 以外と、上限を超えるものは読まずに断る。
    private def with_body(request : HTTP::Request, & : String -> Response) : Response
      unless request.headers["Content-Type"]?.try(&.starts_with?("application/json"))
        return Response.new(415, {errors: ["Content-Type は application/json にする"]}.to_json)
      end
      io = request.body
      return Response.new(400, {errors: ["本文が無い"]}.to_json) unless io

      body = String.build { |buffer| IO.copy(io, buffer, MAX_BODY + 1) }
      return Response.new(413, {errors: ["本文が大きすぎる"]}.to_json) if body.bytesize > MAX_BODY
      yield body
    end

    private def reply(response : HTTP::Server::Response, status : Int32, body : String) : Nil
      response.status_code = status
      response.content_type = "application/json; charset=utf-8" unless body.empty?
      response.print body
    end

    # Host がループバックの名前と、待ち受けているポートか。
    private def allowed_host?(host : String?) : Bool
      return false unless host && (port = @port)
      name, _, port_text = host.rpartition(':')
      return false if name.empty?
      LOOPBACK_HOSTS.includes?(name.downcase) && port_text == port.to_s
    end

    # Origin が付いていれば、Host と同じオリジンか。付いていなければ通す（同じオリジンの GET など）。
    private def allowed_origin?(origin : String?, host : String?) : Bool
      return true if origin.nil?
      origin == "http://#{host}"
    end
  end
end

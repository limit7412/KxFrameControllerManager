require "../spec_helper"
require "http/client"
require "../../src/web_ui/server"

private def start_server : {WebUI::Server, Config::Usecase, Int32}
  repository = Fakes::ConfigRepository.new(%({}))
  config = Config::Usecase.new(repository)
  config.load
  usecase = WebUI::Usecase.new(config)
  usecase.status = -> do
    WebUI::Snapshot.new(
      version: "1.2.3", locale: "en", steamvr_connected: false,
      hands: {"left" => WebUI::HandStatus.new(false, nil, "view"), "right" => WebUI::HandStatus.new(false, nil, "menu")},
      link_reachable: false, power_save_state: "idle", power_save_pending: false, gain_range: nil, busy: false,
      config_errors: [] of String,
    )
  end
  server = WebUI::Server.new(usecase)
  server.start(0).should be_true
  {server, config, server.port.not_nil!}
end

private def request(port : Int32, method : String, path : String, headers = {} of String => String, body : String? = nil) : HTTP::Client::Response
  client = HTTP::Client.new("127.0.0.1", port)
  http_headers = HTTP::Headers{"Host" => "127.0.0.1:#{port}"}
  headers.each { |key, value| http_headers[key] = value }
  client.exec(method, path, http_headers, body)
ensure
  client.try(&.close)
end

private def api_headers(port : Int32) : Hash(String, String)
  {"X-KxFCM" => "1", "Content-Type" => "application/json", "Origin" => "http://127.0.0.1:#{port}"}
end

describe WebUI::Server do
  it "画面を返す" do
    server, _, port = start_server
    begin
      response = request(port, "GET", "/")
      response.status_code.should eq 200
      response.headers["Content-Type"].should start_with "text/html"
      response.headers["Content-Security-Policy"].should contain "frame-ancestors 'none'"
      response.body.should contain "KxFrameControllerManager"
    ensure
      server.stop
    end
  end

  it "localhost の名前でも開ける" do
    server, _, port = start_server
    begin
      request(port, "GET", "/", {"Host" => "localhost:#{port}"}).status_code.should eq 200
    ensure
      server.stop
    end
  end

  it "ループバック以外の Host は断る（DNS rebinding）" do
    server, _, port = start_server
    begin
      request(port, "GET", "/", {"Host" => "evil.example:#{port}"}).status_code.should eq 421
      request(port, "GET", "/api/state", {"Host" => "evil.example:#{port}", "X-KxFCM" => "1"}).status_code.should eq 421
      request(port, "GET", "/", {"Host" => "127.0.0.1:1"}).status_code.should eq 421
    ensure
      server.stop
    end
  end

  it "X-KxFCM ヘッダーの無い /api/ は断る" do
    server, _, port = start_server
    begin
      request(port, "GET", "/api/state").status_code.should eq 403
    ensure
      server.stop
    end
  end

  it "別のオリジンからの /api/ は断る" do
    server, config, port = start_server
    begin
      headers = api_headers(port)
      headers["Origin"] = "http://evil.example"
      request(port, "PUT", "/api/config", headers, %({"power_off": {"hold_ms": 4000}})).status_code.should eq 403
      config.current.power_off.hold_ms.should eq 2000
    ensure
      server.stop
    end
  end

  it "状態を返し、設定を保存する" do
    server, config, port = start_server
    begin
      state = request(port, "GET", "/api/state", api_headers(port))
      state.status_code.should eq 200
      JSON.parse(state.body)["version"].should eq "1.2.3"

      saved = request(port, "PUT", "/api/config", api_headers(port), %({"power_off": {"hold_ms": 4000}}))
      saved.status_code.should eq 200
      config.current.power_off.hold_ms.should eq 4000
    ensure
      server.stop
    end
  end

  it "JSON 以外の本文は読まずに断る" do
    server, config, port = start_server
    begin
      headers = api_headers(port)
      headers["Content-Type"] = "text/plain"
      request(port, "PUT", "/api/config", headers, %({"power_off": {"hold_ms": 4000}})).status_code.should eq 415
      config.current.power_off.hold_ms.should eq 2000
    ensure
      server.stop
    end
  end

  it "大きすぎる本文は断る" do
    server, _, port = start_server
    begin
      body = %({"power_off": {"target": "#{"a" * (WebUI::Server::MAX_BODY + 10)}"}})
      request(port, "PUT", "/api/config", api_headers(port), body).status_code.should eq 413
    ensure
      server.stop
    end
  end

  it "知らない道筋とメソッドは 404 を返す" do
    server, _, port = start_server
    begin
      request(port, "GET", "/missing").status_code.should eq 404
      request(port, "DELETE", "/api/config", api_headers(port)).status_code.should eq 404
    ensure
      server.stop
    end
  end

  it "#apply は無効にすると閉じ、ポートを変えると開き直す" do
    usecase = WebUI::Usecase.new(Config::Usecase.new(Fakes::ConfigRepository.new(%({}))))
    server = WebUI::Server.new(usecase)
    section = Config::UISection.new
    section.port = 0
    server.apply(section)
    server.running?.should be_true

    disabled = Config::UISection.new
    disabled.enabled = false
    server.apply(disabled)
    server.running?.should be_false
    server.port.should be_nil
  end
end

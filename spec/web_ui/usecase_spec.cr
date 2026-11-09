require "../spec_helper"
require "../../src/web_ui/usecase"

private def snapshot : WebUI::Snapshot
  WebUI::Snapshot.new(
    version: "1.2.3",
    locale: "ja",
    steamvr_connected: true,
    hands: {"left" => WebUI::HandStatus.new(true, "cv.aaaaaaaaaaaa", "view"), "right" => WebUI::HandStatus.new(false, nil, "menu")},
    link_reachable: nil,
    power_save_state: "idle",
    power_save_pending: false,
    gain_range: [0.5, 1.6],
    busy: false,
    config_errors: [] of String,
  )
end

private def build(json : String? = %({})) : {WebUI::Usecase, Config::Usecase, Fakes::ConfigRepository}
  repository = Fakes::ConfigRepository.new(json)
  config = Config::Usecase.new(repository)
  config.load
  usecase = WebUI::Usecase.new(config)
  usecase.status = -> { snapshot }
  usecase.buttons = {"left" => %w[view bumper], "right" => %w[menu a]}
  {usecase, config, repository}
end

private def result(hand : PowerOff::Hand, outcome : PowerOff::Outcome) : PowerOff::Result
  PowerOff::Result.new(PowerOff::Target.new(hand, "#{hand.label}serial"), outcome)
end

describe WebUI::Usecase do
  it "#state は状態を JSON で返す" do
    usecase, _, _ = build
    response = usecase.state
    response.status.should eq 200
    data = JSON.parse(response.body)
    data["version"].should eq "1.2.3"
    data["hands"]["left"]["serial"].should eq "cv.aaaaaaaaaaaa"
    data["hands"]["right"]["serial"].raw.should be_nil
    data["link_reachable"].raw.should be_nil
    data["gain_range"].should eq [0.5, 1.6]
  end

  it "#config は画面が扱う項目と選べるボタンを返す" do
    usecase, _, _ = build(%({"power_off": {"hold_ms": 3000}}))
    data = JSON.parse(usecase.config.body)
    data["config"]["power_off"]["hold_ms"].should eq 3000
    data["buttons"]["right"].should eq %w[menu a]
  end

  describe "#save" do
    it "検証を通れば保存して反映し、新しい値を返す" do
      usecase, config, repository = build
      applied = [] of Config::Root
      config.on_apply = ->(root : Config::Root) { applied << root; nil }

      response = usecase.save(%({"power_off": {"hold_ms": 4000, "warn_ms": 2000}}))

      response.status.should eq 200
      JSON.parse(response.body)["config"]["power_off"]["hold_ms"].should eq 4000
      config.current.power_off.hold_ms.should eq 4000
      Config::Root.from_json(repository.stored.not_nil!).power_off.warn_ms.should eq 2000
      applied.size.should eq 1
    end

    it "検証を通らなければ保存せず、誤りを返す" do
      usecase, config, repository = build
      before = repository.save_count

      response = usecase.save(%({"power_off": {"hold_ms": 1200, "warn_ms": 1000}}))

      response.status.should eq 422
      JSON.parse(response.body)["errors"].as_a.map(&.as_s).should contain "power_off: hold_ms と warn_ms の差は 500 以上で指定する"
      config.current.power_off.hold_ms.should eq 2000
      repository.save_count.should eq before
    end

    it "登録された検証も通す" do
      usecase, config, _ = build
      config.register_validator("input") { |root| root.input.left_button == "view" ? [] of String : ["left_button が違う"] }

      usecase.save(%({"input": {"left_button": "a"}})).status.should eq 422
      config.current.input.left_button.should eq "view"
    end

    it "画面から変えられない項目と壊れた JSON は 400 を返す" do
      usecase, _, _ = build
      usecase.save(%({"update": {"channel": "test"}})).status.should eq 400
      usecase.save(%({"power_off": )).status.should eq 400
    end
  end

  describe "#disconnect" do
    it "対象の手を渡し、結末を返す" do
      usecase, _, _ = build
      received = [] of Array(PowerOff::Hand)
      usecase.disconnect = ->(hands : Array(PowerOff::Hand)) do
        received << hands
        hands.map { |hand| result(hand, PowerOff::Outcome::Disconnected) }.as(Array(PowerOff::Result)?)
      end

      response = usecase.disconnect(%({"target": "both"}))

      response.status.should eq 200
      received.should eq [[PowerOff::Hand::Left, PowerOff::Hand::Right]]
      results = JSON.parse(response.body)["results"].as_a
      results.map(&.["target"].as_s).should eq %w[left right]
      results.map(&.["outcome"].as_s).should eq %w[disconnected disconnected]
    end

    it "結末の綴りは画面の辞書のキーと同じにする" do
      usecase, _, _ = build
      usecase.disconnect = ->(hands : Array(PowerOff::Hand)) { [result(hands.first, PowerOff::Outcome::SendFailed)].as(Array(PowerOff::Result)?) }
      JSON.parse(usecase.disconnect(%({"target": "left"})).body)["results"][0]["outcome"].should eq "send_failed"
    end

    it "処理中なら 409 を返す" do
      usecase, _, _ = build
      usecase.disconnect = ->(_hands : Array(PowerOff::Hand)) { nil.as(Array(PowerOff::Result)?) }
      usecase.disconnect(%({"target": "left"})).status.should eq 409
    end

    it "知らない対象は渡さずに 400 を返す" do
      usecase, _, _ = build
      called = false
      usecase.disconnect = ->(_hands : Array(PowerOff::Hand)) { called = true; nil.as(Array(PowerOff::Result)?) }
      usecase.disconnect(%({"target": "cv.aaaaaaaaaaaa"})).status.should eq 400
      usecase.disconnect(%({})).status.should eq 400
      called.should be_false
    end
  end

  describe "#controllers" do
    it "接続中とペアリング済みを分けて返す" do
      usecase, _, _ = build
      usecase.controllers = -> do
        PowerOff::ControllerList.new([PowerOff::LinkedController.new("aaaa", PowerOff::Hand::Left)], ["aaaa", "bbbb"]).as(PowerOff::ControllerList?)
      end
      data = JSON.parse(usecase.controllers.body)
      data["connected"][0]["hand"].should eq "left"
      data["paired"].should eq ["bbbb"]
    end

    it "27062 に届かなければ 502 を返す" do
      usecase, _, _ = build
      usecase.controllers.status.should eq 502
    end
  end
end

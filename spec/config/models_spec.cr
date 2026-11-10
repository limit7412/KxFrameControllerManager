require "../spec_helper"

describe Config::Root do
  # 無いキーは既定値で埋める（仕様書 6.1 節）。
  # 利用者が一部だけを書いた設定ファイルでも、残りは既定のまま動く。
  it "空の設定は既定値で埋まる" do
    root = Config::Root.from_json("{}")

    root.power_off.enabled.should be_true
    root.power_off.target.should eq Config::PowerOffTarget::Pressed
    root.power_off.hold_ms.should eq 2000
    root.power_off.warn_ms.should eq 1000
    root.power_off.cooldown_ms.should eq 3000
    root.power_off.confirm_timeout_ms.should eq 3000
    root.power_save.enabled.should be_false
    root.power_save.brightness.should be_false
    root.power_save.delay_s.should eq 10
    root.power_save.brightness_gain.should be_nil
    root.input.priority.should eq Config::InputPriority::Normal
    root.input.poll_interval_ms.should eq 20
    root.feedback.haptics.should be_true
    root.feedback.amplitude.should eq 0.5
    root.steamvr.openvr_library_path.should eq ""
    root.steamvr.retry_interval_s.should eq 10
    root.frame_link.port.should eq 27062
    root.update.check_enabled.should be_true
    root.update.channel.should eq "stable"
    root.update.auto_update.should be_true
    root.update.check_interval_h.should eq 6
    root.log_level.should eq "info"
    root.language.should eq "auto"
  end

  it "セクションの一部だけを書いても残りは既定値になる" do
    root = Config::Root.from_json(%({"power_off": {"hold_ms": 3000}}))

    root.power_off.hold_ms.should eq 3000
    root.power_off.warn_ms.should eq 1000
    root.power_off.enabled.should be_true
  end

  # 列挙は仕様書の綴り（小文字とアンダースコア）で読み書きする。
  it "列挙を仕様書の綴りで読み書きする" do
    root = Config::Root.from_json(%({"power_off": {"target": "both"}, "input": {"priority": "overlay_global"}}))

    root.power_off.target.should eq Config::PowerOffTarget::Both
    root.input.priority.should eq Config::InputPriority::OverlayGlobal

    json = JSON.parse(root.to_json)
    json["power_off"]["target"].as_s.should eq "both"
    json["input"]["priority"].as_s.should eq "overlay_global"
  end

  it "知らない列挙の値は読み込みで失敗する" do
    expect_raises(JSON::ParseException) do
      Config::Root.from_json(%({"power_off": {"target": "left"}}))
    end
  end

  # 省くと、設定ファイルを開いた利用者が brightness_gain の存在に気付けない。
  it "brightness_gain は null でも書き出す" do
    json = JSON.parse(Config::Root.default.to_json)

    json["power_save"].as_h.has_key?("brightness_gain").should be_true
    json["power_save"]["brightness_gain"].raw.should be_nil
  end

  it "書き出したものを読み戻すと同じ内容になる" do
    root = Config::Root.from_json(%({"power_save": {"brightness_gain": 0.4}, "log_level": "debug"}))

    Config::Root.from_json(root.to_json).to_json.should eq root.to_json
  end

  it "dup_snapshot は元を共有しない" do
    root = Config::Root.default
    copy = root.dup_snapshot
    copy.power_off.hold_ms = 5000

    root.power_off.hold_ms.should eq 2000
  end
end

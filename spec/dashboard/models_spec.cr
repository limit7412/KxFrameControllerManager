require "../spec_helper"
require "../../src/update/auto_updater"

private BUTTONS = {
  PowerOff::Hand::Left  => SteamVR::Bindings::LEFT_BUTTONS,
  PowerOff::Hand::Right => SteamVR::Bindings::RIGHT_BUTTONS,
}

private def apply(root : Config::Root, key : String, direction = 1, gain_range = nil) : Config::Root
  Dashboard::Editor.apply(root, key, direction, BUTTONS, gain_range, Runtime::I18n.settings)
end

describe Dashboard::Editor do
  it "切り替えの項目は押すたびに反転し、元の設定は書き換えない" do
    root = Config::Root.default
    changed = apply(root, "power_off.enabled")
    changed.power_off.enabled.should be_false
    root.power_off.enabled.should be_true
    apply(changed, "power_off.enabled").power_off.enabled.should be_true
  end

  it "ボタンはその手で選べるものを順に回す" do
    root = Config::Root.default
    apply(root, "input.left_button").input.left_button.should eq "dpad_up"
    apply(root, "input.left_button", -1).input.left_button.should eq "thumbstick"
    apply(root, "input.right_button").input.right_button.should eq "a"
  end

  it "切る範囲と優先度は値を順に回す" do
    root = Config::Root.default
    apply(root, "power_off.target").power_off.target.should eq Config::PowerOffTarget::Both
    apply(root, "input.priority", -1).input.priority.should eq Config::InputPriority::OverlayGlobal
  end

  it "数値は幅ずつ増減し、範囲の外へ出さない" do
    root = Config::Root.default
    apply(root, "power_off.cooldown_ms").power_off.cooldown_ms.should eq 3500
    root.power_off.cooldown_ms = 0
    apply(root, "power_off.cooldown_ms", -1).power_off.cooldown_ms.should eq 0
    root.feedback.amplitude = 1.0
    apply(root, "feedback.amplitude").feedback.amplitude.should eq 1.0
  end

  it "振動の強さに端数を残さない" do
    root = Config::Root.default
    root.feedback.amplitude = 0.25
    apply(root, "feedback.amplitude").feedback.amplitude.should eq 0.3
  end

  it "切断までを縮めて予告との間が 500 ms を切るなら、予告を早める" do
    root = Config::Root.default
    root.power_off.hold_ms = 1500
    root.power_off.warn_ms = 1000
    changed = apply(root, "power_off.hold_ms", -1)
    changed.power_off.hold_ms.should eq 1400
    changed.power_off.warn_ms.should eq 900
  end

  it "予告は切断までより 500 ms 以上前に止める" do
    root = Config::Root.default
    root.power_off.warn_ms = 1500
    apply(root, "power_off.warn_ms").power_off.warn_ms.should eq 1500
  end

  it "自動更新の間隔は決まった段を順に動き、段の間の値からは押した向きの段へ移る" do
    root = Config::Root.default
    apply(root, "update.check_interval_h").update.check_interval_h.should eq 12
    apply(root, "update.check_interval_h", -1).update.check_interval_h.should eq 3
    root.update.check_interval_h = 5
    apply(root, "update.check_interval_h").update.check_interval_h.should eq 6
    apply(root, "update.check_interval_h", -1).update.check_interval_h.should eq 3
    root.update.check_interval_h = 168
    apply(root, "update.check_interval_h").update.check_interval_h.should eq 168
    root.update.check_interval_h = 1
    apply(root, "update.check_interval_h", -1).update.check_interval_h.should eq 1
  end

  it "どの操作の結果も config の検証を通る" do
    usecase = Config::Usecase.new(Fakes::ConfigRepository.new)
    usecase.register_validator("update") { |checked| Update.validate(checked.update) }
    usecase.register_validator(Config::ValidationError::GENERAL) { |checked| Runtime::I18n.validate(checked.language) }
    root = Config::Root.default
    root.power_off.hold_ms = 500
    root.power_off.warn_ms = 0
    Dashboard::Editor::FIELDS.each_key do |key|
      [1, -1].each do |direction|
        30.times { root = apply(root, key, direction, {0.5, 1.6}) }
        usecase.validate(root).should be_empty
      end
    end
  end

  it "表示言語は auto から辞書のある言語を順に巡る" do
    root = Config::Root.default
    seen = [] of String
    Runtime::I18n.settings.size.times do
      root = apply(root, "language")
      seen << root.language
    end
    seen.last.should eq "auto"
    seen.sort.should eq Runtime::I18n.settings.sort
    apply(Config::Root.default, "language", -1).language.should eq Runtime::I18n::CODES.last
  end

  describe "明るさ" do
    it "HMD の最小値から上げると最小値の 1 段上になる" do
      root = Config::Root.default
      apply(root, "power_save.brightness_gain", 1, {0.5, 1.6}).power_save.brightness_gain.should eq 0.55
    end

    it "最小値まで下げると HMD の最小値（null）へ戻り、そこからは下がらない" do
      root = Config::Root.default
      root.power_save.brightness_gain = 0.55
      changed = apply(root, "power_save.brightness_gain", -1, {0.5, 1.6})
      changed.power_save.brightness_gain.should be_nil
      apply(changed, "power_save.brightness_gain", -1, {0.5, 1.6}).power_save.brightness_gain.should be_nil
    end

    it "HMD の最大値を超えない" do
      root = Config::Root.default
      root.power_save.brightness_gain = 1.6
      apply(root, "power_save.brightness_gain", 1, {0.5, 1.6}).power_save.brightness_gain.should eq 1.6
    end
  end

  it "知らない項目は断る" do
    expect_raises(ArgumentError) { apply(Config::Root.default, "update.channel") }
  end
end

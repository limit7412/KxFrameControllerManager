require "../spec_helper"
require "../../src/web_ui/models"

describe WebUI do
  describe ".editable" do
    it "画面が扱う項目だけを抜き出す" do
      editable = WebUI.editable(Config::Root.default)
      editable.keys.should eq %w[power_off power_save input feedback]
      editable["power_off"]["hold_ms"].should eq 2000
      editable["power_off"]["target"].should eq "pressed"
      editable["input"]["left_button"].should eq "view"
      editable["power_save"]["brightness_gain"].raw.should be_nil
      editable["power_off"].has_key?("confirm_timeout_ms").should be_false
      editable["input"].has_key?("poll_interval_ms").should be_false
    end
  end

  describe ".merge" do
    it "書かれた項目だけを差し替え、他は元の値を残す" do
      root = Config::Root.default
      root.update.channel = "test"
      patch = JSON.parse(%({"power_off": {"hold_ms": 3000, "target": "both"}, "input": {"right_button": "a"}, "power_save": {"brightness_gain": 0.8}}))

      merged = WebUI.merge(root, patch)

      merged.power_off.hold_ms.should eq 3000
      merged.power_off.target.should eq Config::PowerOffTarget::Both
      merged.power_off.warn_ms.should eq 1000
      merged.input.right_button.should eq "a"
      merged.input.left_button.should eq "view"
      merged.power_save.brightness_gain.should eq 0.8
      merged.update.channel.should eq "test"
      # 元のスナップショットは書き換えない。
      root.power_off.hold_ms.should eq 2000
    end

    it "null で明るさを HMD の最小値へ戻せる" do
      root = Config::Root.default
      root.power_save.brightness_gain = 0.5
      WebUI.merge(root, JSON.parse(%({"power_save": {"brightness_gain": null}}))).power_save.brightness_gain.should be_nil
    end

    it "画面から変えられないセクションと項目は断る" do
      root = Config::Root.default
      expect_raises(WebUI::PatchError, /update/) { WebUI.merge(root, JSON.parse(%({"update": {"channel": "test"}}))) }
      expect_raises(WebUI::PatchError, /ui/) { WebUI.merge(root, JSON.parse(%({"ui": {"port": 1}}))) }
      expect_raises(WebUI::PatchError, /confirm_timeout_ms/) { WebUI.merge(root, JSON.parse(%({"power_off": {"confirm_timeout_ms": 1}}))) }
    end

    it "型の合わない値は断る" do
      root = Config::Root.default
      expect_raises(WebUI::PatchError) { WebUI.merge(root, JSON.parse(%({"power_off": {"hold_ms": "長い"}}))) }
      expect_raises(WebUI::PatchError) { WebUI.merge(root, JSON.parse(%({"power_off": {"target": "left"}}))) }
      expect_raises(WebUI::PatchError) { WebUI.merge(root, JSON.parse(%({"power_off": 1}))) }
      expect_raises(WebUI::PatchError) { WebUI.merge(root, JSON.parse(%([1]))) }
    end
  end
end

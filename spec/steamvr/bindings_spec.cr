require "../spec_helper"
require "../../src/steamvr/bindings"

private TEMPLATE = File.read(File.join(__DIR__, "..", "..", "actions", "bindings_frame_controller.json"))

private def input(left : String, right : String) : Config::InputSection
  section = Config::InputSection.new
  section.left_button = left
  section.right_button = right
  section
end

private def source_paths(json : String) : Array(String)
  JSON.parse(json)["bindings"]["/actions/kxfcm"]["sources"].as_a.map(&.["path"].as_s)
end

describe SteamVR::Bindings do
  it "既定の設定では雛形と同じ入力を書き出す" do
    source_paths(SteamVR::Bindings.render(TEMPLATE, Config::InputSection.new)).should eq [
      "/user/hand/left/input/view",
      "/user/hand/right/input/menu",
    ]
  end

  it "左右のボタンを設定のものへ差し替える" do
    paths = source_paths(SteamVR::Bindings.render(TEMPLATE, input("dpad_down", "b")))
    paths.should eq ["/user/hand/left/input/dpad_down", "/user/hand/right/input/b"]
  end

  it "振動の出力とモードは書き換えない" do
    rendered = JSON.parse(SteamVR::Bindings.render(TEMPLATE, input("bumper", "a")))
    original = JSON.parse(TEMPLATE)
    rendered["bindings"]["/actions/kxfcm"]["haptics"].should eq original["bindings"]["/actions/kxfcm"]["haptics"]
    rendered["bindings"]["/actions/kxfcm"]["sources"].as_a.map(&.["mode"]).should eq original["bindings"]["/actions/kxfcm"]["sources"].as_a.map(&.["mode"])
    rendered["controller_type"].should eq "frame_controller"
  end

  it "その手に無いボタンは雛形のまま残す" do
    # x は右手にしかない。検証を通らない経路でも、左手に x を割り当てたバインドは書き出さない。
    paths = source_paths(SteamVR::Bindings.render(TEMPLATE, input("x", "dpad_up")))
    paths.should eq ["/user/hand/left/input/view", "/user/hand/right/input/menu"]
  end

  it ".validate はその手に無いボタンを誤りにする" do
    SteamVR::Bindings.validate(Config::InputSection.new).should be_empty
    errors = SteamVR::Bindings.validate(input("system", "view"))
    errors.size.should eq 2
    errors[0].should start_with "left_button は view / "
    errors[1].should start_with "right_button は menu / "
  end

  it "Steam ボタンとトリガーとグリップは選べない" do
    {PowerOff::Hand::Left, PowerOff::Hand::Right}.each do |hand|
      buttons = SteamVR::Bindings.buttons(hand)
      buttons.should_not contain "system"
      buttons.should_not contain "trigger"
      buttons.should_not contain "grip"
    end
  end
end

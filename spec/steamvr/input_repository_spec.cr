require "../spec_helper"

private def build
  repository = Fakes::SteamVRRepository.new
  repository.opened = true
  actions = SteamVR::InputActions.new(repository, "/home/deck/actions.json")
  {repository, actions}
end

describe SteamVR::InputActions do
  it "接続ごとに 1 回だけアクションを読ませる" do
    repository, actions = build
    actions.prepare.should be_true
    actions.prepare.should be_true
    repository.manifest_paths.should eq ["/home/deck/actions.json"]

    repository.generation += 1
    actions.prepare.should be_true
    repository.manifest_paths.size.should eq 2
  end

  it "読ませられなければ、間隔が過ぎるまで同じ接続ではやり直さない" do
    repository, actions = build
    actions.retry_interval = 10.seconds
    repository.fail_manifest_path = true
    now = Time.instant
    actions.prepare(now).should be_false
    actions.prepare(now + 20.milliseconds).should be_false
    actions.prepare(now + 9.seconds).should be_false
    repository.manifest_paths.size.should eq 1
  end

  it "間隔が過ぎたら同じ接続でやり直し、読ませられたら入力を読める" do
    repository, actions = build
    actions.retry_interval = 10.seconds
    repository.fail_manifest_path = true
    now = Time.instant
    actions.prepare(now).should be_false

    repository.fail_manifest_path = false
    actions.prepare(now + 10.seconds).should be_true
    repository.manifest_paths.size.should eq 2
    actions.power_off.should eq 2_u64
    actions.source(PowerOff::Hand::Left).should eq 10_u64

    actions.prepare(now + 30.seconds).should be_true
    repository.manifest_paths.size.should eq 2
  end

  it "つながっていない間と、読ませる前の状態を見分ける" do
    repository, actions = build
    actions.state.should eq PowerOff::Detection::Pending
    repository.manifest_paths.should be_empty

    repository.opened = false
    actions.state.should eq PowerOff::Detection::NotConnected
  end

  it "読ませられたか、失敗してやり直しているかを状態で見せる" do
    repository, actions = build
    actions.retry_interval = 10.seconds
    repository.fail_manifest_path = true
    now = Time.instant
    actions.prepare(now)
    actions.state.should eq PowerOff::Detection::Failed
    actions.prepare(now + 5.seconds)
    actions.state.should eq PowerOff::Detection::Failed

    repository.fail_manifest_path = false
    actions.prepare(now + 10.seconds)
    actions.state.should eq PowerOff::Detection::Ready
  end

  it "つなぎ直した後は、読ませ直すまで読ませた状態にしない" do
    repository, actions = build
    actions.prepare
    actions.state.should eq PowerOff::Detection::Ready

    repository.generation += 1
    actions.state.should eq PowerOff::Detection::Pending
  end

  it "SteamVR Input を使えなければ、その状態を見せる" do
    repository, actions = build
    repository.input_available = false
    actions.prepare.should be_false
    actions.state.should eq PowerOff::Detection::Unavailable
  end

  it "失敗が続く間は、間隔ごとに 1 回ずつやり直す" do
    repository, actions = build
    actions.retry_interval = 10.seconds
    repository.fail_manifest_path = true
    now = Time.instant
    actions.prepare(now).should be_false
    actions.prepare(now + 10.seconds).should be_false
    actions.prepare(now + 15.seconds).should be_false
    actions.prepare(now + 20.seconds).should be_false
    repository.manifest_paths.size.should eq 3
  end

  it "失敗した後につなぎ直したら、間隔を待たずに読ませる" do
    repository, actions = build
    actions.retry_interval = 10.seconds
    repository.fail_manifest_path = true
    now = Time.instant
    actions.prepare(now).should be_false

    repository.fail_manifest_path = false
    repository.generation += 1
    actions.prepare(now + 20.milliseconds).should be_true
    repository.manifest_paths.size.should eq 2
  end

  it "overlay_global を k_nActionSetOverlayGlobalPriorityMin に直す" do
    _, actions = build
    actions.priority_value.should eq 0
    actions.priority = Config::InputPriority::OverlayGlobal
    actions.priority_value.should eq 0x01000000
  end
end

describe SteamVR::InputRepository do
  it "手の入力ソースで片手ずつ読む" do
    repository, actions = build
    input = SteamVR::InputRepository.new(repository, actions)
    repository.digital[10_u64] = true
    repository.digital[11_u64] = nil

    input.ready?.should be_true
    input.update.should be_true
    input.pressed?(PowerOff::Hand::Left).should be_true
    input.pressed?(PowerOff::Hand::Right).should be_false
    repository.update_calls.should eq [{1_u64, 0}]
  end

  it "UpdateActionState が失敗したら押されていないとみなす" do
    repository, actions = build
    input = SteamVR::InputRepository.new(repository, actions)
    repository.digital[10_u64] = true
    input.ready?
    repository.fail_update = true
    input.update.should be_false
    input.pressed?(PowerOff::Hand::Left).should be_false
  end
end

describe SteamVR::HapticRepository do
  it "その手の入力ソースに限って振動させる" do
    repository, actions = build
    haptics = SteamVR::HapticRepository.new(repository, actions)
    haptics.vibrate(PowerOff::Hand::Right, 0.15, 0.06, 0.5)
    repository.haptics.should eq [{3_u64, 0.15_f32, 0.06_f32, 0.5_f32, 11_u64}]
  end
end

describe SteamVR::DeviceRepository do
  it "役割からデバイス番号とシリアルを引く" do
    repository, _ = build
    repository.roles[SteamVR::LibOpenVR::CONTROLLER_ROLE_LEFT_HAND] = 3_u32
    repository.connected_devices << 3_u32
    repository.string_properties[{3_u32, SteamVR::LibOpenVR::PROP_SERIAL_NUMBER_STRING}] = "cv.91481bedcdfa"
    devices = SteamVR::DeviceRepository.new(repository)

    devices.device_index(PowerOff::Hand::Left).should eq 3_u32
    devices.connected?(PowerOff::Hand::Left).should be_true
    devices.serial(PowerOff::Hand::Left).should eq "cv.91481bedcdfa"
    devices.connected?(PowerOff::Hand::Right).should be_false
    devices.serial(PowerOff::Hand::Right).should be_nil
  end
end

describe SteamVR::SettingsRepository do
  it "既定値も無い未設定と、読み出しの失敗を読み分ける" do
    repository, _ = build
    repository.float_settings["steamvr/analogGain"] = {1.3_f32, 0}
    repository.float_settings["steamvr/broken"] = {0.0_f32, 3}
    settings = SteamVR::SettingsRepository.new(repository)

    settings.read_float("steamvr", "analogGain").status.should eq PowerSave::ReadStatus::Value
    settings.read_float("steamvr", "missing").status.should eq PowerSave::ReadStatus::Unset
    settings.read_float("steamvr", "broken").status.should eq PowerSave::ReadStatus::Failed
  end

  it "HMD が analogGain に対応しているときだけ範囲を返す" do
    repository, _ = build
    settings = SteamVR::SettingsRepository.new(repository)
    settings.gain_range.should be_nil

    hmd = SteamVR::LibOpenVR::TRACKED_DEVICE_INDEX_HMD
    repository.bool_properties[{hmd, SteamVR::LibOpenVR::PROP_DISPLAY_SUPPORTS_ANALOG_GAIN_BOOL}] = true
    repository.float_properties[{hmd, SteamVR::LibOpenVR::PROP_DISPLAY_MIN_ANALOG_GAIN_FLOAT}] = 0.25_f32
    repository.float_properties[{hmd, SteamVR::LibOpenVR::PROP_DISPLAY_MAX_ANALOG_GAIN_FLOAT}] = 1.5_f32
    settings.gain_range.should eq({0.25, 1.5})
  end
end

describe "SteamVR::LibOpenVR" do
  it "構造体の大きさが openvr_capi.h と合う" do
    sizeof(SteamVR::LibOpenVR::InputDigitalActionData).should eq 24
    sizeof(SteamVR::LibOpenVR::VRActiveActionSet).should eq 32
    sizeof(SteamVR::LibOpenVR::IVRInputFnTable).should eq 34 * sizeof(Void*)
    sizeof(SteamVR::LibOpenVR::IVRSettingsFnTable).should eq 11 * sizeof(Void*)
  end
end

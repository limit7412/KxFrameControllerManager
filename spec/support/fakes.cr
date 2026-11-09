require "json"
require "../../src/config/repository"
require "../../src/steamvr/repository"
require "../../src/steamvr/ffi"
require "../../src/power_off/repository"
require "../../src/power_save/repository"
require "../../src/dashboard/canvas"
require "../../src/dashboard/view"

# 外部境界のテスト用実装。
# usecase をファイルにも OpenVR にも触れずに確かめるために差し替える。
module Fakes
  # ファイルを持たない Config::Repository 実装。
  class ConfigRepository < Config::Repository
    property stored : String?
    property save_count : Int32 = 0
    # load が失敗する状況を真似る。
    property unreadable : Bool = false

    def initialize(@stored : String? = nil)
    end

    def path : String
      "(memory)"
    end

    def exists? : Bool
      !@stored.nil?
    end

    def load : Config::Root
      raise JSON::ParseException.new("壊れている", 1, 1) if @unreadable
      Config::Root.from_json(@stored || "{}")
    end

    def save(root : Config::Root) : Nil
      @stored = root.to_json
      @save_count += 1
    end
  end

  class SteamVRRepository < SteamVR::Repository
    property opened : Bool = false
    # 真にすると open が失敗する。SteamVR が動いていない状況を真似る。
    property unavailable : Bool = false
    property open_count : Int32 = 0
    property added_manifests : Array(String) = [] of String
    property removed_manifests : Array(String) = [] of String
    property acknowledged : Bool = false
    property fail_add : Bool = false
    property fail_remove : Bool = false
    # 次の poll_events で返すイベント。返したら空にする。
    property pending_events : Array(SteamVR::Event) = [] of SteamVR::Event

    def open : Bool
      @open_count += 1
      return false if @unavailable
      @opened = true
    end

    def close : Nil
      @opened = false
    end

    def opened? : Bool
      @opened
    end

    def add_application_manifest(manifest_path : String) : Bool
      return false if @fail_add
      @added_manifests << manifest_path
      true
    end

    def remove_application_manifest(manifest_path : String) : Bool
      return false if @fail_remove
      @removed_manifests << manifest_path
      true
    end

    def poll_events : Array(SteamVR::Event)
      events = @pending_events
      @pending_events = [] of SteamVR::Event
      events
    end

    def acknowledge_quit : Nil
      @acknowledged = true
    end

    # イベントを 1 件積む。
    def push(kind : SteamVR::EventKind, device_index : UInt32 = 0_u32) : Nil
      @pending_events << SteamVR::Event.new(kind, 0_u32, device_index)
    end

    # --- 入力 ---
    property generation : Int32 = 1
    property input_available : Bool = true
    property settings_available : Bool = true
    property manifest_paths : Array(String) = [] of String
    property fail_manifest_path : Bool = false
    # 名前とハンドルの対応。無い名前は引けない。
    property handles : Hash(String, UInt64) = {
      "/actions/kxfcm"              => 1_u64,
      "/actions/kxfcm/in/power_off" => 2_u64,
      "/actions/kxfcm/out/haptic"   => 3_u64,
      "/user/hand/left"             => 10_u64,
      "/user/hand/right"            => 11_u64,
    }
    property update_calls : Array({UInt64, Int32}) = [] of {UInt64, Int32}
    property fail_update : Bool = false
    # 入力ソースのハンドルごとの押下状態。nil はアクションが有効でない状態を表す。
    property digital : Hash(UInt64, Bool?) = {} of UInt64 => Bool?
    property haptics : Array({UInt64, Float32, Float32, Float32, UInt64}) = [] of {UInt64, Float32, Float32, Float32, UInt64}

    def input_available? : Bool
      @opened && @input_available
    end

    def settings_available? : Bool
      @opened && @settings_available
    end

    def set_action_manifest_path(path : String) : Bool
      @manifest_paths << path
      !@fail_manifest_path
    end

    def action_set_handle(name : String) : UInt64?
      @handles[name]?
    end

    def action_handle(name : String) : UInt64?
      @handles[name]?
    end

    def input_source_handle(path : String) : UInt64?
      @handles[path]?
    end

    def update_action_state(action_set : UInt64, priority : Int32) : Bool
      @update_calls << {action_set, priority}
      !@fail_update
    end

    def digital_action_state(action : UInt64, restrict_to : UInt64) : Bool?
      @digital[restrict_to]?
    end

    def trigger_haptic(action : UInt64, start_s : Float32, duration_s : Float32, frequency : Float32, amplitude : Float32, restrict_to : UInt64) : Bool
      @haptics << {action, start_s, duration_s, amplitude, restrict_to}
      true
    end

    # --- デバイス ---
    property roles : Hash(Int32, UInt32) = {} of Int32 => UInt32
    property connected_devices : Set(UInt32) = Set(UInt32).new
    property string_properties : Hash({UInt32, Int32}, String) = {} of {UInt32, Int32} => String
    property float_properties : Hash({UInt32, Int32}, Float32) = {} of {UInt32, Int32} => Float32
    property bool_properties : Hash({UInt32, Int32}, Bool) = {} of {UInt32, Int32} => Bool

    def controller_index(role : Int32) : UInt32?
      @roles[role]?
    end

    def device_connected?(index : UInt32) : Bool
      @connected_devices.includes?(index)
    end

    def string_property(index : UInt32, property : Int32) : String?
      @string_properties[{index, property}]?
    end

    def float_property(index : UInt32, property : Int32) : Float32?
      @float_properties[{index, property}]?
    end

    def bool_property(index : UInt32, property : Int32) : Bool?
      @bool_properties[{index, property}]?
    end

    # --- 設定値 ---
    property float_settings : Hash(String, {Float32, Int32}) = {} of String => {Float32, Int32}
    property string_settings : Hash(String, {String, Int32}) = {} of String => {String, Int32}
    property removed_settings : Array(String) = [] of String

    def get_float_setting(section : String, key : String) : {Float32, Int32}
      @float_settings["#{section}/#{key}"]? || {0.0_f32, 5}
    end

    def get_string_setting(section : String, key : String) : {String, Int32}
      @string_settings["#{section}/#{key}"]? || {"", 5}
    end

    def set_float_setting(section : String, key : String, value : Float32) : Int32
      @float_settings["#{section}/#{key}"] = {value, 0}
      0
    end

    def set_string_setting(section : String, key : String, value : String) : Int32
      @string_settings["#{section}/#{key}"] = {value, 0}
      0
    end

    def remove_setting(section : String, key : String) : Int32
      @removed_settings << "#{section}/#{key}"
      @float_settings.delete("#{section}/#{key}")
      @string_settings.delete("#{section}/#{key}")
      0
    end
  end

  # power_off の外部境界のテスト用実装。
  class Input < PowerOff::InputRepository
    property ready : Bool = true
    property pressed : Hash(PowerOff::Hand, Bool) = {} of PowerOff::Hand => Bool

    def ready? : Bool
      @ready
    end

    def update : Bool
      @ready
    end

    def pressed?(hand : PowerOff::Hand) : Bool
      @pressed[hand]? || false
    end
  end

  class Haptics < PowerOff::HapticRepository
    getter pulses : Array({PowerOff::Hand, Float64, Float64, Float64}) = [] of {PowerOff::Hand, Float64, Float64, Float64}

    def vibrate(hand : PowerOff::Hand, start_s : Float64, duration_s : Float64, amplitude : Float64) : Nil
      @pulses << {hand, start_s, duration_s, amplitude}
    end
  end

  class Devices < PowerOff::DeviceRepository
    property available : Bool = true
    property indices : Hash(PowerOff::Hand, UInt32) = {PowerOff::Hand::Left => 3_u32, PowerOff::Hand::Right => 4_u32}
    property serials : Hash(PowerOff::Hand, String) = {PowerOff::Hand::Left => "cv.aaaaaaaaaaaa", PowerOff::Hand::Right => "cv.bbbbbbbbbbbb"}
    property connected : Set(PowerOff::Hand) = Set{PowerOff::Hand::Left, PowerOff::Hand::Right}

    def available? : Bool
      @available
    end

    def device_index(hand : PowerOff::Hand) : UInt32?
      @indices[hand]?
    end

    def connected?(hand : PowerOff::Hand) : Bool
      @connected.includes?(hand)
    end

    def serial(hand : PowerOff::Hand) : String?
      @serials[hand]?
    end
  end

  # 27062 の代わり。切断要求を受けると、そのシリアルを接続中から外す。
  class Link < PowerOff::DisconnectRepository
    property list_result : PowerOff::ControllerList? = PowerOff::ControllerList.new(
      [PowerOff::LinkedController.new("aaaaaaaaaaaa", PowerOff::Hand::Left), PowerOff::LinkedController.new("bbbbbbbbbbbb", PowerOff::Hand::Right)],
      ["aaaaaaaaaaaa", "bbbbbbbbbbbb"],
    )
    getter sent : Array(String) = [] of String
    property list_count : Int32 = 0
    property fail_send : Bool = false
    # 真にすると、切断要求を受けても接続中から外さない。切れない状況を作る。
    property ignore_disconnect : Bool = false

    def list : PowerOff::ControllerList?
      @list_count += 1
      @list_result
    end

    def disconnect(serial : String) : Bool
      return false if @fail_send
      @sent << serial
      if !@ignore_disconnect && (current = @list_result)
        @list_result = PowerOff::ControllerList.new(current.connected.reject { |c| c.serial == serial }, current.paired)
      end
      true
    end
  end

  # power_save の外部境界のテスト用実装。
  class Settings < PowerSave::SettingsRepository
    property available : Bool = true
    property floats : Hash(String, Float64) = {} of String => Float64
    property strings : Hash(String, String) = {} of String => String
    # 読めないキー。
    property unreadable : Set(String) = Set(String).new
    # 書けないキー。
    property unwritable : Set(String) = Set(String).new
    property range : {Float64, Float64}? = {0.4, 1.6}
    getter writes : Array(String) = [] of String
    getter removed : Array(String) = [] of String

    def available? : Bool
      @available
    end

    def read_float(section : String, key : String) : PowerSave::FloatReading
      name = "#{section}/#{key}"
      return PowerSave::FloatReading.new(PowerSave::ReadStatus::Failed) if @unreadable.includes?(name)
      value = @floats[name]?
      value ? PowerSave::FloatReading.new(PowerSave::ReadStatus::Value, value) : PowerSave::FloatReading.new(PowerSave::ReadStatus::Unset)
    end

    def read_string(section : String, key : String) : PowerSave::StringReading
      name = "#{section}/#{key}"
      return PowerSave::StringReading.new(PowerSave::ReadStatus::Failed) if @unreadable.includes?(name)
      value = @strings[name]?
      value ? PowerSave::StringReading.new(PowerSave::ReadStatus::Value, value) : PowerSave::StringReading.new(PowerSave::ReadStatus::Unset)
    end

    def write_float(section : String, key : String, value : Float64) : Bool
      name = "#{section}/#{key}"
      return false if @unwritable.includes?(name)
      @writes << name
      @floats[name] = value
      true
    end

    def write_string(section : String, key : String, value : String) : Bool
      name = "#{section}/#{key}"
      return false if @unwritable.includes?(name)
      @writes << name
      @strings[name] = value
      true
    end

    def remove(section : String, key : String) : Bool
      name = "#{section}/#{key}"
      @removed << name
      @floats.delete(name)
      @strings.delete(name)
      true
    end

    def gain_range : {Float64, Float64}?
      @range
    end
  end

  class StateStore < PowerSave::StateRepository
    property saved : PowerSave::SavedState? = nil
    property save_count : Int32 = 0

    def exists? : Bool
      !@saved.nil?
    end

    def load : PowerSave::SavedState
      @saved.not_nil!
    end

    def save(state : PowerSave::SavedState) : Nil
      @save_count += 1
      # ファイルへ書くのと同じく、JSON を経由して複製する。
      @saved = PowerSave::SavedState.from_json(state.to_json)
    end

    def delete : Nil
      @saved = nil
    end
  end

  class ManifestStore < SteamVR::ManifestStore
    property files : Hash(String, String) = {} of String => String
    # 真にすると delete が例外を上げる。ファイルを消せない状況を作る。
    property fail_delete : Bool = false

    def write(path : String, content : String) : Nil
      @files[path] = content
    end

    def delete(path : String) : Nil
      raise File::Error.new("消せなかった", file: path) if @fail_delete
      @files.delete(path)
    end

    def exists?(path : String) : Bool
      @files.has_key?(path)
    end
  end

  # 設定画面のオーバーレイを持つ SteamVR の偽物。
  class OverlayRepository < SteamVRRepository
    property overlay_ok : Bool = true
    property fail_create : Bool = false
    property visible : Bool = true
    property created : Int32 = 0
    property destroyed : Array(UInt64) = [] of UInt64
    property uploads : Array({UInt64, Int32, Int32}) = [] of {UInt64, Int32, Int32}
    # 次の poll_overlay_events で返すイベント。返したら空にする。
    property pending_overlay_events : Array(SteamVR::OverlayEvent) = [] of SteamVR::OverlayEvent

    def initialize
      @opened = true
    end

    def overlay_available? : Bool
      @opened && @overlay_ok
    end

    def create_dashboard_overlay(key : String, name : String) : {UInt64, UInt64}?
      return nil if @fail_create
      @created += 1
      {@created.to_u64 * 10, @created.to_u64 * 10 + 1}
    end

    def destroy_overlay(handle : UInt64) : Nil
      @destroyed << handle
    end

    def configure_overlay(handle : UInt64, width_m : Float32, mouse_width : Int32, mouse_height : Int32) : Bool
      true
    end

    def set_overlay_raw(handle : UInt64, pixels : Bytes, width : Int32, height : Int32) : Bool
      @uploads << {handle, width, height}
      true
    end

    def overlay_visible?(handle : UInt64) : Bool
      @visible
    end

    def poll_overlay_events(handle : UInt64) : Array(SteamVR::OverlayEvent)
      events = @pending_overlay_events
      @pending_overlay_events = [] of SteamVR::OverlayEvent
      events
    end
  end

  # 中身は Dashboard 側に置く。抽象メソッドの既定値（Align::Left）を同じ名前で解決させるためである。
  alias Canvas = Dashboard::FakeCanvas
end

module Dashboard
  # 描いた文字を記録する Canvas。画素は持たない。
  class FakeCanvas < Canvas
    getter texts = [] of String

    def width : Int32
      View::WIDTH
    end

    def height : Int32
      View::HEIGHT
    end

    def clear(color : Color) : Nil
      @texts.clear
    end

    def fill_rect(x : Float64, y : Float64, w : Float64, h : Float64, color : Color, radius : Float64 = 0.0) : Nil
    end

    def stroke_rect(x : Float64, y : Float64, w : Float64, h : Float64, color : Color, radius : Float64 = 0.0, line : Float64 = 2.0) : Nil
    end

    def line(x1 : Float64, y1 : Float64, x2 : Float64, y2 : Float64, color : Color, width : Float64 = 2.0) : Nil
    end

    def arc(cx : Float64, cy : Float64, radius : Float64, from : Float64, to : Float64, color : Color, width : Float64 = 2.0) : Nil
    end

    def text(x : Float64, y : Float64, text : String, size : Float64, color : Color, bold : Bool = false, align : Align = Align::Left) : Nil
      @texts << text
    end

    # 1 字を字の大きさの幅とみなす。
    def text_width(text : String, size : Float64, bold : Bool = false) : Float64
      text.size * size
    end

    def rgba : Bytes
      Bytes.new(width * height * 4)
    end
  end
end

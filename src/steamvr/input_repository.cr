require "../config/models"
require "log"
require "../power_off/repository"
require "./ffi"
require "./repository"

module SteamVR
  # SteamVR Input のアクションとハンドル（仕様書 3.1 節）。
  #
  # 入力と振動は同じアクションマニフェストのハンドルを使うため、ここで 1 回だけ取る。
  # ハンドルは SteamVR を再起動すると無効になる。接続の番号（generation）が変わったら取り直す。
  class InputActions
    Log = ::Log.for("steamvr")

    ACTION_SET   = "/actions/kxfcm"
    POWER_OFF    = "/actions/kxfcm/in/power_off"
    HAPTIC       = "/actions/kxfcm/out/haptic"
    LEFT_SOURCE  = "/user/hand/left"
    RIGHT_SOURCE = "/user/hand/right"

    # 設定 input.priority。
    property priority : Config::InputPriority = Config::InputPriority::Normal

    getter action_set : UInt64 = 0_u64
    getter power_off : UInt64 = 0_u64
    getter haptic : UInt64 = 0_u64

    def initialize(@repository : Repository, @action_manifest_path : String)
      @prepared_generation = nil.as(Int32?)
      @failed_generation = nil.as(Int32?)
      @sources = {} of PowerOff::Hand => UInt64
    end

    # ハンドルを取り終えていれば true を返す。まだなら、ここで取る。
    #
    # 取れなかった接続では、つなぎ直すまでやり直さない。
    # 20 ミリ秒ごとに失敗を繰り返しても、同じ接続の中で結果は変わらない。
    def prepare : Bool
      return false unless @repository.input_available?
      generation = @repository.generation
      return true if @prepared_generation == generation
      return false if @failed_generation == generation

      if fetch
        @prepared_generation = generation
        Log.info { "SteamVR Input のアクションを読ませた: #{@action_manifest_path}" }
        true
      else
        @failed_generation = generation
        Log.error { "SteamVR Input のアクションを読ませられなかったため、長押しを検出しない" }
        false
      end
    end

    def source(hand : PowerOff::Hand) : UInt64
      @sources[hand]? || 0_u64
    end

    # input.priority を OpenVR の優先度の値へ直す。
    def priority_value : Int32
      @priority.overlay_global? ? LibOpenVR::ACTION_SET_OVERLAY_GLOBAL_PRIORITY_MIN : 0
    end

    private def fetch : Bool
      return false unless @repository.set_action_manifest_path(@action_manifest_path)
      action_set = @repository.action_set_handle(ACTION_SET)
      power_off = @repository.action_handle(POWER_OFF)
      haptic = @repository.action_handle(HAPTIC)
      left = @repository.input_source_handle(LEFT_SOURCE)
      right = @repository.input_source_handle(RIGHT_SOURCE)
      return false unless action_set && power_off && haptic && left && right

      @action_set = action_set
      @power_off = power_off
      @haptic = haptic
      @sources = {PowerOff::Hand::Left => left, PowerOff::Hand::Right => right}
      true
    end
  end

  # SteamVR Input で長押しのアクションを読む（仕様書 3.1 節）。
  #
  # 左右の区別は、GetDigitalActionData の restrict に手の入力ソースを渡して片手ずつ読むことで行う。
  class InputRepository < PowerOff::InputRepository
    def initialize(@repository : Repository, @actions : InputActions)
      @pressed = {} of PowerOff::Hand => Bool
    end

    def ready? : Bool
      @repository.opened? && @actions.prepare
    end

    def update : Bool
      @pressed.clear
      return false unless @repository.update_action_state(@actions.action_set, @actions.priority_value)
      PowerOff::Hand.each do |hand|
        @pressed[hand] = @repository.digital_action_state(@actions.power_off, @actions.source(hand)) || false
      end
      true
    end

    def pressed?(hand : PowerOff::Hand) : Bool
      @pressed[hand]? || false
    end
  end

  # SteamVR Input の出力アクションで振動させる（仕様書 3.5 節）。
  class HapticRepository < PowerOff::HapticRepository
    # 振動の周波数。Hz で指定する。
    FREQUENCY = 160.0_f32

    def initialize(@repository : Repository, @actions : InputActions)
    end

    def vibrate(hand : PowerOff::Hand, start_s : Float64, duration_s : Float64, amplitude : Float64) : Nil
      return unless @repository.opened? && @actions.prepare
      @repository.trigger_haptic(@actions.haptic, start_s.to_f32, duration_s.to_f32, FREQUENCY, amplitude.to_f32, @actions.source(hand))
    end
  end
end

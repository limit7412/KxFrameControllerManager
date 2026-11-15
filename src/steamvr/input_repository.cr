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
    # 取れなかったときに、同じ接続の中でやり直す間隔。設定 steamvr.retry_interval_s。
    property retry_interval : Time::Span = 10.seconds

    getter action_set : UInt64 = 0_u64
    getter power_off : UInt64 = 0_u64
    getter haptic : UInt64 = 0_u64

    def initialize(@repository : Repository, @action_manifest_path : String)
      @prepared_generation = nil.as(Int32?)
      @failed_generation = nil.as(Int32?)
      @next_retry = nil.as(Time::Instant?)
      @sources = {} of PowerOff::Hand => UInt64
    end

    # ハンドルを取り終えていれば true を返す。まだなら、ここで取る。
    #
    # 取れなかった接続でも、retry_interval ごとにやり直す。
    # SteamVR の起動直後は vrserver の応答が遅く、SetActionManifestPath が
    # IPC の待ち時間切れ（VRInputError_IPCError）で失敗することがある。
    # この失敗は同じ接続のまま呼び直せば通るため、つなぎ直しを待つと長押しを検出できない状態が続く。
    # 間隔を空けるのは、1 拍（20 ミリ秒）ごとに呼び直して待ち時間切れを重ねると、主ループが止まるからである。
    def prepare(now : Time::Instant = Time.instant) : Bool
      return false unless @repository.input_available?
      generation = @repository.generation
      return true if @prepared_generation == generation

      retrying = @failed_generation == generation
      next_retry = @next_retry
      return false if retrying && next_retry && now < next_retry

      if fetch
        @prepared_generation = generation
        @failed_generation = nil
        @next_retry = nil
        Log.info { "SteamVR Input のアクションを読ませた: #{@action_manifest_path}" }
        true
      else
        @failed_generation = generation
        @next_retry = now + @retry_interval
        # 同じ接続で失敗が続いても、同じ行でログを埋めない。初回だけ書く。
        unless retrying
          Log.error { "SteamVR Input のアクションを読ませられなかった。読ませるまで長押しを検出せず、#{@retry_interval.total_seconds.to_i} 秒ごとにやり直す" }
        end
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

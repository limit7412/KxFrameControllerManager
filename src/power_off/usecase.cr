require "log"
require "../config/models"
require "./models"
require "./hold_detector"
require "./repository"

module PowerOff
  # 長押しの判定から切断の確認までを受け持つ（仕様書 3.2 節から 3.5 節）。
  #
  # 主ループからは tick を 1 拍ごとに呼ぶ。切断を決めたら別のファイバで要求を送り、
  # 主ループは止めない。切断の確認は、OpenVR の VREvent_TrackedDeviceDeactivated か、
  # 27062 の一覧の接続中から対象が消えたことで行う。
  #
  # 切断の処理中に別の手の長押しが成立したら、捨てずに保留し、前の処理に続けて切る。
  # 左右を同時に長押しすると、同じ拍で左右の長押しが成立する。
  # 後から成立した側を捨てると、片方しか切れない。
  class Usecase
    Log = ::Log.for("power_off")

    # 振動の長さと間隔（仕様書 3.5 節）。予告で短く 1 回、切断の直前に短く 2 回出す。
    WARN_PULSE_S          = 0.08
    FIRE_PULSE_S          = 0.06
    FIRE_PULSE_INTERVAL_S = 0.15

    # 確認を待つ間に眠る長さ。
    CONFIRM_STEP = 50.milliseconds

    # 切断の直前の振動を出してから要求を送るまでの間。
    # 振動が終わる前に切ると、2 回目が出ないまま切れる。spec では 0 にする。
    property haptic_lead : Time::Span = 300.milliseconds

    # 切断の処理が走っているか。長押しの切断を処理している間と、設定画面からの切断の間に真になる。
    def busy? : Bool
      @draining || @manual
    end

    def initialize(
      @input : InputRepository,
      @haptics : HapticRepository,
      @devices : DeviceRepository,
      @link : DisconnectRepository,
      @config : Config::PowerOffSection = Config::PowerOffSection.new,
      @feedback : Config::FeedbackSection = Config::FeedbackSection.new,
    )
      @detectors = {
        Hand::Left  => HoldDetector.new,
        Hand::Right => HoldDetector.new,
      }
      @deactivated = Set(UInt32).new
      # 長押しが成立し、まだ切り始めていない手。要求を送ってよくなる時刻を添える。
      @pending = [] of {Hand, Time::Instant}
      # 長押しの切断で、いま切っている手。
      @active = [] of Hand
      # 保留を処理するファイバが走っているか。
      @draining = false
      # 設定画面からの切断が走っているか。
      @manual = false
      # 27062 へ送る切断を 1 件ずつに絞る。確認が済んでから次を送ることで、
      # Steam UI が使うサーバーへ要求を重ねない（仕様書 2 章の「間隔を設ける」）。
      @lock = Mutex.new
      apply(@config, @feedback)
    end

    # 検証を通った設定を受け取る。
    def apply(@config : Config::PowerOffSection, @feedback : Config::FeedbackSection) : Nil
      @detectors.each_value do |detector|
        detector.warn = @config.warn_ms.milliseconds
        detector.hold = @config.hold_ms.milliseconds
        detector.cooldown = @config.cooldown_ms.milliseconds
      end
    end

    # 主ループの 1 拍。
    def tick(now : Time::Instant = Time.instant) : Nil
      unless @config.enabled && @input.ready? && @input.update
        @detectors.each_value(&.reset)
        return
      end

      @detectors.each do |hand, detector|
        case detector.update(@input.pressed?(hand), now)
        in .none?
        in .warn?
          Log.debug { "#{hand.label}: 予告の振動を出す" }
          pulse(hand, 0.0, WARN_PULSE_S)
        in .cancel?
          Log.info { "#{hand.label}: 長押しが途中で離されたため切断を中止した" }
        in .fire?
          fire(hand)
        end
      end
    end

    # 押下中の判定を捨てる。SteamVR の終了とつなぎ直しのときに呼ぶ。
    #
    # つながっていない間は tick が呼ばれないため、押し始めた時刻が残る。
    # 残したままつなぎ直すと、止まっていた時間まで長押しに数え、予告なしに切断してしまう。
    def reset : Nil
      @detectors.each_value(&.reset)
    end

    # OpenVR のデバイスが切れたことを受け取る。切断の確認に使う。
    def device_deactivated(device_index : UInt32) : Nil
      @deactivated << device_index
    end

    # 手を指定して対象を決める（仕様書 3.3 節）。
    #
    # OpenVR が使えるときは、OpenVR のシリアルを 27062 の形へ直して一覧と照合する。
    # 一覧に無い、または一覧の左右と食い違うときは、その手を切らない。
    # 違う側を切るより、切らないほうがよい（仕様書 7.1 節）。
    #
    # OpenVR が使えないとき（CLI で SteamVR につながらないとき）は、
    # 27062 の一覧が報告する左右だけで決める（仕様書 4.3 節）。
    def resolve(hands : Array(Hand), list : ControllerList? = @link.list) : Array(Target)
      unless list
        Log.warn { "27062 からコントローラーの一覧を取れなかったため切断しない" }
        return [] of Target
      end

      hands.compact_map do |hand|
        @devices.available? ? resolve_with_openvr(hand, list) : resolve_with_link(hand, list)
      end
    end

    # シリアルを指定して対象を決める。27062 の接続中の一覧に無ければ切らない。
    def resolve_serial(serial : String, list : ControllerList? = @link.list) : Target?
      unless list
        Log.warn { "27062 からコントローラーの一覧を取れなかったため切断しない" }
        return nil
      end

      normalized = PowerOff.link_serial(serial)
      linked = list.find(normalized)
      unless linked
        Log.warn { "#{normalized} は 27062 の接続中の一覧に無いため切断しない" }
        return nil
      end
      Target.new(linked.hand, normalized)
    end

    # 対象を順に切り、結末を返す。終わるまで呼び出したファイバを止める。
    def execute(targets : Array(Target)) : Array(Result)
      targets.map { |target| disconnect(target) }
    end

    # 長押しを経ずに手を指定して切る。設定画面の切断ボタンから呼ぶ。
    #
    # 処理中なら新しく始めずに nil を返す。長押しと違って保留しないのは、
    # 画面に結果を返す相手がいて、受け付けなかったことをその場で知らせられるためである。
    # 対象が決まらなければ空の配列を返す。終わるまで呼び出したファイバを止める。
    def manual(hands : Array(Hand)) : Array(Result)?
      if busy?
        Log.info { "前の切断を処理中のため #{hands.map(&.label).join(" と ")} の切断を受け付けない" }
        return nil
      end

      @manual = true
      begin
        Log.info { "設定画面から #{hands.map(&.label).join(" と ")} の切断を受けた" }
        @lock.synchronize { execute(resolve(hands)) }
      ensure
        @manual = false
      end
    end

    # 長押しが成立した手を保留に積み、処理するファイバが走っていなければ起こす。
    private def fire(hand : Hand) : Nil
      wanted = @config.target.both? ? [hand, hand.other] : [hand]
      # target が both のときは、左右の長押しがどちらも左右を対象にする。重ねて積まない。
      hands = wanted.reject { |candidate| @active.includes?(candidate) || @pending.any? { |entry| entry[0] == candidate } }
      if hands.empty?
        Log.info { "#{hand.label}: #{wanted.map(&.label).join(" と ")} はすでに切断の対象のため重ねて切らない" }
        return
      end
      Log.info { "#{hand.label}: 長押しを検出したため #{hands.map(&.label).join(" と ")} を切断する" }

      pulse(hand, 0.0, FIRE_PULSE_S)
      pulse(hand, FIRE_PULSE_INTERVAL_S, FIRE_PULSE_S)
      ready_at = Time.instant + @haptic_lead
      hands.each { |target| @pending << {target, ready_at} }

      return if @draining
      @draining = true
      spawn(name: "power_off") do
        begin
          drain
        rescue exception
          Log.error(exception: exception) { "切断の処理に失敗した" }
        ensure
          @pending.clear
          @active.clear
          @draining = false
        end
      end
    end

    # 保留が無くなるまで切る。切っている間に積まれた手も、続けて切る。
    private def drain : Nil
      until @pending.empty?
        # 振動が終わるのを待つ。眠っている間に積まれた手があれば、その手の振動も待つ。
        while (wait = @pending.max_of { |entry| entry[1] } - Time.instant) > Time::Span.zero
          sleep wait
        end

        # 同じ拍で成立した左右は、27062 の一覧を 1 回引いてまとめて対象を決める。
        @active = @pending.map { |entry| entry[0] }
        @pending.clear
        @lock.synchronize { execute(resolve(@active)) }
        @active.clear
      end
    end

    private def resolve_with_openvr(hand : Hand, list : ControllerList) : Target?
      openvr_serial = @devices.serial(hand)
      unless openvr_serial
        Log.warn { "#{hand.label}: OpenVR からシリアルを読めなかったため切断しない" }
        return nil
      end

      serial = PowerOff.link_serial(openvr_serial)
      linked = list.find(serial)
      unless linked
        Log.warn do
          "#{hand.label}: OpenVR のシリアル #{openvr_serial}（照合に使った値 #{serial}）が " \
          "27062 の接続中の一覧（#{list.connected.map(&.serial).join(", ")}）に無いため切断しない"
        end
        return nil
      end

      if (reported = linked.hand) && reported != hand
        Log.warn { "#{hand.label}: #{serial} は 27062 では #{reported.label} と報告されているため切断しない" }
        return nil
      end

      Target.new(hand, serial, @devices.device_index(hand))
    end

    private def resolve_with_link(hand : Hand, list : ControllerList) : Target?
      candidates = list.connected.select { |controller| controller.hand == hand }
      unless candidates.size == 1
        Log.warn { "#{hand.label}: 27062 の一覧から #{hand.label} のコントローラーを 1 台に決められないため切断しない（#{candidates.size} 台）" }
        return nil
      end
      Target.new(hand, candidates.first.serial)
    end

    # 1 台を切る（仕様書 3.4 節）。
    #
    # 送ってから confirm_timeout_ms のうちに切れたと分からなければ 1 回だけ送り直す。
    # 何度も送り直さないのは、Steam UI が使うサーバーへ要求を重ねたくないためである。
    private def disconnect(target : Target) : Result
      if index = target.device_index
        @deactivated.delete(index)
      end

      2.times do |attempt|
        unless @link.disconnect(target.serial)
          Log.error { "#{target.label}: 切断要求を送れなかった" }
          return Result.new(target, Outcome::SendFailed)
        end
        Log.info { "#{target.label}: 切断要求を送った（#{target.serial}）" }

        if confirmed?(target)
          Log.info { "#{target.label}: 切れたことを確かめた" }
          return Result.new(target, Outcome::Disconnected)
        end
        Log.warn { "#{target.label}: 切れたことを確かめられないため送り直す" } if attempt.zero?
      end

      Log.error { "#{target.label}: 送り直しても切れたことを確かめられなかった" }
      Result.new(target, Outcome::Unconfirmed)
    end

    # OpenVR のイベントを待ち、来なければ最後に 27062 の一覧で確かめる。
    private def confirmed?(target : Target) : Bool
      deadline = Time.instant + @config.confirm_timeout_ms.milliseconds
      index = target.device_index
      while Time.instant < deadline
        return true if index && @deactivated.includes?(index)
        sleep CONFIRM_STEP
      end
      return true if index && @deactivated.includes?(index)

      list = @link.list
      !list.nil? && !list.connected?(target.serial)
    end

    private def pulse(hand : Hand, start_s : Float64, duration_s : Float64) : Nil
      return unless @feedback.haptics
      @haptics.vibrate(hand, start_s, duration_s, @feedback.amplitude)
    end
  end
end

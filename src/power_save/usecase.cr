require "log"
require "../config/models"
require "../power_off/repository"
require "./models"
require "./repository"

module PowerSave
  # 省電力へ入るか、戻るかを決めて設定値を書き換える（仕様書 3.8 節）。
  #
  # 主ループからは tick を 1 拍ごとに呼び、コントローラーがつながっているかを渡す。
  # 入る直前の 27062 の一覧の確認は別のファイバで行い、主ループは止めない。
  #
  # 変える前の値はファイルへ書いてから変える。戻すときはファイルの値を正とする。
  # 設定は SteamVR 側で永続化されるため、戻さずに落ちると次に SteamVR を使うときまで暗いままになる。
  class Usecase
    Log = ::Log.for("power_save")

    enum State
      # コントローラーがつながっている。
      Idle
      # 両方が切れてから delay_s を待っている。
      Waiting
      # 入る直前に 27062 の一覧を確かめている。
      Checking
      # 省電力中。
      Active
    end

    # 戻すのに失敗したとき、次に試すまでの間。毎拍やり直すと、失敗のログで埋まる。
    RECOVERY_RETRY = 10.seconds

    getter state : State = State::Idle

    def initialize(
      @settings : SettingsRepository,
      @store : StateRepository,
      @link : PowerOff::DisconnectRepository,
      @config : Config::PowerSaveSection = Config::PowerSaveSection.new,
    )
      @waiting_since = nil.as(Time::Instant?)
      @next_recovery = nil.as(Time::Instant?)
      # 一覧を確かめている間にコントローラーがつながったら真にする。確認が終わっても入らない。
      @cancelled = false
    end

    def apply(@config : Config::PowerSaveSection) : Nil
    end

    def active? : Bool
      @state.active?
    end

    # 主ループの 1 拍。SteamVR につながっている間だけ呼ぶ。
    def tick(any_connected : Bool, now : Time::Instant = Time.instant) : Nil
      return unless @settings.available?

      # 前回戻せずに終わった値が残っていれば、まず戻す。
      # 強制終了や SteamVR の終了で戻しきれなかった場合がこれにあたる。
      unless @state.active?
        return unless recover(now)
      end

      if any_connected
        leave("コントローラーがつながったため") if @state.active?
        @cancelled = true if @state.checking?
        @state = State::Idle unless @state.checking?
        @waiting_since = nil
        return
      end

      unless @config.enabled
        leave("省電力が無効にされたため") if @state.active?
        @cancelled = true if @state.checking?
        @state = State::Idle unless @state.checking?
        @waiting_since = nil
        return
      end

      case @state
      in .idle?
        @state = State::Waiting
        @waiting_since = now
      in .waiting?
        since = @waiting_since || now
        start_check if now - since >= @config.delay_s.seconds
      in .checking?, .active?
      end
    end

    # 終了の前に呼ぶ。省電力中なら元に戻す。
    # SIGTERM と VREvent_Quit のときに、OpenVR を閉じる前に呼ぶ。
    def shutdown : Nil
      leave("終了するため") if @state.active?
      @state = State::Idle
      @waiting_since = nil
    end

    private def start_check : Nil
      @state = State::Checking
      @cancelled = false
      spawn(name: "power_save") do
        begin
          list = @link.list
          if @cancelled
            Log.debug { "一覧を確かめている間にコントローラーがつながったため入らない" }
            @state = State::Idle
          elsif list && !list.connected.empty?
            # OpenVR と 27062 の言い分が食い違う。安全側に倒し、待ち直す。
            Log.info { "27062 では #{list.connected.map(&.serial).join(", ")} が接続中のため省電力へ入らない" }
            @state = State::Waiting
            @waiting_since = Time.instant
          else
            Log.debug { "27062 の一覧を取れなかったため OpenVR の判定だけで入る" } unless list
            enter
          end
        rescue exception
          Log.error(exception: exception) { "省電力へ入る処理に失敗した" }
          @state = State::Active
        end
      end
    end

    # 省電力へ入る。どの値も変えられなかった場合も Active にする。
    # 戻さずに Waiting へ返すと、delay_s ごとに同じ失敗を繰り返す。
    private def enter : Nil
      @state = State::Active
      plan = build_plan
      if plan.empty?
        Log.info { "両方のコントローラーが切れているが、変える値が無い" }
        return
      end

      @store.save(SavedState.new(plan.map(&.[0])))

      plan.each do |saved, write|
        next if write.call
        Log.error { "#{saved.section}/#{saved.key} を書き換えられなかったため、書き換えた分を戻す" }
        restore
        return
      end
      Log.info { "両方のコントローラーが切れているため省電力へ入った（#{plan.map { |saved, _| saved.key }.join(", ")}）" }
    end

    # 変える値ごとに、変える前の値と書き換えの手順を組にする。
    private def build_plan : Array({SavedValue, Proc(Bool)})
      plan = [] of {SavedValue, Proc(Bool)}
      plan_brightness(plan) if @config.brightness
      plan_profile(plan) if @config.performance_profile
      plan
    end

    private def plan_brightness(plan : Array({SavedValue, Proc(Bool)})) : Nil
      range = @settings.gain_range
      unless range
        Log.info { "HMD が analogGain に対応していないか範囲を読めないため、明るさは変えない" }
        return
      end
      min, max = range
      target = (@config.brightness_gain || min).clamp(min, max)

      current = @settings.read_float(SECTION, ANALOG_GAIN_KEY)
      if current.status.failed?
        Log.warn { "#{SECTION}/#{ANALOG_GAIN_KEY} を読めないため、明るさは変えない" }
        return
      end
      # 既に省電力の値より暗ければ触らない。下げるつもりで明るくすることになる。
      if current.status.value? && current.value <= target
        Log.debug { "analogGain は既に #{current.value} で、#{target} 以下のため変えない" }
        return
      end

      saved = SavedValue.of_float(SECTION, ANALOG_GAIN_KEY, current)
      plan << {saved, -> { @settings.write_float(SECTION, ANALOG_GAIN_KEY, target) }}
    end

    private def plan_profile(plan : Array({SavedValue, Proc(Bool)})) : Nil
      powersave = @settings.read_string(SECTION, POWERSAVE_PROFILE_KEY)
      unless powersave.status.value? && !powersave.value.empty?
        Log.info { "#{SECTION}/#{POWERSAVE_PROFILE_KEY} を読めないため、描画のプロファイルは変えない" }
        return
      end

      current = @settings.read_string(SECTION, PERFORMANCE_PROFILE_KEY)
      if current.status.failed?
        Log.warn { "#{SECTION}/#{PERFORMANCE_PROFILE_KEY} を読めないため、描画のプロファイルは変えない" }
        return
      end
      return if current.status.value? && current.value == powersave.value

      saved = SavedValue.of_string(SECTION, PERFORMANCE_PROFILE_KEY, current)
      name = powersave.value
      plan << {saved, -> { @settings.write_string(SECTION, PERFORMANCE_PROFILE_KEY, name) }}
    end

    private def leave(reason : String) : Nil
      @state = State::Idle
      Log.info { "#{reason}省電力から戻る" } if restore
    end

    # 前回の値が残っていれば戻す。戻せた、または残っていなければ true を返す。
    private def recover(now : Time::Instant) : Bool
      return true unless @store.exists?
      if (next_recovery = @next_recovery) && now < next_recovery
        return false
      end

      Log.info { "前回戻せなかった設定値が残っているため戻す" }
      if restore
        @next_recovery = nil
        return true
      end
      @next_recovery = now + RECOVERY_RETRY
      false
    end

    # ファイルに残した値へ戻す。すべて戻せたらファイルを消して true を返す。
    # 1 つでも戻せなければファイルを残し、次の接続でやり直す。
    private def restore : Bool
      return true unless @store.exists?

      state = begin
        @store.load
      rescue exception : JSON::Error | IO::Error
        Log.error(exception: exception) { "戻す値を読めなかった。ファイルは残しておく" }
        return false
      end

      failed = state.values.reject { |saved| restore_one(saved) }
      if failed.empty?
        @store.delete
        return true
      end
      Log.error { "#{failed.map(&.key).join(", ")} を戻せなかった。次に SteamVR へつながったときにやり直す" }
      false
    end

    private def restore_one(saved : SavedValue) : Bool
      return @settings.remove(saved.section, saved.key) if saved.unset
      if value = saved.float
        return @settings.write_float(saved.section, saved.key, value)
      end
      if value = saved.string
        return @settings.write_string(saved.section, saved.key, value)
      end
      # 値も未設定の印も無いものは、読めなかった値である。plan に入らないため、ここへは来ない。
      true
    end
  end
end

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
  #
  # 明るさは 1 回で書くと一瞬で変わるため、fade_ms が正なら拍ごとに少しずつ書く。
  # 描画のプロファイルは切り替えの直後に 0.5 秒ほど画面が暗転する（実機、2026-11-17）。
  # 段階的には変えられないので、暗い間に切り替える。
  # 入るときは明るさを下げきってから切り替え、戻るときは切り替えてから明るさを上げる。
  class Usecase
    Log = ::Log.for("power_save")

    enum State
      # コントローラーがつながっている。
      Idle
      # 両方が切れてから delay_s を待っている。
      Waiting
      # 入る直前に 27062 の一覧を確かめている。
      Checking
      # 省電力中。明るさを下げている途中も含む。
      Active
      # 省電力から戻っている途中。明るさを上げきるまでここにいる。
      Restoring
    end

    # フェードの間に明るさを書く間隔。
    # 実機では、これより細かく書いても画面の明るさは約 120ms に 1 回しか変わらなかった（2026-11-17）。
    FADE_STEP = 100.milliseconds
    # 戻るときのフェードの長さの上限。コントローラーをつないだ人を、暗い画面の前で待たせない。
    FADE_IN_LIMIT = 500.milliseconds
    # 描画のプロファイルを戻してから、明るさを上げ始めるまでの間。
    # 切り替えの暗転が終わるのを待つ。実機の暗転は切り替えから 0.5 秒以内に終わった（2026-11-17）。
    PROFILE_SETTLE = 500.milliseconds
    # 明るさを補間するときのガンマ。
    # 値を等間隔に変えると、暗い側だけが急に変わって見える。
    FADE_GAMMA = 2.2

    # 変える値 1 件。fade は、明るさを段階的に変えるときの始まりと終わりの値である。
    private record Change, saved : SavedValue, write : Proc(Bool), fade : {Float64, Float64}? = nil

    # 進行中のフェード。始まりの時刻は、最初に進めた拍で決める。
    private class Fade
      getter from : Float64
      getter to : Float64
      getter duration : Time::Span
      getter delay : Time::Span
      property started : Time::Instant?
      property last_write : Time::Instant?
      # 最後に書いた値。途中で向きを変えるときの始まりの値になる。
      property current : Float64

      def initialize(@from : Float64, @to : Float64, @duration : Time::Span, @delay : Time::Span = Time::Span.zero)
        @current = @from
      end

      # 始まってからの時間に応じた値。ガンマの空間で直線に補間する。
      def value(elapsed : Time::Span) : Float64
        ratio = (elapsed / @duration).clamp(0.0, 1.0)
        exponent = 1.0 / FADE_GAMMA
        ((@from ** exponent) * (1.0 - ratio) + (@to ** exponent) * ratio) ** FADE_GAMMA
      end
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
      # 確認のファイバの番号。shutdown の後に戻ってきた古い確認を見分けるのに使う。
      @check_id = 0
      # 進行中のフェード。Active なら下げている途中、Restoring なら上げている途中である。
      @fade = nil.as(Fade?)
      # 下げているフェードが書いている値と、下げきった後に書く残りの値。
      @fading = nil.as(Change?)
      @pending = [] of Change
      # 上げているフェードが書いている値。
      @restoring = nil.as(SavedValue?)
    end

    def apply(@config : Config::PowerSaveSection) : Nil
    end

    def active? : Bool
      @state.active?
    end

    # 主ループの 1 拍。SteamVR につながっている間だけ呼ぶ。
    def tick(any_connected : Bool, now : Time::Instant = Time.instant) : Nil
      return unless @settings.available?

      # 戻しきるまでは、入る判定へ進まない。途中でまた両方が切れても、いったん元の明るさまで戻す。
      if @state.restoring?
        advance_restore(now)
        return
      end

      # 前回戻せずに終わった値が残っていれば、まず戻す。
      # 強制終了や SteamVR の終了で戻しきれなかった場合がこれにあたる。
      unless @state.active?
        return unless recover(now)
      end

      if any_connected
        leave("コントローラーがつながったため") if @state.active?
        @cancelled = true if @state.checking?
        @state = State::Idle if @state.waiting?
        @waiting_since = nil
        return
      end

      unless @config.enabled
        leave("省電力が無効にされたため") if @state.active?
        @cancelled = true if @state.checking?
        @state = State::Idle if @state.waiting?
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
      in .active?
        advance_enter(now)
      in .checking?, .restoring?
      end
    end

    # 終了の前に呼ぶ。省電力中なら元に戻す。
    # SIGTERM と VREvent_Quit のときに、OpenVR を閉じる前に呼ぶ。
    #
    # フェードはしない。OpenVR を閉じる前に戻し終える必要がある。
    def shutdown : Nil
      if @state.active? || @state.restoring?
        clear_fade
        Log.info { "終了するため省電力から戻る" } if restore
      end
      # 確認の途中なら、その結果では入らない。OpenVR を閉じた後に Active へ移ると、
      # つなぎ直してもコントローラーがつながるまで入り直せなくなる。
      @check_id += 1
      @state = State::Idle
      @waiting_since = nil
    end

    private def start_check : Nil
      @state = State::Checking
      @cancelled = false
      @check_id += 1
      check_id = @check_id
      spawn(name: "power_save") do
        begin
          list = @link.list
          if check_id != @check_id
            Log.debug { "一覧を確かめている間に終了したため入らない" }
          elsif @cancelled
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
          @state = State::Active if check_id == @check_id
        end
      end
    end

    # 省電力へ入る。どの値も変えられなかった場合も Active にする。
    # 戻さずに Waiting へ返すと、delay_s ごとに同じ失敗を繰り返す。
    #
    # 明るさを段階的に下げる場合は、ここではフェードを始めるだけにする。
    # 続きは tick が拍ごとに進め、下げきってから残りの値を書く。
    private def enter : Nil
      @state = State::Active
      plan = build_plan
      if plan.empty?
        Log.info { "両方のコントローラーが切れているが、変える値が無い" }
        return
      end

      @store.save(SavedState.new(plan.map(&.saved)))

      first = plan.first
      if (range = first.fade) && @config.fade_ms > 0
        @fading = first
        @pending = plan[1..]
        @fade = Fade.new(range[0], range[1], @config.fade_ms.milliseconds)
        Log.debug { "#{first.saved.key} を #{@config.fade_ms}ms かけて #{range[0]} から #{range[1]} へ下げる" }
        return
      end

      write_all(plan, [] of SavedValue)
    end

    # 値を順に書く。written は、ここへ来る前に書き換えを終えている値である。
    # 途中で失敗したら、書き換えた分を戻す。
    private def write_all(changes : Array(Change), written : Array(SavedValue)) : Nil
      changes.each do |change|
        unless change.write.call
          Log.error { "#{change.saved.section}/#{change.saved.key} を書き換えられなかったため、書き換えた分を戻す" }
          roll_back(written)
          return
        end
        written << change.saved
      end
      Log.info { "両方のコントローラーが切れているため省電力へ入った（#{written.map(&.key).join(", ")}）" }
    end

    # 書き換えた分だけを戻す。
    # 書き換えていない値まで書き戻すと、その書き戻しも同じ理由で失敗し、ファイルが残り続ける。
    private def roll_back(written : Array(SavedValue)) : Nil
      failed = written.reject { |value| restore_one(value) }
      if failed.empty?
        @store.delete
      else
        @store.save(SavedState.new(failed))
        Log.error { "#{failed.map(&.key).join(", ")} を戻せなかった。次に SteamVR へつながったときにやり直す" }
      end
    end

    # 明るさを下げているフェードを 1 拍進める。下げきったら残りの値を書く。
    private def advance_enter(now : Time::Instant) : Nil
      fade = @fade
      change = @fading
      return unless fade && change

      case step(fade, change.saved, now)
      in .waiting?
      in .failed?
        Log.error { "#{change.saved.section}/#{change.saved.key} を書き換えられなかったため、書き換えた分を戻す" }
        clear_fade
        roll_back([change.saved])
      in .finished?
        pending = @pending
        clear_fade
        # 最後は補間の値ではなく、目標の値そのものを書く。
        # 明るさは途中まで書き換えてあるので、この書き込みが失敗しても戻す対象に入れる。
        unless change.write.call
          Log.error { "#{change.saved.section}/#{change.saved.key} を書き換えられなかったため、書き換えた分を戻す" }
          roll_back([change.saved])
          return
        end
        write_all(pending, [change.saved])
      end
    end

    # 明るさを上げているフェードを 1 拍進める。上げきったらファイルを消して Idle へ戻る。
    private def advance_restore(now : Time::Instant) : Nil
      fade = @fade
      saved = @restoring
      unless fade && saved
        finish_restore
        return
      end

      case step(fade, saved, now)
      in .waiting?
      in .failed?, .finished?
        # 失敗したときも、残りは 1 回で戻す。それも失敗すればファイルが残り、recover がやり直す。
        finish_restore
      end
    end

    private def finish_restore : Nil
      clear_fade
      @state = State::Idle
      Log.info { "省電力から戻った" } if restore
    end

    private enum StepResult
      Waiting
      Finished
      Failed
    end

    # フェードを 1 拍進める。FADE_STEP ごとに 1 回だけ書く。
    private def step(fade : Fade, saved : SavedValue, now : Time::Instant) : StepResult
      started = fade.started
      unless started
        # 遅らせる分も含めて、最初に進めた拍を起点にする。
        started = fade.started = now + fade.delay
        fade.last_write = started
      end
      return StepResult::Waiting if now < started

      elapsed = now - started
      return StepResult::Finished if elapsed >= fade.duration
      if (last = fade.last_write) && now - last < FADE_STEP
        return StepResult::Waiting
      end

      value = fade.value(elapsed)
      return StepResult::Failed unless @settings.write_float(saved.section, saved.key, value)
      fade.current = value
      fade.last_write = now
      StepResult::Waiting
    end

    private def clear_fade : Nil
      @fade = nil
      @fading = nil
      @restoring = nil
      @pending = [] of Change
    end

    # 変える値ごとに、変える前の値と書き換えの手順を組にする。
    # 明るさを先頭に置く。描画のプロファイルは、明るさを下げきってから切り替える。
    private def build_plan : Array(Change)
      plan = [] of Change
      plan_brightness(plan) if @config.brightness
      plan_profile(plan) if @config.performance_profile
      plan
    end

    private def plan_brightness(plan : Array(Change)) : Nil
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
      # 元が未設定なら今の明るさが分からないため、段階的には下げられない。
      fade = current.status.value? ? {current.value, target} : nil
      plan << Change.new(saved, -> { @settings.write_float(SECTION, ANALOG_GAIN_KEY, target) }, fade)
    end

    private def plan_profile(plan : Array(Change)) : Nil
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
      plan << Change.new(saved, -> { @settings.write_string(SECTION, PERFORMANCE_PROFILE_KEY, name) })
    end

    # 省電力から戻る。
    #
    # 明るさを段階的に上げられるなら、ほかの値を先に戻してから Restoring へ移り、続きは tick が進める。
    # 上げられないとき、またはほかの値を戻せなかったときは、今までどおり 1 回で戻す。
    private def leave(reason : String) : Nil
      # 下げている途中なら、残りの値（描画のプロファイル）はまだ書いていない。
      entering = @fade
      fading = @fading
      clear_fade

      if start_restore(entering)
        Log.info { "#{reason}省電力から戻る" }
        return
      end
      @state = State::Idle
      if fading
        # 下げ始めた直後など、上げるフェードにできなかった場合。書いたのは明るさだけなので、明るさだけを戻す。
        roll_back([fading.saved])
        Log.info { "#{reason}省電力から戻る" }
      elsif restore
        Log.info { "#{reason}省電力から戻る" }
      end
    end

    # 明るさを上げるフェードを始める。始められたら true を返す。
    private def start_restore(entering : Fade?) : Bool
      return false unless @config.fade_ms > 0 && @store.exists?
      values = begin
        @store.load.values
      rescue JSON::Error | IO::Error
        # 読めないときの扱いは restore に任せる。
        return false
      end

      brightness = values.find { |saved| saved.section == SECTION && saved.key == ANALOG_GAIN_KEY }
      target = brightness.try(&.float)
      return false unless brightness && target

      current = entering.try(&.current) || begin
        reading = @settings.read_float(SECTION, ANALOG_GAIN_KEY)
        return false unless reading.status.value?
        reading.value
      end
      return false unless 0 < current < target

      # 描画のプロファイルは、暗いうちに戻す。下げている途中だったなら、まだ書いていないので触らない。
      others = entering ? [] of SavedValue : values.reject { |saved| saved == brightness }
      return false unless others.all? { |saved| restore_one(saved) }
      # 戻し終えた値と書いていない値をファイルから外す。
      # 残すと、上げきった後や次の起動で、変わっていない描画のプロファイルを書き直すことになる。
      @store.save(SavedState.new([brightness])) if values.size > 1

      duration = Math.min(@config.fade_ms.milliseconds, FADE_IN_LIMIT)
      delay = others.empty? ? Time::Span.zero : PROFILE_SETTLE
      @restoring = brightness
      @fade = Fade.new(current, target, duration, delay)
      @state = State::Restoring
      true
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

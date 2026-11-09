module PowerOff
  # 長押しの判定が返す合図。
  enum HoldSignal
    # 何もしない。
    None
    # 予告の振動を出す。
    Warn
    # 切断する。
    Fire
    # 予告の後に離されたので中止した。
    Cancel
  end

  # 片手ぶんの長押しの状態機械（仕様書 3.2 節）。
  #
  # 入力は時刻と押下状態だけであり、OpenVR には触れない。
  # 時刻を引数で受け取るのは、spec から任意の時刻を与えて確かめるためである。
  class HoldDetector
    enum State
      # 押されるのを待っている。
      Idle
      # 押されていて、予告はまだ出していない。
      Pressing
      # 予告を出し、切断までの残りを待っている。
      Warned
      # 切断を返した。離されるのを待っている。
      WaitingRelease
      # 離された後の再判定しない時間。
      Cooldown
    end

    getter state : State = State::Idle

    property warn : Time::Span
    property hold : Time::Span
    property cooldown : Time::Span

    def initialize(@warn : Time::Span = 1000.milliseconds, @hold : Time::Span = 2000.milliseconds, @cooldown : Time::Span = 3000.milliseconds)
      @pressed_at = nil.as(Time::Instant?)
      @cooldown_until = nil.as(Time::Instant?)
    end

    # 主ループの 1 拍ごとに呼ぶ。
    def update(pressed : Bool, now : Time::Instant) : HoldSignal
      case @state
      in .idle?
        return HoldSignal::None unless pressed
        @pressed_at = now
        @state = State::Pressing
        # warn が 0 のときは、押した拍のうちに予告まで進める。
        advance(now)
      in .pressing?
        return release_before_fire unless pressed
        advance(now)
      in .warned?
        return release_before_fire unless pressed
        advance(now)
      in .waiting_release?
        unless pressed
          @cooldown_until = now + @cooldown
          @state = State::Cooldown
        end
        HoldSignal::None
      in .cooldown?
        cooldown_until = @cooldown_until
        return HoldSignal::None if cooldown_until && now < cooldown_until
        # 押したまま明けたときは、離されるまで待つ。押しっぱなしで次の判定へ入ると、
        # 1 回の長押しで 2 回切断することになる。
        @state = pressed ? State::WaitingRelease : State::Idle
        HoldSignal::None
      end
    end

    # 入力が読めなくなったときなどに、待機へ戻す。
    # 解放待ちとクールダウンは保つ。戻すと、離していないのに次の判定を始めてしまう。
    def reset : Nil
      return unless @state.pressing? || @state.warned?
      @state = State::Idle
      @pressed_at = nil
    end

    private def advance(now : Time::Instant) : HoldSignal
      pressed_at = @pressed_at || now
      elapsed = now - pressed_at
      if @state.pressing? && elapsed >= @warn
        @state = State::Warned
        # 予告と切断が同じ拍に来たら、切断を優先する。
        # 検証で hold - warn >= 500 ミリ秒を保証しているため、通常は起きない。
        return fire if elapsed >= @hold
        return HoldSignal::Warn
      end
      return fire if @state.warned? && elapsed >= @hold
      HoldSignal::None
    end

    private def fire : HoldSignal
      @state = State::WaitingRelease
      @pressed_at = nil
      HoldSignal::Fire
    end

    private def release_before_fire : HoldSignal
      warned = @state.warned?
      @state = State::Idle
      @pressed_at = nil
      warned ? HoldSignal::Cancel : HoldSignal::None
    end
  end
end

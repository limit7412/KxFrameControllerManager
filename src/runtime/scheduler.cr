require "../error/usecase"
require "../steamvr/usecase"

module Runtime
  # 主ループの 1 拍で何を呼ぶかを決める（仕様書 4.2 節）。
  # ロジックは持たず、usecase を呼ぶ順序と間隔だけを決める。
  #
  # 主ループは「処理して短く sleep する」形を取る。
  # Crystal のファイバは協調的にしか切り替わらず、sleep で制御を返さないと
  # 切断要求や更新の確認を待つファイバが進まないためである。
  class Scheduler
    # OpenVR から受け取ったイベントを渡す先。
    # 長押しの判定や省電力が、デバイスの接続と切断を知るために使う。
    property on_events : Proc(Array(SteamVR::Event), Nil) = ->(_events : Array(SteamVR::Event)) { }

    # SteamVR が動いていない間に、OpenVR の初期化をやり直す間隔。
    property retry_interval : Time::Span

    # 1 拍の後に眠る長さ。SteamVR Input の UpdateActionState を呼ぶ間隔でもある。
    property poll_interval : Time::Span

    def initialize(
      @steamvr : SteamVR::Usecase,
      @errors : Error::Usecase,
      @retry_interval : Time::Span = 10.seconds,
      @poll_interval : Time::Span = 20.milliseconds,
    )
      # 起動直後の 1 拍目で接続を試す。SteamVR が先に動いていれば待たずにつながる。
      @next_retry = nil.as(Time::Instant?)
    end

    # 主ループから繰り返し呼ぶ 1 拍。
    #
    # つながっていればイベントを読む。つながっていなければ、間隔を空けて接続を試す。
    # SteamVR の終了を受けて OpenVR を閉じた後も、ここで再試行へ戻る（仕様書 3.6 節）。
    def step(now : Time::Instant = Time.instant) : Nil
      if @steamvr.connected?
        @errors.guard("error.steamvr_poll") do
          events = @steamvr.poll
          @on_events.call(events) unless events.empty?
        end
        # 閉じた直後にすぐ開き直さない。SteamVR が終わりかけている間に初期化を繰り返すと、
        # 終了の邪魔になる。次の試行は 1 間隔の後にする。
        @next_retry = now + @retry_interval unless @steamvr.connected?
        return
      end

      next_retry = @next_retry
      return if next_retry && now < next_retry

      @next_retry = now + @retry_interval
      @errors.guard("error.steamvr_open") { @steamvr.connect }
    end
  end
end

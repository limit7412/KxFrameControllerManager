require "log"
require "../config/usecase"
require "../power_off/models"
require "../steamvr/repository"
require "./canvas"
require "./models"
require "./view"

module Dashboard
  # ダッシュボードのタブを作り、操作を受けて設定と切断へ流す。
  #
  # 主ループから tick を 1 拍ごとに呼ぶ。SteamVR につながっている間だけ呼ばれる前提である。
  # 画面は IVROverlay の SetOverlayRaw で渡す。SetOverlayRaw は渡すたびに一瞬画面が消えるため、
  # 描き直すのは、見えている間に内容が変わったときだけにする（ポインタを動かしただけでは描き直さない）。
  class Usecase
    Log = ::Log.for("dashboard")

    OVERLAY_KEY  = "kairo.kxframecontrollermanager.dashboard"
    OVERLAY_NAME = "KxFCM"
    # ダッシュボードの中での幅。FrameMover（2.4 m）と frameeyeosc（2.8 m）の間に取る。
    WIDTH_M        = 2.4_f32
    THUMBNAIL_SIZE =     128

    # 見えている間に常駐の状態を読み直す間隔。
    STATUS_INTERVAL = 1.second
    # 切断の 1 回目を押してから、2 回目を待つ長さ。
    ARM_TIMEOUT = 4.seconds

    # 常駐の状態を組み立てる。
    property status : Proc(Snapshot) = -> { raise "status が渡されていない" }
    # 手を指定して切る。処理中で受け付けられなければ nil を返す。
    property disconnect : Proc(Array(PowerOff::Hand), Array(PowerOff::Result)?) = ->(_hands : Array(PowerOff::Hand)) { nil.as(Array(PowerOff::Result)?) }
    # 長押しに割り当てられるボタン。
    property buttons : Hash(PowerOff::Hand, Array(String)) = {} of PowerOff::Hand => Array(String)
    # 新しい版があるかだけを見る。check の結末の名前（up_to_date、available など）と、見つけた版を返す。
    property check_update : Proc({String, String?}) = -> { {"unknown", nil.as(String?)} }
    # 今すぐの更新を、常駐とは別のユニットで始める。始められたら真を返す。
    property start_update : Proc(Bool) = -> { false }
    # 描画先を作る。libcairo が無ければ nil を返す。
    property canvas_factory : Proc(Int32, Int32, Canvas?) = ->(_w : Int32, _h : Int32) { nil.as(Canvas?) }

    getter state : ViewState = ViewState.new

    def initialize(@repository : SteamVR::Repository, @config : Config::Usecase, @view : View)
      @main = nil.as(UInt64?)
      @thumbnail = nil.as(UInt64?)
      @generation = nil.as(Int32?)
      @failed_generation = nil.as(Int32?)
      @enabled = true
      @visible = false
      @dirty = true
      @hits = [] of Hit
      @last_status = nil.as(Time::Instant?)
      @armed_at = nil.as(Time::Instant?)
      @canvas = nil.as(Canvas?)
    end

    # 設定 dashboard.enabled を受け取る。無効にされたらタブを消す。
    def apply(enabled : Bool) : Nil
      @enabled = enabled
      close unless enabled
      @dirty = true
    end

    # タブが見えているか。ボタンの割り当ての反映（つなぎ直し）は、見えていない間に行う。
    def visible? : Bool
      @visible
    end

    # 設定を外から変えられたとき（SIGHUP など）に描き直す。
    def invalidate : Nil
      @dirty = true
    end

    def tick(now : Time::Instant = Time.instant) : Nil
      return unless @enabled
      return unless ensure_overlay
      main = @main.not_nil!

      # 期限切れの確認は、クリックを処理する前に取り消す。後にすると、4 秒を過ぎた 2 回目で切れてしまう。
      expire_arm(now)
      @repository.poll_overlay_events(main).each { |event| handle(event, now) }
      @visible = @repository.overlay_visible?(main)

      return unless @visible
      refresh_status(now)
      draw if @dirty
    end

    # タブを消す。OpenVR を閉じる前に呼ぶ。
    # 画面を受け取っている途中のオーバーレイを残したまま閉じると、SteamVR 側が落ちた例がある（FrameMover）。
    def close : Nil
      if @repository.opened?
        @main.try { |handle| @repository.destroy_overlay(handle) }
        @thumbnail.try { |handle| @repository.destroy_overlay(handle) }
      end
      @main = nil
      @thumbnail = nil
      @generation = nil
      @visible = false
      @dirty = true
    end

    # 押せる場所の綴りを受けて動かす。spec から直接呼べるよう公開しておく。
    def act(action : String, now : Time::Instant = Time.instant) : Nil
      kind, _, rest = action.partition(':')
      case kind
      when "tab"
        @state.tab = Tab.parse(rest)
        @state.message = nil
        @state.update_message = nil
      when "disconnect"
        press_disconnect(rest, now)
      when "update"
        rest == "run" ? press_update(now) : check_for_update
      when "set"
        key, _, direction = rest.rpartition(':')
        change(key, direction.to_i)
      end
      @dirty = true
    end

    # 今の画面を描いて返す。spec と、実機なしで画面を確かめるために使う。
    def render(canvas : Canvas) : Nil
      @hits = @view.render(canvas, @state, @config.current)
    end

    private def ensure_overlay : Bool
      return false unless @repository.overlay_available?
      generation = @repository.generation
      # 開き直した OpenVR では前のハンドルは使えない。作り直す。
      if @generation != generation
        @main = nil
        @thumbnail = nil
        @generation = nil
      end
      return true if @main
      return false if @failed_generation == generation

      handles = @repository.create_dashboard_overlay(OVERLAY_KEY, OVERLAY_NAME)
      unless handles && (canvas = @canvas || @canvas_factory.call(View::WIDTH, View::HEIGHT))
        @failed_generation = generation
        Log.error { "設定画面のタブを作れなかったため、次に SteamVR へつながるまで出さない" }
        handles.try { |(main, thumbnail)| @repository.destroy_overlay(main); @repository.destroy_overlay(thumbnail) }
        return false
      end

      main, thumbnail = handles
      @canvas = canvas
      @main = main
      @thumbnail = thumbnail
      @generation = generation
      @repository.configure_overlay(main, WIDTH_M, View::WIDTH, View::HEIGHT)
      if icon = @canvas_factory.call(THUMBNAIL_SIZE, THUMBNAIL_SIZE)
        View.thumbnail(icon)
        @repository.set_overlay_raw(thumbnail, icon.rgba, THUMBNAIL_SIZE, THUMBNAIL_SIZE)
      end
      @dirty = true
      Log.info { "設定画面のタブを作った" }
      true
    end

    private def handle(event : SteamVR::OverlayEvent, now : Time::Instant) : Nil
      case event.kind
      in .mouse_button_up?
        # オーバーレイのマウスの座標は左下が原点である。画面の座標（左上が原点）へ直す。
        x = event.x.to_f
        y = View::HEIGHT - event.y.to_f
        if hit = @hits.find(&.contains?(x, y))
          act(hit.action, now)
        end
      in .shown?
        @last_status = nil
        @dirty = true
      in .other?
      end
    end

    private def refresh_status(now : Time::Instant) : Nil
      last = @last_status
      return if last && now - last < STATUS_INTERVAL
      @last_status = now
      snapshot = @status.call
      return if snapshot == @state.snapshot
      @state.snapshot = snapshot
      @dirty = true
    end

    private def draw : Nil
      canvas = @canvas
      main = @main
      return unless canvas && main
      render(canvas)
      @repository.set_overlay_raw(main, canvas.rgba, View::WIDTH, View::HEIGHT)
      @dirty = false
    end

    # 切断は 2 回押しで動かす。VR の中では誤って触れやすく、確認のダイアログも出せない。
    private def press_disconnect(target : String, now : Time::Instant) : Nil
      return if @state.running?
      expire_arm(now)
      unless @state.armed == target
        @state.armed = target
        @armed_at = now
        @state.message = nil
        return
      end

      @state.armed = nil
      @armed_at = nil
      hands = case target
              when "left"  then [PowerOff::Hand::Left]
              when "right" then [PowerOff::Hand::Right]
              else              [PowerOff::Hand::Left, PowerOff::Hand::Right]
              end
      @state.running = true
      @state.message = @view.t("dashboard.disconnect.running")
      @state.tone = Tone::Info

      # 切断は確認まで最長で数秒待つ。主ループを止めないよう別のファイバで行う。
      spawn(name: "dashboard_disconnect") do
        begin
          finish_disconnect(@disconnect.call(hands))
        rescue exception
          Log.error(exception: exception) { "設定画面からの切断に失敗した" }
          @state.message = @view.t("dashboard.disconnect.failed")
          @state.tone = Tone::Error
        ensure
          @state.running = false
          @last_status = nil
          @dirty = true
        end
      end
    end

    private def expire_arm(now : Time::Instant) : Nil
      armed_at = @armed_at
      return unless armed_at && now - armed_at >= ARM_TIMEOUT
      @state.armed = nil
      @armed_at = nil
      @dirty = true
    end

    # 今すぐの更新も 2 回押しで動かす。常駐が再起動してタブが一度消えるためである。
    #
    # 更新は常駐の中では行わず、systemd の別のユニットで `update` を走らせる。
    # 常駐の中から自分を再起動すると、新しい版の起動を確かめる者がいなくなる（自動更新と同じ理由）。
    private def press_update(now : Time::Instant) : Nil
      expire_arm(now)
      unless @state.armed == "update"
        @state.armed = "update"
        @armed_at = now
        @state.update_message = nil
        return
      end

      @state.armed = nil
      @armed_at = nil
      if @start_update.call
        @state.update_message = @view.t("dashboard.update.started")
        @state.update_tone = Tone::Info
      else
        @state.update_message = @view.t("dashboard.update.start_failed")
        @state.update_tone = Tone::Error
      end
      @last_status = nil
    end

    # GitHub への問い合わせは数秒かかりうる。主ループを止めないよう別のファイバで行う。
    private def check_for_update : Nil
      return if @state.checking?
      @state.checking = true
      @state.update_message = nil
      spawn(name: "dashboard_check_update") do
        begin
          outcome, tag = @check_update.call
          @state.update_message = @view.t("dashboard.update.check.#{outcome}", {"tag" => tag || ""})
          @state.update_tone = case outcome
                               when "available"  then Tone::Ok
                               when "up_to_date" then Tone::Info
                               else                   Tone::Warn
                               end
        rescue exception
          Log.error(exception: exception) { "設定画面からの更新の確認に失敗した" }
          @state.update_message = @view.t("dashboard.update.check.unreachable", {"tag" => ""})
          @state.update_tone = Tone::Warn
        ensure
          @state.checking = false
          @dirty = true
        end
      end
    end

    private def finish_disconnect(results : Array(PowerOff::Result)?) : Nil
      unless results
        @state.message = @view.t("dashboard.disconnect.busy")
        @state.tone = Tone::Warn
        return
      end
      if results.empty?
        @state.message = @view.t("dashboard.disconnect.no_target")
        @state.tone = Tone::Error
        return
      end
      @state.message = results.map do |result|
        "#{@view.t("dashboard.hand.#{result.target.label}")}: #{@view.t("dashboard.outcome.#{result.outcome.to_s.underscore}")}"
      end.join(" / ")
      @state.tone = results.all?(&.outcome.disconnected?) ? Tone::Ok : Tone::Warn
    end

    # 設定を 1 段変えて保存する。保存は config の usecase を通し、検証を通ったときだけ反映される。
    private def change(key : String, direction : Int32) : Nil
      before = @config.current
      gain_range = @state.snapshot.try(&.gain_range)
      root = Editor.apply(before, key, direction, @buttons, gain_range)
      errors = @config.save(root)
      if errors.empty?
        @state.message = nil
        if before.input.left_button != root.input.left_button || before.input.right_button != root.input.right_button
          @state.rebind_pending = true
        end
      else
        @state.message = errors.first.to_s
        @state.tone = Tone::Error
      end
    rescue exception : File::Error
      Log.error(exception: exception) { "設定画面からの保存に失敗した" }
      @state.message = @view.t("dashboard.save_failed")
      @state.tone = Tone::Error
    end

    # ボタンの割り当てを SteamVR に読ませ終えたことを受け取る。
    def rebound : Nil
      @state.rebind_pending = false
      @dirty = true
    end
  end
end

require "../spec_helper"

private def update_status(phase : String? = nil, installed : Bool = true, outcome : String? = nil) : Dashboard::UpdateStatus
  Dashboard::UpdateStatus.new(
    version: "1.2.3",
    last_checked_at: Time.utc(2026, 11, 9, 12, 0, 0),
    last_outcome: outcome,
    last_tag: outcome ? "1.3.0" : nil,
    last_finished_at: outcome ? Time.utc(2026, 11, 9, 12, 1, 0) : nil,
    phase: phase,
    service_installed: installed,
    executable: "/home/deck/.local/bin/kx-frame-controller-manager",
  )
end

private def snapshot(errors = [] of String, update = update_status) : Dashboard::Snapshot
  Dashboard::Snapshot.new(
    steamvr_connected: true,
    left: Dashboard::HandStatus.new(true, "cv.aaaaaaaaaaaa", "view"),
    right: Dashboard::HandStatus.new(false, nil, "menu"),
    link_reachable: true,
    power_save_state: "idle",
    power_save_pending: false,
    gain_range: {0.5, 1.6},
    config_errors: errors,
    update: update,
  )
end

private def build
  repository = Fakes::OverlayRepository.new
  config = Config::Usecase.new(Fakes::ConfigRepository.new("{}"))
  config.load
  translate = ->(key : String, _vars : Hash(String, String)) { key }
  usecase = Dashboard::Usecase.new(repository, config, Dashboard::View.new(translate, "1.2.3"))
  usecase.buttons = {
    PowerOff::Hand::Left  => SteamVR::Bindings::LEFT_BUTTONS,
    PowerOff::Hand::Right => SteamVR::Bindings::RIGHT_BUTTONS,
  }
  usecase.status = -> { snapshot }
  canvases = [] of Fakes::Canvas
  usecase.canvas_factory = ->(_w : Int32, _h : Int32) do
    canvas = Fakes::Canvas.new
    canvases << canvas
    canvas.as(Dashboard::Canvas?)
  end
  {usecase, repository, config, canvases}
end

# 画面の座標（左上が原点）を、オーバーレイのマウスの座標（左下が原点）にして押す。
private def click(repository : Fakes::OverlayRepository, x : Float64, y : Float64) : Nil
  repository.pending_overlay_events << SteamVR::OverlayEvent.new(SteamVR::OverlayEventKind::MouseButtonUp, x.to_f32, (Dashboard::View::HEIGHT - y).to_f32)
end

private def hit_for(usecase : Dashboard::Usecase, action : String) : Dashboard::Hit
  canvas = Fakes::Canvas.new
  hits = Dashboard::View.new(->(key : String, _vars : Hash(String, String)) { key }, "").render(canvas, usecase.state, Config::Root.default)
  hits.find { |hit| hit.action == action } || fail "#{action} が画面に無い"
end

describe Dashboard::Usecase do
  it "タブを作り、サムネイルと画面を渡す" do
    usecase, repository, _, _ = build
    usecase.tick
    repository.created.should eq 1
    repository.uploads.map(&.[0]).should eq [11_u64, 10_u64]
    repository.uploads.last.should eq({10_u64, Dashboard::View::WIDTH, Dashboard::View::HEIGHT})
  end

  it "見えていない間は描かない" do
    usecase, repository, _, _ = build
    repository.visible = false
    usecase.tick
    repository.uploads.map(&.[0]).should eq [11_u64]
  end

  it "内容が変わらなければ描き直さない" do
    usecase, repository, _, _ = build
    now = Time.instant
    usecase.tick(now)
    usecase.tick(now + 2.seconds)
    usecase.tick(now + 4.seconds)
    repository.uploads.count(&.[0].==(10_u64)).should eq 1
  end

  it "常駐の状態が変わったら描き直す" do
    usecase, repository, _, _ = build
    now = Time.instant
    usecase.tick(now)
    usecase.status = -> { snapshot(["power_off: 誤り"]) }
    usecase.tick(now + 2.seconds)
    repository.uploads.count(&.[0].==(10_u64)).should eq 2
  end

  it "押した場所の操作で設定を保存する" do
    usecase, repository, config, _ = build
    usecase.tick
    hit = hit_for(usecase, "set:power_off.enabled:+1")
    click(repository, hit.x + 1, hit.y + 1)
    usecase.tick
    config.current.power_off.enabled.should be_false
  end

  it "ボタンを変えたら、反映待ちにする" do
    usecase, _, config, _ = build
    usecase.act("set:input.right_button:+1")
    config.current.input.right_button.should eq "a"
    usecase.state.rebind_pending?.should be_true
    usecase.rebound
    usecase.state.rebind_pending?.should be_false
  end

  it "タブを切り替える" do
    usecase, _, _, _ = build
    usecase.act("tab:power")
    usecase.state.tab.should eq Dashboard::Tab::Power
  end

  it "切断は 2 回目で動き、結果を知らせる" do
    usecase, _, _, _ = build
    received = [] of Array(PowerOff::Hand)
    usecase.disconnect = ->(hands : Array(PowerOff::Hand)) do
      received << hands
      hands.map { |hand| PowerOff::Result.new(PowerOff::Target.new(hand, "x"), PowerOff::Outcome::Disconnected) }.as(Array(PowerOff::Result)?)
    end
    now = Time.instant

    usecase.act("disconnect:both", now)
    usecase.state.armed.should eq "both"
    received.should be_empty

    usecase.act("disconnect:both", now)
    sleep 10.milliseconds
    received.should eq [[PowerOff::Hand::Left, PowerOff::Hand::Right]]
    usecase.state.running?.should be_false
    usecase.state.tone.should eq Dashboard::Tone::Ok
  end

  it "1 回目の後に別の対象を押したら、そちらを確かめ待ちにする" do
    usecase, _, _, _ = build
    called = false
    usecase.disconnect = ->(_hands : Array(PowerOff::Hand)) { called = true; nil.as(Array(PowerOff::Result)?) }
    usecase.act("disconnect:left")
    usecase.act("disconnect:right")
    called.should be_false
    usecase.state.armed.should eq "right"
  end

  it "確かめ待ちは時間が経つと解ける" do
    usecase, _, _, _ = build
    now = Time.instant
    usecase.act("disconnect:left", now)
    usecase.tick(now + Dashboard::Usecase::ARM_TIMEOUT)
    usecase.state.armed.should be_nil
  end

  it "時間が経ってからの 2 回目は、1 回目として扱う" do
    usecase, _, _, _ = build
    called = false
    usecase.disconnect = ->(_hands : Array(PowerOff::Hand)) { called = true; nil.as(Array(PowerOff::Result)?) }
    now = Time.instant
    usecase.act("disconnect:left", now)
    usecase.act("disconnect:left", now + Dashboard::Usecase::ARM_TIMEOUT)
    sleep 10.milliseconds
    called.should be_false
    usecase.state.armed.should eq "left"
  end

  it "処理中で受け付けられなければ知らせる" do
    usecase, _, _, _ = build
    usecase.disconnect = ->(_hands : Array(PowerOff::Hand)) { nil.as(Array(PowerOff::Result)?) }
    usecase.act("disconnect:left")
    usecase.act("disconnect:left")
    sleep 10.milliseconds
    usecase.state.message.should eq "dashboard.disconnect.busy"
  end

  it "今すぐの更新は 2 回目で始める" do
    usecase, _, _, _ = build
    started = 0
    usecase.start_update = -> { started += 1; true }
    now = Time.instant
    usecase.act("update:run", now)
    started.should eq 0
    usecase.state.armed.should eq "update"
    usecase.act("update:run", now)
    started.should eq 1
    usecase.state.armed.should be_nil
    usecase.state.update_message.should eq "dashboard.update.started"
  end

  it "更新を始められなければ知らせる" do
    usecase, _, _, _ = build
    usecase.start_update = -> { false }
    usecase.act("update:run")
    usecase.act("update:run")
    usecase.state.update_message.should eq "dashboard.update.start_failed"
    usecase.state.update_tone.should eq Dashboard::Tone::Error
  end

  it "更新の確認は別のファイバで行い、結果を知らせる" do
    usecase, _, _, _ = build
    calls = 0
    usecase.check_update = -> { calls += 1; {"available", "1.3.0".as(String?)} }
    usecase.act("update:check")
    usecase.state.checking?.should be_true
    sleep 10.milliseconds
    calls.should eq 1
    usecase.state.checking?.should be_false
    usecase.state.update_message.should eq "dashboard.update.check.available"
    usecase.state.update_tone.should eq Dashboard::Tone::Ok
  end

  it "画面で確かめられたら、その時刻を最後の確認として見せる" do
    usecase, _, _, _ = build
    usecase.check_update = -> { {"up_to_date", nil.as(String?)} }
    usecase.act("update:check")
    sleep 10.milliseconds
    usecase.state.checked_at.should_not be_nil
  end

  it "確かめられなかったら、確認の時刻を残さない" do
    usecase, _, _, _ = build
    usecase.check_update = -> { {"unreachable", nil.as(String?)} }
    usecase.act("update:check")
    sleep 10.milliseconds
    usecase.state.checked_at.should be_nil
  end

  it "確認が例外で終わっても、確認中のままにしない" do
    usecase, _, _, _ = build
    usecase.check_update = -> { raise IO::Error.new("つながらない") }
    usecase.act("update:check")
    sleep 10.milliseconds
    usecase.state.checking?.should be_false
    usecase.state.update_message.should eq "dashboard.update.check.unreachable"
  end

  it "close でタブを消し、次の tick で作り直す" do
    usecase, repository, _, _ = build
    usecase.tick
    usecase.close
    repository.destroyed.should eq [10_u64, 11_u64]
    usecase.tick
    repository.created.should eq 2
  end

  it "OpenVR を開き直したら、前のハンドルを使わずに作り直す" do
    usecase, repository, _, _ = build
    usecase.tick
    repository.generation += 1
    usecase.tick
    repository.created.should eq 2
  end

  it "作れなかった接続では作り直さない" do
    usecase, repository, _, _ = build
    repository.fail_create = true
    usecase.tick
    usecase.tick
    repository.fail_create = false
    usecase.tick
    repository.created.should eq 0
    repository.generation += 1
    usecase.tick
    repository.created.should eq 1
  end

  it "無効にしたらタブを消し、作らない" do
    usecase, repository, _, _ = build
    usecase.tick
    usecase.apply(false)
    repository.destroyed.should eq [10_u64, 11_u64]
    usecase.tick
    repository.created.should eq 1
  end

  it "IVROverlay が使えなければ何もしない" do
    usecase, repository, _, _ = build
    repository.overlay_ok = false
    usecase.tick
    repository.created.should eq 0
  end
end

private def update_tab_hits(status : Dashboard::UpdateStatus, canvas = Fakes::Canvas.new) : Array(Dashboard::Hit)
  state = Dashboard::ViewState.new
  state.tab = Dashboard::Tab::Update
  state.snapshot = snapshot(update: status)
  Dashboard::View.new(->(key : String, _vars : Hash(String, String)) { key }, "").render(canvas, state, Config::Root.default)
end

describe Dashboard::View do
  it "どちらのタブでも、項目の操作はすべて押せる場所にある" do
    translate = ->(key : String, _vars : Hash(String, String)) { key }
    view = Dashboard::View.new(translate, "")
    actions = [] of String
    Dashboard::Tab.each do |tab|
      state = Dashboard::ViewState.new
      state.tab = tab
      actions.concat(view.render(Fakes::Canvas.new, state, Config::Root.default).map(&.action))
    end
    Dashboard::Editor::FIELDS.each do |key, field|
      actions.should contain "set:#{key}:+1"
      actions.should contain "set:#{key}:-1" unless field.kind.toggle?
    end
    actions.should contain "disconnect:both"
  end

  it "どのタブでも、押せる場所は重ならない" do
    translate = ->(key : String, _vars : Hash(String, String)) { key }
    Dashboard::Tab.each do |tab|
      state = Dashboard::ViewState.new
      state.tab = tab
      state.snapshot = snapshot
      hits = Dashboard::View.new(translate, "").render(Fakes::Canvas.new, state, Config::Root.default)
      hits.each_combination(2) do |(a, b)|
        overlap = a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
        fail "#{a.action} と #{b.action} が重なる" if overlap
      end
    end
  end

  it "更新のタブには、確認と今すぐの更新のボタンがある" do
    actions = update_tab_hits(update_status).map(&.action)
    actions.should contain "update:check"
    actions.should contain "update:run"
  end

  it "チャンネルを切り替える場所は置かず、test のときだけ版の横に添える" do
    translate = ->(key : String, _vars : Hash(String, String)) { key }
    state = Dashboard::ViewState.new
    state.tab = Dashboard::Tab::Update
    state.snapshot = snapshot

    stable = Fakes::Canvas.new
    hits = Dashboard::View.new(translate, "").render(stable, state, Config::Root.default)
    hits.none?(&.action.includes?("channel")).should be_true
    stable.texts.should_not contain "dashboard.update.version_test"

    root = Config::Root.default
    root.update.channel = "test"
    test = Fakes::Canvas.new
    hits = Dashboard::View.new(translate, "").render(test, state, root)
    hits.none?(&.action.includes?("channel")).should be_true
    test.texts.should contain "dashboard.update.version_test"
  end

  it "更新が走っている間は、どちらのボタンも押せず、段階を見せる" do
    canvas = Fakes::Canvas.new
    hits = update_tab_hits(update_status(phase: "restarting"), canvas)
    hits.none?(&.action.starts_with?("update:")).should be_true
    canvas.texts.should contain "dashboard.update.phase.restarting"
  end

  it "最後の確認には、自動更新と画面の確認のうち新しいほうの時刻を出す" do
    canvas = Fakes::Canvas.new
    state = Dashboard::ViewState.new
    state.tab = Dashboard::Tab::Update
    state.snapshot = snapshot
    later = Time.utc(2026, 11, 10, 9, 30, 0)
    state.checked_at = later
    Dashboard::View.new(->(key : String, _vars : Hash(String, String)) { key }, "").render(canvas, state, Config::Root.default)
    canvas.texts.should contain later.to_local.to_s("%Y-%m-%d %H:%M")
  end

  it "走っていなければ、最後の結末を見せる" do
    canvas = Fakes::Canvas.new
    update_tab_hits(update_status(outcome: "rolled_back"), canvas)
    canvas.texts.should contain "update.rolled_back"
  end

  it "常駐が systemd のユニットでなければ、今すぐの更新は押せない" do
    canvas = Fakes::Canvas.new
    actions = update_tab_hits(update_status(installed: false), canvas).map(&.action)
    actions.should contain "update:check"
    actions.should_not contain "update:run"
    canvas.texts.should contain "dashboard.update.not_installed"
  end

  it "切断の処理中は切断のボタンを押せない" do
    translate = ->(key : String, _vars : Hash(String, String)) { key }
    state = Dashboard::ViewState.new
    state.running = true
    hits = Dashboard::View.new(translate, "").render(Fakes::Canvas.new, state, Config::Root.default)
    hits.none?(&.action.starts_with?("disconnect:")).should be_true
  end
end

describe "Dashboard::View の多言語" do
  translate = ->(key : String, vars : Hash(String, String)) { Runtime::I18n.t(key, vars) }
  names = Runtime::I18n::CODES.to_h { |code| {code, Runtime::I18n.native_name(code)} }

  after_each { Runtime::I18n.locale = Runtime::I18n::DEFAULT_LOCALE }

  it "全般のタブに表示言語を出し、auto では今の言語の名前を添える" do
    Runtime::I18n.locale = "ko"
    state = Dashboard::ViewState.new
    state.tab = Dashboard::Tab::General
    canvas = Fakes::Canvas.new
    Dashboard::View.new(translate, "", names).render(canvas, state, Config::Root.default)
    canvas.texts.should contain "자동 (한국어)"
    canvas.texts.should contain "표시 언어"
    # 機械翻訳の言語では、そうと分かる文を出す。
    canvas.texts.join.should contain "기계 번역"
  end

  it "言語を指定したときは、その言語での名前を出す" do
    root = Config::Root.default
    root.language = "zh-Hant"
    state = Dashboard::ViewState.new
    state.tab = Dashboard::Tab::General
    canvas = Fakes::Canvas.new
    Dashboard::View.new(translate, "", names).render(canvas, state, root)
    canvas.texts.should contain "繁體中文"
    canvas.texts.join.should_not contain "機械翻訳です"
  end

  it "書体は言語の辞書に従う" do
    Runtime::I18n.locale = "zh-Hans"
    canvas = Fakes::Canvas.new
    Dashboard::View.new(translate, "", names).render(canvas, Dashboard::ViewState.new, Config::Root.default)
    canvas.font_family.should eq "Noto Sans CJK SC"
  end

  # 枠に収まらない文字列は、小さくしても収まらなければ末尾を「…」で切る。
  it "枠に収まらない項目名は末尾を切る" do
    long = ->(key : String, vars : Hash(String, String)) do
      key == "dashboard.field.power_off.enabled" ? "x" * 80 : Runtime::I18n.t(key, vars)
    end
    canvas = Fakes::Canvas.new
    Dashboard::View.new(long, "", names).render(canvas, Dashboard::ViewState.new, Config::Root.default)
    cut = canvas.texts.find(&.starts_with?("xxxx")).not_nil!
    cut.should end_with "…"
    cut.size.should be < 80
  end
end

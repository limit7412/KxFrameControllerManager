require "../spec_helper"

private def snapshot(errors = [] of String) : Dashboard::Snapshot
  Dashboard::Snapshot.new(
    steamvr_connected: true,
    left: Dashboard::HandStatus.new(true, "cv.aaaaaaaaaaaa", "view"),
    right: Dashboard::HandStatus.new(false, nil, "menu"),
    link_reachable: true,
    power_save_state: "idle",
    power_save_pending: false,
    gain_range: {0.5, 1.6},
    config_errors: errors,
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

  it "処理中で受け付けられなければ知らせる" do
    usecase, _, _, _ = build
    usecase.disconnect = ->(_hands : Array(PowerOff::Hand)) { nil.as(Array(PowerOff::Result)?) }
    usecase.act("disconnect:left")
    usecase.act("disconnect:left")
    sleep 10.milliseconds
    usecase.state.message.should eq "dashboard.disconnect.busy"
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

  it "押せる場所は重ならない" do
    translate = ->(key : String, _vars : Hash(String, String)) { key }
    hits = Dashboard::View.new(translate, "").render(Fakes::Canvas.new, Dashboard::ViewState.new, Config::Root.default)
    hits.each_combination(2) do |(a, b)|
      overlap = a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
      fail "#{a.action} と #{b.action} が重なる" if overlap
    end
  end

  it "切断の処理中は切断のボタンを押せない" do
    translate = ->(key : String, _vars : Hash(String, String)) { key }
    state = Dashboard::ViewState.new
    state.running = true
    hits = Dashboard::View.new(translate, "").render(Fakes::Canvas.new, state, Config::Root.default)
    hits.none?(&.action.starts_with?("disconnect:")).should be_true
  end
end

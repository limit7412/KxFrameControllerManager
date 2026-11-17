require "../spec_helper"

private def build(enabled = true, delay_s = 10, fade_ms = 0)
  settings = Fakes::Settings.new
  settings.floats["steamvr/analogGain"] = 1.3
  settings.strings["steamvr/performanceProfile"] = "Performance"
  settings.strings["steamvr/powersaveSteamOSManagerCustomProfile"] = "Playtime"
  store = Fakes::StateStore.new
  link = Fakes::Link.new
  link.list_result = PowerOff::ControllerList.new
  config = Config::PowerSaveSection.new
  config.enabled = enabled
  config.brightness = true
  config.delay_s = delay_s
  config.fade_ms = fade_ms
  usecase = PowerSave::Usecase.new(settings, store, link, config)
  {usecase, settings, store, link}
end

# 入る直前の確認のファイバが終わるまで待つ。
private def settle(usecase : PowerSave::Usecase) : Nil
  50.times do
    Fiber.yield
    sleep 1.millisecond
    return unless usecase.state.checking?
  end
end

private def enter(usecase : PowerSave::Usecase, base = Time.instant) : Nil
  usecase.tick(false, base)
  usecase.tick(false, base + 10.seconds)
  settle(usecase)
end

describe PowerSave::Usecase do
  it "両方が delay_s 切れていたら、値をファイルへ残してから下げる" do
    usecase, settings, store, _ = build
    base = Time.instant
    usecase.tick(false, base)
    usecase.tick(false, base + 9.seconds)
    settle(usecase)
    usecase.active?.should be_false

    usecase.tick(false, base + 10.seconds)
    settle(usecase)
    usecase.active?.should be_true
    settings.floats["steamvr/analogGain"].should eq 0.4
    settings.strings["steamvr/performanceProfile"].should eq "Playtime"

    saved = store.saved.not_nil!.values
    saved.map(&.key).should eq ["analogGain", "performanceProfile"]
    saved[0].float.should eq 1.3
    saved[1].string.should eq "Performance"
  end

  it "どちらかがつながったら元の値へ戻し、ファイルを消す" do
    usecase, settings, store, _ = build
    enter(usecase)
    usecase.tick(true)

    usecase.active?.should be_false
    settings.floats["steamvr/analogGain"].should eq 1.3
    settings.strings["steamvr/performanceProfile"].should eq "Performance"
    store.saved.should be_nil
  end

  it "元が未設定だったキーは、戻すときに消す" do
    usecase, settings, _, _ = build
    settings.floats.delete("steamvr/analogGain")
    enter(usecase)
    settings.floats["steamvr/analogGain"].should eq 0.4

    usecase.tick(true)
    settings.removed.should eq ["steamvr/analogGain"]
    settings.floats.has_key?("steamvr/analogGain").should be_false
  end

  it "brightness_gain を HMD の範囲へ収める" do
    usecase, settings, _, _ = build
    config = Config::PowerSaveSection.new
    config.enabled = true
    config.brightness = true
    config.brightness_gain = 0.1
    config.fade_ms = 0
    usecase.apply(config)
    enter(usecase)
    settings.floats["steamvr/analogGain"].should eq 0.4
  end

  it "HMD が analogGain に対応していなければ明るさは変えない" do
    usecase, settings, store, _ = build
    settings.range = nil
    enter(usecase)
    settings.floats["steamvr/analogGain"].should eq 1.3
    store.saved.not_nil!.values.map(&.key).should eq ["performanceProfile"]
  end

  it "省電力のプロファイル名を読めなければ描画のプロファイルは変えない" do
    usecase, settings, _, _ = build
    settings.strings.delete("steamvr/powersaveSteamOSManagerCustomProfile")
    enter(usecase)
    settings.strings["steamvr/performanceProfile"].should eq "Performance"
  end

  it "27062 で接続中のものがあれば入らない" do
    usecase, settings, _, link = build
    link.list_result = PowerOff::ControllerList.new([PowerOff::LinkedController.new("aaaaaaaaaaaa")])
    enter(usecase)
    usecase.active?.should be_false
    settings.writes.should be_empty
  end

  it "27062 の一覧を取れなければ OpenVR の判定だけで入る" do
    usecase, _, _, link = build
    link.list_result = nil
    enter(usecase)
    usecase.active?.should be_true
  end

  it "無効なら入らない" do
    usecase, settings, _, _ = build(enabled: false)
    enter(usecase)
    usecase.active?.should be_false
    settings.writes.should be_empty
  end

  it "省電力中に無効にされたら戻す" do
    usecase, settings, _, _ = build
    enter(usecase)
    disabled = Config::PowerSaveSection.new
    disabled.fade_ms = 0
    usecase.apply(disabled)
    usecase.tick(false)
    usecase.active?.should be_false
    settings.floats["steamvr/analogGain"].should eq 1.3
  end

  it "書き換えに失敗したら、書き換えた分を戻す" do
    usecase, settings, store, _ = build
    settings.unwritable << "steamvr/performanceProfile"
    enter(usecase)
    settings.floats["steamvr/analogGain"].should eq 1.3
    store.saved.should be_nil
  end

  it "前回戻せずに残った値があれば、つながったときに戻す" do
    usecase, settings, store, _ = build
    settings.floats["steamvr/analogGain"] = 0.4
    store.saved = PowerSave::SavedState.new([PowerSave::SavedValue.new("steamvr", "analogGain", false, float: 1.3)])

    usecase.tick(true)
    settings.floats["steamvr/analogGain"].should eq 1.3
    store.saved.should be_nil
  end

  it "shutdown で戻す" do
    usecase, settings, store, _ = build
    enter(usecase)
    usecase.shutdown
    settings.strings["steamvr/performanceProfile"].should eq "Performance"
    store.saved.should be_nil
  end

  it "設定値を扱えない間は何もしない" do
    usecase, settings, _, _ = build
    settings.available = false
    enter(usecase)
    usecase.state.should eq PowerSave::Usecase::State::Idle
  end

  it "既に省電力の値より暗ければ明るさは変えない" do
    usecase, settings, store, _ = build
    settings.floats["steamvr/analogGain"] = 0.3
    enter(usecase)
    settings.floats["steamvr/analogGain"].should eq 0.3
    store.saved.not_nil!.values.map(&.key).should eq ["performanceProfile"]
  end

  it "一覧を確かめている間に shutdown したら、その結果では入らない" do
    usecase, settings, _, _ = build
    base = Time.instant
    usecase.tick(false, base)
    usecase.tick(false, base + 10.seconds)
    usecase.state.should eq PowerSave::Usecase::State::Checking
    usecase.shutdown
    settle(usecase)

    usecase.active?.should be_false
    settings.writes.should be_empty
  end

  describe "フェード" do
    it "明るさを少しずつ下げ、下げきってから描画のプロファイルを切り替える" do
      usecase, settings, store, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      start = base + 10.seconds

      # 入った時点では、ファイルへ残しただけで何も書いていない。
      usecase.active?.should be_true
      store.saved.not_nil!.values.map(&.key).should eq ["analogGain", "performanceProfile"]
      settings.writes.should be_empty

      usecase.tick(false, start)
      usecase.tick(false, start + 1.second)
      middle = settings.floats["steamvr/analogGain"]
      (0.4 < middle < 1.3).should be_true
      # ガンマの空間で補間するため、半分の時点では直線の中間（0.85）より暗い。
      (middle < 0.85).should be_true
      settings.strings["steamvr/performanceProfile"].should eq "Performance"

      usecase.tick(false, start + 2.seconds)
      settings.floats["steamvr/analogGain"].should eq 0.4
      settings.strings["steamvr/performanceProfile"].should eq "Playtime"
      settings.written.last.should eq({"steamvr/performanceProfile", "Playtime"})
    end

    it "FADE_STEP より短い間隔では書かない" do
      usecase, settings, _, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      start = base + 10.seconds
      # 主ループと同じ 20ms ごとに 1 秒ぶん進める。
      51.times { |index| usecase.tick(false, start + (index * 20).milliseconds) }
      settings.writes.size.should eq 10
    end

    it "戻るときは描画のプロファイルを先に戻し、間を置いてから明るさを上げる" do
      usecase, settings, store, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      start = base + 10.seconds
      usecase.tick(false, start)
      usecase.tick(false, start + 2.seconds)

      back = start + 60.seconds
      usecase.tick(true, back)
      usecase.state.should eq PowerSave::Usecase::State::Restoring
      settings.strings["steamvr/performanceProfile"].should eq "Performance"
      settings.floats["steamvr/analogGain"].should eq 0.4
      # 戻し終えた描画のプロファイルは、ファイルから外す。
      store.saved.not_nil!.values.map(&.key).should eq ["analogGain"]

      # 暗転が終わるまでは明るさを上げない。
      usecase.tick(true, back)
      usecase.tick(true, back + 400.milliseconds)
      settings.floats["steamvr/analogGain"].should eq 0.4

      usecase.tick(true, back + 750.milliseconds)
      (0.4 < settings.floats["steamvr/analogGain"] < 1.3).should be_true

      # 戻すフェードは 500ms を上限にする。
      usecase.tick(true, back + 1.second)
      settings.floats["steamvr/analogGain"].should eq 1.3
      usecase.state.should eq PowerSave::Usecase::State::Idle
      store.saved.should be_nil
    end

    it "下げている途中でつながったら、その明るさから上げ、描画のプロファイルには触らない" do
      usecase, settings, store, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      start = base + 10.seconds
      usecase.tick(false, start)
      usecase.tick(false, start + 1.second)
      middle = settings.floats["steamvr/analogGain"]

      usecase.tick(true, start + 1100.milliseconds)
      usecase.state.should eq PowerSave::Usecase::State::Restoring
      usecase.tick(true, start + 1100.milliseconds)
      usecase.tick(true, start + 1300.milliseconds)
      (middle < settings.floats["steamvr/analogGain"] < 1.3).should be_true

      usecase.tick(true, start + 1600.milliseconds)
      settings.floats["steamvr/analogGain"].should eq 1.3
      settings.writes.should_not contain "steamvr/performanceProfile"
      store.saved.should be_nil
    end

    it "下げ始める前につながったら、描画のプロファイルには触らずに戻る" do
      usecase, settings, store, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      usecase.tick(true, base + 10.seconds)

      usecase.state.should eq PowerSave::Usecase::State::Idle
      settings.floats["steamvr/analogGain"].should eq 1.3
      settings.writes.should_not contain "steamvr/performanceProfile"
      store.saved.should be_nil
    end

    it "戻っている途中でまた両方が切れても、戻しきってから待ち直す" do
      usecase, settings, _, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      start = base + 10.seconds
      usecase.tick(false, start)
      usecase.tick(false, start + 2.seconds)

      back = start + 60.seconds
      usecase.tick(true, back)
      usecase.tick(false, back)
      usecase.tick(false, back + 2.seconds)
      settings.floats["steamvr/analogGain"].should eq 1.3
      usecase.state.should eq PowerSave::Usecase::State::Idle

      usecase.tick(false, back + 3.seconds)
      usecase.state.should eq PowerSave::Usecase::State::Waiting
    end

    it "下げている途中の shutdown は 1 回で戻す" do
      usecase, settings, store, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      start = base + 10.seconds
      usecase.tick(false, start)
      usecase.tick(false, start + 1.second)

      usecase.shutdown
      settings.floats["steamvr/analogGain"].should eq 1.3
      store.saved.should be_nil
      usecase.state.should eq PowerSave::Usecase::State::Idle
    end

    it "上げている途中の shutdown は 1 回で戻す" do
      usecase, settings, store, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      start = base + 10.seconds
      usecase.tick(false, start)
      usecase.tick(false, start + 2.seconds)
      usecase.tick(true, start + 60.seconds)

      usecase.shutdown
      settings.floats["steamvr/analogGain"].should eq 1.3
      store.saved.should be_nil
      usecase.state.should eq PowerSave::Usecase::State::Idle
    end

    it "下げている途中で書けなくなったら、元の明るさへ戻す" do
      usecase, settings, store, _ = build(fade_ms: 2000)
      base = Time.instant
      enter(usecase, base)
      start = base + 10.seconds
      usecase.tick(false, start)
      usecase.tick(false, start + 1.second)
      settings.unwritable << "steamvr/analogGain"
      usecase.tick(false, start + 1200.milliseconds)

      # 戻す書き込みも失敗するため、ファイルに残して次の接続でやり直す。
      store.saved.not_nil!.values.map(&.key).should eq ["analogGain"]
      settings.strings["steamvr/performanceProfile"].should eq "Performance"
    end

    it "元が未設定なら今の明るさが分からないため、1 回で切り替える" do
      usecase, settings, _, _ = build(fade_ms: 2000)
      settings.floats.delete("steamvr/analogGain")
      enter(usecase)
      settings.floats["steamvr/analogGain"].should eq 0.4
      settings.strings["steamvr/performanceProfile"].should eq "Playtime"

      usecase.tick(true)
      settings.removed.should eq ["steamvr/analogGain"]
      usecase.state.should eq PowerSave::Usecase::State::Idle
    end

    it "明るさを変えないなら、描画のプロファイルは今までどおり 1 回で切り替える" do
      usecase, settings, _, _ = build(fade_ms: 2000)
      config = Config::PowerSaveSection.new
      config.enabled = true
      config.brightness = false
      usecase.apply(config)
      enter(usecase)
      settings.strings["steamvr/performanceProfile"].should eq "Playtime"

      usecase.tick(true)
      settings.strings["steamvr/performanceProfile"].should eq "Performance"
      usecase.state.should eq PowerSave::Usecase::State::Idle
    end
  end
end

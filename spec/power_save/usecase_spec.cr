require "../spec_helper"

private def build(enabled = true, delay_s = 10)
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

# 省電力中の 27062 の確認のファイバが終わるまで待つ。
private def poll(usecase : PowerSave::Usecase) : Nil
  5.times do
    Fiber.yield
    sleep 1.millisecond
  end
end

private def enter(usecase : PowerSave::Usecase, base = Time.instant) : Nil
  usecase.tick(false, base)
  usecase.tick(false, base + 10.seconds)
  settle(usecase)
  # 入った後の初めの拍。省電力中の 27062 の確認は、ここから間を数える。
  usecase.tick(false, base + 10.seconds)
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
    usecase.apply(Config::PowerSaveSection.new)
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

  it "省電力中に 27062 で接続中のものが現れたら、OpenVR の報告を待たずに戻す" do
    usecase, settings, store, link = build
    base = Time.instant
    enter(usecase, base)
    usecase.active?.should be_true

    link.list_result = PowerOff::ControllerList.new([PowerOff::LinkedController.new("aaaaaaaaaaaa")])
    usecase.tick(false, base + 13.seconds)
    poll(usecase)
    usecase.tick(false, base + 13.seconds)

    usecase.active?.should be_false
    settings.floats["steamvr/analogGain"].should eq 1.3
    settings.strings["steamvr/performanceProfile"].should eq "Performance"
    store.saved.should be_nil
  end

  it "省電力中の 27062 の確認は間を空ける" do
    usecase, _, _, link = build
    base = Time.instant
    enter(usecase, base)
    count = link.list_count

    # 入った直後は見に行かない。入る直前に見たばかりである。
    usecase.tick(false, base + 10.seconds)
    poll(usecase)
    link.list_count.should eq count

    usecase.tick(false, base + 13.seconds)
    poll(usecase)
    usecase.tick(false, base + 13.seconds)
    poll(usecase)
    link.list_count.should eq count + 1
    usecase.active?.should be_true
  end

  it "省電力中に 27062 の一覧を取れなくても、省電力のままにする" do
    usecase, settings, _, link = build
    base = Time.instant
    enter(usecase, base)
    link.list_result = nil
    usecase.tick(false, base + 13.seconds)
    poll(usecase)
    usecase.tick(false, base + 13.seconds)

    usecase.active?.should be_true
    settings.floats["steamvr/analogGain"].should eq 0.4
  end

  it "27062 で戻った後、OpenVR の報告が遅れていても入り直さない" do
    usecase, settings, _, link = build
    base = Time.instant
    enter(usecase, base)
    link.list_result = PowerOff::ControllerList.new([PowerOff::LinkedController.new("aaaaaaaaaaaa")])
    usecase.tick(false, base + 13.seconds)
    poll(usecase)
    usecase.tick(false, base + 13.seconds)
    usecase.active?.should be_false

    usecase.tick(false, base + 14.seconds)
    usecase.tick(false, base + 24.seconds)
    settle(usecase)
    usecase.active?.should be_false
    settings.floats["steamvr/analogGain"].should eq 1.3
  end

  it "27062 を見ている間に shutdown したら、その結果では戻さない" do
    usecase, settings, _, link = build
    base = Time.instant
    enter(usecase, base)
    link.list_result = PowerOff::ControllerList.new([PowerOff::LinkedController.new("aaaaaaaaaaaa")])
    usecase.tick(false, base + 13.seconds)
    usecase.shutdown
    writes = settings.writes.size
    poll(usecase)
    usecase.tick(false, base + 13.seconds)

    usecase.state.should eq PowerSave::Usecase::State::Waiting
    settings.writes.size.should eq writes
  end
end

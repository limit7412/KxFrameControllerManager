require "../spec_helper"

private def build(target = Config::PowerOffTarget::Pressed, confirm_ms = 100)
  input = Fakes::Input.new
  haptics = Fakes::Haptics.new
  devices = Fakes::Devices.new
  link = Fakes::Link.new
  config = Config::PowerOffSection.new
  config.target = target
  config.confirm_timeout_ms = confirm_ms
  usecase = PowerOff::Usecase.new(input, haptics, devices, link, config)
  usecase.haptic_lead = 0.milliseconds
  {usecase, input, haptics, devices, link}
end

# 切断のファイバが終わるまで待つ。
private def wait_idle(usecase : PowerOff::Usecase) : Nil
  100.times do
    sleep 10.milliseconds
    return unless usecase.busy?
  end
  fail "切断の処理が終わらなかった"
end

private def hold(usecase : PowerOff::Usecase, input : Fakes::Input, hand : PowerOff::Hand) : Nil
  base = Time.instant
  input.pressed[hand] = true
  usecase.tick(base)
  usecase.tick(base + 1000.milliseconds)
  usecase.tick(base + 2000.milliseconds)
end

describe PowerOff do
  it ".link_serial は先頭の cv. だけを外す" do
    PowerOff.link_serial("cv.91481bedcdfa").should eq "91481bedcdfa"
    PowerOff.link_serial("91481bedcdfa").should eq "91481bedcdfa"
    PowerOff.link_serial("CV.91481BEDCDFA").should eq "CV.91481BEDCDFA"
  end
end

describe PowerOff::Usecase do
  describe "#tick" do
    it "長押しで押した側だけを切り、予告と切断前の振動を出す" do
      usecase, input, haptics, _, link = build
      hold(usecase, input, PowerOff::Hand::Left)
      wait_idle(usecase)

      link.sent.should eq ["aaaaaaaaaaaa"]
      haptics.pulses.size.should eq 3
      haptics.pulses.all? { |pulse| pulse[0].left? }.should be_true
      # 切断の前の 2 回は間を空ける。
      haptics.pulses[2][1].should be > 0.0
    end

    it "target が both なら左右を切る" do
      usecase, input, _, _, link = build(Config::PowerOffTarget::Both)
      hold(usecase, input, PowerOff::Hand::Right)
      wait_idle(usecase)

      link.sent.should eq ["bbbbbbbbbbbb", "aaaaaaaaaaaa"]
    end

    it "無効にしていれば切らない" do
      usecase, input, _, _, link = build
      config = Config::PowerOffSection.new
      config.enabled = false
      usecase.apply(config, Config::FeedbackSection.new)
      hold(usecase, input, PowerOff::Hand::Left)
      sleep 20.milliseconds

      link.sent.should be_empty
    end

    it "振動を無効にしていれば振動させない" do
      usecase, input, haptics, _, _ = build
      feedback = Config::FeedbackSection.new
      feedback.haptics = false
      config = Config::PowerOffSection.new
      config.confirm_timeout_ms = 100
      usecase.apply(config, feedback)
      hold(usecase, input, PowerOff::Hand::Left)
      wait_idle(usecase)

      haptics.pulses.should be_empty
    end

    it "入力が読めなくなったら押下中の判定を捨てる" do
      usecase, input, _, _, link = build
      base = Time.instant
      input.pressed[PowerOff::Hand::Left] = true
      usecase.tick(base)
      usecase.tick(base + 1000.milliseconds)
      input.ready = false
      usecase.tick(base + 1500.milliseconds)
      input.ready = true
      usecase.tick(base + 2000.milliseconds)
      sleep 20.milliseconds

      link.sent.should be_empty
    end
  end

  describe "#reset" do
    it "押下中の判定を捨て、つなぎ直した後は押した時刻から数え直す" do
      usecase, input, _, _, link = build
      base = Time.instant
      input.pressed[PowerOff::Hand::Left] = true
      usecase.tick(base)
      usecase.tick(base + 1500.milliseconds)
      usecase.reset
      usecase.tick(base + 60.seconds)
      sleep 20.milliseconds

      link.sent.should be_empty
    end
  end

  describe "#resolve" do
    it "シリアルが 27062 の接続中に無ければその手を切らない" do
      usecase, _, _, devices, _ = build
      devices.serials[PowerOff::Hand::Left] = "cv.cccccccccccc"
      usecase.resolve([PowerOff::Hand::Left, PowerOff::Hand::Right]).map(&.serial).should eq ["bbbbbbbbbbbb"]
    end

    it "27062 が報告する左右と食い違えば切らない" do
      usecase, _, _, devices, _ = build
      devices.serials[PowerOff::Hand::Left] = "cv.bbbbbbbbbbbb"
      usecase.resolve([PowerOff::Hand::Left]).should be_empty
    end

    it "27062 の一覧を取れなければ切らない" do
      usecase, _, _, _, link = build
      link.list_result = nil
      usecase.resolve([PowerOff::Hand::Left]).should be_empty
    end

    it "OpenVR のシリアルを読めなければ切らない" do
      usecase, _, _, devices, _ = build
      devices.serials.delete(PowerOff::Hand::Left)
      usecase.resolve([PowerOff::Hand::Left]).should be_empty
    end

    it "OpenVR が使えなければ 27062 の左右だけで決める" do
      usecase, _, _, devices, _ = build
      devices.available = false
      targets = usecase.resolve([PowerOff::Hand::Right])
      targets.map(&.serial).should eq ["bbbbbbbbbbbb"]
      targets.first.device_index.should be_nil
    end

    it "27062 の左右で 1 台に決まらなければ切らない" do
      usecase, _, _, devices, link = build
      devices.available = false
      link.list_result = PowerOff::ControllerList.new([PowerOff::LinkedController.new("aaaaaaaaaaaa")])
      usecase.resolve([PowerOff::Hand::Left]).should be_empty
    end
  end

  describe "#resolve_serial" do
    it "OpenVR の形で渡されても 27062 の形で照合する" do
      usecase, _, _, _, _ = build
      usecase.resolve_serial("cv.aaaaaaaaaaaa").try(&.serial).should eq "aaaaaaaaaaaa"
      usecase.resolve_serial("dddddddddddd").should be_nil
    end
  end

  describe "#execute" do
    it "OpenVR のイベントで切れたことを確かめる" do
      usecase, _, _, _, link = build(confirm_ms: 5000)
      link.ignore_disconnect = true
      target = PowerOff::Target.new(PowerOff::Hand::Left, "aaaaaaaaaaaa", 3_u32)
      spawn do
        sleep 30.milliseconds
        usecase.device_deactivated(3_u32)
      end
      started = Time.instant
      usecase.execute([target]).first.outcome.should eq PowerOff::Outcome::Disconnected
      (Time.instant - started).should be < 1.second
      link.sent.size.should eq 1
    end

    it "イベントが来なくても、27062 の一覧から消えていれば切れたとみなす" do
      usecase, _, _, _, link = build
      target = PowerOff::Target.new(PowerOff::Hand::Left, "aaaaaaaaaaaa", 3_u32)
      usecase.execute([target]).first.outcome.should eq PowerOff::Outcome::Disconnected
      link.sent.size.should eq 1
    end

    it "切れなければ 1 回だけ送り直す" do
      usecase, _, _, _, link = build
      link.ignore_disconnect = true
      target = PowerOff::Target.new(PowerOff::Hand::Left, "aaaaaaaaaaaa", 3_u32)
      usecase.execute([target]).first.outcome.should eq PowerOff::Outcome::Unconfirmed
      link.sent.size.should eq 2
    end

    it "送れなければ送り直さない" do
      usecase, _, _, _, link = build
      link.fail_send = true
      target = PowerOff::Target.new(PowerOff::Hand::Left, "aaaaaaaaaaaa")
      usecase.execute([target]).first.outcome.should eq PowerOff::Outcome::SendFailed
    end
  end
end

require "../spec_helper"

private def at(base : Time::Instant, ms : Int32) : Time::Instant
  base + ms.milliseconds
end

describe PowerOff::HoldDetector do
  it "warn_ms で予告し、hold_ms で切断する" do
    detector = PowerOff::HoldDetector.new
    base = Time.instant

    detector.update(true, base).should eq PowerOff::HoldSignal::None
    detector.update(true, at(base, 999)).should eq PowerOff::HoldSignal::None
    detector.update(true, at(base, 1000)).should eq PowerOff::HoldSignal::Warn
    detector.update(true, at(base, 1999)).should eq PowerOff::HoldSignal::None
    detector.update(true, at(base, 2000)).should eq PowerOff::HoldSignal::Fire
    detector.state.should eq PowerOff::HoldDetector::State::WaitingRelease
  end

  it "予告の前に離せば何も返さずに待機へ戻る" do
    detector = PowerOff::HoldDetector.new
    base = Time.instant

    detector.update(true, base)
    detector.update(false, at(base, 500)).should eq PowerOff::HoldSignal::None
    detector.state.should eq PowerOff::HoldDetector::State::Idle
  end

  it "予告の後に離せば中止を返す" do
    detector = PowerOff::HoldDetector.new
    base = Time.instant

    detector.update(true, base)
    detector.update(true, at(base, 1000)).should eq PowerOff::HoldSignal::Warn
    detector.update(false, at(base, 1500)).should eq PowerOff::HoldSignal::Cancel
    detector.state.should eq PowerOff::HoldDetector::State::Idle
  end

  it "離してからの押し直しは、押した時刻から数え直す" do
    detector = PowerOff::HoldDetector.new
    base = Time.instant

    detector.update(true, base)
    detector.update(false, at(base, 1500))
    detector.update(true, at(base, 1600))
    detector.update(true, at(base, 2500)).should eq PowerOff::HoldSignal::None
    detector.update(true, at(base, 2600)).should eq PowerOff::HoldSignal::Warn
  end

  it "切断の後は、離してから cooldown_ms の間は再判定しない" do
    detector = PowerOff::HoldDetector.new
    base = Time.instant

    detector.update(true, base)
    detector.update(true, at(base, 1000))
    detector.update(true, at(base, 2000)).should eq PowerOff::HoldSignal::Fire

    # 押しっぱなしの間は解放待ちのまま。
    detector.update(true, at(base, 9000)).should eq PowerOff::HoldSignal::None
    detector.update(false, at(base, 9100))
    detector.state.should eq PowerOff::HoldDetector::State::Cooldown

    # クールダウン中に押しても判定しない。
    detector.update(true, at(base, 10_000)).should eq PowerOff::HoldSignal::None
    detector.update(false, at(base, 12_099)).should eq PowerOff::HoldSignal::None
    detector.state.should eq PowerOff::HoldDetector::State::Cooldown
    detector.update(false, at(base, 12_100))
    detector.state.should eq PowerOff::HoldDetector::State::Idle
  end

  it "押したままクールダウンが明けたら、離されるまで次の判定を始めない" do
    detector = PowerOff::HoldDetector.new
    base = Time.instant

    detector.update(true, base)
    detector.update(true, at(base, 1000))
    detector.update(true, at(base, 2000))
    detector.update(false, at(base, 2100))
    detector.update(true, at(base, 5100))
    detector.state.should eq PowerOff::HoldDetector::State::WaitingRelease
    detector.update(true, at(base, 9000)).should eq PowerOff::HoldSignal::None
  end

  it "reset は押下中だけを待機へ戻し、解放待ちは保つ" do
    detector = PowerOff::HoldDetector.new
    base = Time.instant

    detector.update(true, base)
    detector.update(true, at(base, 1000))
    detector.reset
    detector.state.should eq PowerOff::HoldDetector::State::Idle

    detector.update(true, at(base, 2000))
    detector.update(true, at(base, 3000))
    detector.update(true, at(base, 4000)).should eq PowerOff::HoldSignal::Fire
    detector.reset
    detector.state.should eq PowerOff::HoldDetector::State::WaitingRelease
  end

  it "warn が 0 なら押した拍で予告する" do
    detector = PowerOff::HoldDetector.new(warn: 0.milliseconds, hold: 500.milliseconds)
    detector.update(true, Time.instant).should eq PowerOff::HoldSignal::Warn
  end
end

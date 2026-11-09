require "../spec_helper"
require "../../src/runtime/scheduler"

private def build
  repository = Fakes::SteamVRRepository.new
  steamvr = SteamVR::Usecase.new(repository, Fakes::ManifestStore.new, "/tmp/a.vrmanifest", "/tmp/a")
  scheduler = Runtime::Scheduler.new(steamvr, Error::Usecase.new, retry_interval: 10.seconds)
  {scheduler, repository, steamvr}
end

describe Runtime::Scheduler do
  it "1 拍目で接続を試す" do
    scheduler, repository, steamvr = build

    scheduler.step(Time.instant)

    repository.open_count.should eq 1
    steamvr.connected?.should be_true
  end

  # SteamVR が動いていない間に毎拍初期化すると、20 ミリ秒ごとに dlopen を繰り返す。
  it "つながらなければ間隔を空けてやり直す" do
    scheduler, repository, _ = build
    repository.unavailable = true
    start = Time.instant

    scheduler.step(start)
    scheduler.step(start + 5.seconds)
    repository.open_count.should eq 1

    scheduler.step(start + 10.seconds)
    repository.open_count.should eq 2
  end

  it "つながっている間はイベントを渡す" do
    scheduler, repository, _ = build
    received = [] of SteamVR::EventKind
    scheduler.on_events = ->(events : Array(SteamVR::Event)) { received.concat(events.map(&.kind)); nil }
    start = Time.instant
    scheduler.step(start)

    repository.push(SteamVR::EventKind::TrackedDeviceActivated)
    scheduler.step(start + 20.milliseconds)

    received.should eq [SteamVR::EventKind::TrackedDeviceActivated]
  end

  # 閉じた直後に開き直すと、終わりかけの SteamVR へ初期化を繰り返すことになる。
  it "SteamVR の終了で閉じたら、1 間隔の後に開き直す" do
    scheduler, repository, steamvr = build
    start = Time.instant
    scheduler.step(start)

    repository.push(SteamVR::EventKind::Quit)
    scheduler.step(start + 1.second)
    steamvr.connected?.should be_false

    scheduler.step(start + 2.seconds)
    repository.open_count.should eq 1

    scheduler.step(start + 11.seconds)
    repository.open_count.should eq 2
    steamvr.connected?.should be_true
  end

  it "イベントの処理で例外が出ても止まらない" do
    scheduler, repository, _ = build
    scheduler.on_events = ->(_events : Array(SteamVR::Event)) { raise "壊れた" }
    start = Time.instant
    scheduler.step(start)

    repository.push(SteamVR::EventKind::Other)
    scheduler.step(start + 20.milliseconds)
    repository.push(SteamVR::EventKind::Other)
    scheduler.step(start + 40.milliseconds)
  end
end

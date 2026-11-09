require "../spec_helper"
require "../../src/update/auto_updater"

# 自動更新の流れを確かめる。
# 実行ファイルの入れ替えは実ファイルで行い、GitHub、systemd、時刻は差し替える。

private class FakeRepository < Update::Repository
  property releases = [] of Update::Release
  property error : Exception? = nil
  property body = "新しい実行ファイル"
  getter fetches = 0

  def fetch_releases(channel : String) : Update::Catalog
    @fetches += 1
    if error = @error
      raise error
    end
    Update::Catalog.new(@releases)
  end

  def download(asset : Update::Asset, path : String) : Nil
    File.write(path, @body)
  end
end

private class MemoryStateStore < Update::StateStore
  property state = Update::State.new
  property marker : Update::RunningMarker? = nil
  property locked = false
  property save_error : Exception? = nil
  getter saves = 0

  def load : Update::State
    Update::State.from_json(@state.to_json)
  end

  def save(state : Update::State) : Nil
    @saves += 1
    if error = @save_error
      raise error
    end
    @state = Update::State.from_json(state.to_json)
  end

  def running : Update::RunningMarker?
    @marker
  end

  def try_lock : Bool
    return false if @locked
    @locked = true
  end

  def unlock : Nil
    @locked = false
  end
end

# ユニットの振る舞いを真似る。
# 再起動のたびに on_restart を呼び、新しいプロセスが印を残すかどうかを spec ごとに決める。
private class FakeService < Update::ServiceControl
  property active = true
  property pid : Int64? = 100
  property restart_result = true
  getter restarts = 0
  property on_restart : Proc(Int32, Nil) = ->(_count : Int32) { }

  def active? : Bool
    @active
  end

  def restart : Bool
    @restarts += 1
    @on_restart.call(@restarts)
    @restart_result
  end

  def main_pid : Int64?
    @active ? @pid : nil
  end
end

private class FakePreflight < Update::Preflight
  property result = true
  getter verified = [] of {String, String}

  def verify(path : String, tag : String) : Bool
    @verified << {path, tag}
    @result
  end
end

# 待つたびに時刻を進める。on_sleep で、待っている間に起きることを差し込める。
private class FakeClock < Update::Clock
  property now : Time = Time.utc(2026, 11, 9, 12, 0, 0)
  getter slept = Time::Span.zero
  property on_sleep : Proc(Nil) = -> { }

  def sleep(span : Time::Span) : Nil
    @slept += span
    @now += span
    @on_sleep.call
  end
end

private record Fixture,
  updater : Update::AutoUpdater,
  installer : Update::Installer,
  repository : FakeRepository,
  state : MemoryStateStore,
  service : FakeService,
  preflight : FakePreflight,
  clock : FakeClock,
  executable : String

private def release(tag : String, body : String) : Update::Release
  Update::Release.new(
    Update::Version.parse?(tag).not_nil!,
    tag,
    "https://example.test/#{tag}",
    false,
    Update::Asset.new(Digest::SHA256.hexdigest(body), "https://example.test/#{tag}/asset", body.bytesize.to_i64),
  )
end

private def with_updater(running : String = "1.0.0", & : Fixture -> Nil) : Nil
  directory = File.join(Dir.tempdir, "kxfcm-auto-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(directory)
  begin
    executable = File.join(directory, "kx-frame-controller-manager")
    File.write(executable, "実行中の実行ファイル")
    repository = FakeRepository.new
    repository.releases = [release("1.1.0", repository.body)]
    installer = Update::Installer.new(repository, running, executable, "#{executable}.new")
    state = MemoryStateStore.new
    service = FakeService.new
    preflight = FakePreflight.new
    clock = FakeClock.new
    updater = Update::AutoUpdater.new(repository, installer, state, service, preflight, running, clock)
    yield Fixture.new(updater, installer, repository, state, service, preflight, clock, executable)
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def settings(auto_update : Bool = true, check_enabled : Bool = true, interval : Int32 = 6) : Config::UpdateSection
  section = Config::UpdateSection.new
  section.auto_update = auto_update
  section.check_enabled = check_enabled
  section.check_interval_h = interval
  section
end

# 再起動すると、新しい版のプロセス（pid 200）が印を残すようにする。
private def start_new_version(fixture : Fixture, tag : String = "1.1.0") : Nil
  service = fixture.service
  state = fixture.state
  service.on_restart = ->(_count : Int32) do
    service.pid = 200_i64
    state.marker = Update::RunningMarker.new(tag, 200_i64)
    nil
  end
end

describe Update::AutoUpdater do
  describe "設定と間隔" do
    it "auto_update が偽なら確かめない" do
      with_updater do |fixture|
        fixture.updater.run(settings(auto_update: false)).outcome.should eq Update::RunOutcome::Disabled
        fixture.repository.fetches.should eq 0
      end
    end

    it "check_enabled が偽なら auto_update が真でも確かめない" do
      with_updater do |fixture|
        fixture.updater.run(settings(check_enabled: false)).outcome.should eq Update::RunOutcome::Disabled
      end
    end

    it "手で実行したときは設定の無効を見ない" do
      with_updater do |fixture|
        fixture.service.active = false
        fixture.updater.run(settings(auto_update: false), manual: true).outcome.should eq Update::RunOutcome::Applied
      end
    end

    it "前回の確認から間隔が経っていなければ確かめない" do
      with_updater do |fixture|
        fixture.state.state.last_checked_at = fixture.clock.now - 5.hours
        fixture.updater.run(settings(interval: 6)).outcome.should eq Update::RunOutcome::NotDue
        fixture.repository.fetches.should eq 0
      end
    end

    it "間隔が経っていれば確かめ、確かめた時刻を残す" do
      with_updater do |fixture|
        fixture.repository.releases = [] of Update::Release
        fixture.state.state.last_checked_at = fixture.clock.now - 6.hours
        fixture.updater.run(settings(interval: 6)).outcome.should eq Update::RunOutcome::UpToDate
        fixture.state.state.last_checked_at.should eq fixture.clock.now
      end
    end

    it "前回の確認が未来にあるなら、経ったものとして確かめる" do
      with_updater do |fixture|
        fixture.repository.releases = [] of Update::Release
        fixture.state.state.last_checked_at = fixture.clock.now + 1.day
        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::UpToDate
      end
    end

    it "確かめられなくても時刻を残し、失敗として返す" do
      with_updater do |fixture|
        fixture.repository.error = IO::Error.new("つながらない")
        result = fixture.updater.run(settings)
        result.outcome.should eq Update::RunOutcome::Unreachable
        result.outcome.failure?.should be_true
        fixture.state.state.last_checked_at.should eq fixture.clock.now
      end
    end

    it "別の更新が走っていれば何もしない" do
      with_updater do |fixture|
        fixture.state.locked = true
        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::Busy
        fixture.repository.fetches.should eq 0
      end
    end

    it "終わったら排他を外す" do
      with_updater do |fixture|
        fixture.repository.releases = [] of Update::Release
        fixture.updater.run(settings)
        fixture.state.locked.should be_false
      end
    end
  end

  describe "置き換え" do
    it "ユニットが動いていなければ置き換えるだけで再起動しない" do
      with_updater do |fixture|
        fixture.service.active = false
        result = fixture.updater.run(settings)

        result.outcome.should eq Update::RunOutcome::Applied
        result.tag.should eq "1.1.0"
        File.read(fixture.executable).should eq fixture.repository.body
        File.read(fixture.installer.backup_path).should eq "実行中の実行ファイル"
        fixture.service.restarts.should eq 0
      end
    end

    it "置き換える前に、取得したものを試しに起動する" do
      with_updater do |fixture|
        fixture.service.active = false
        fixture.updater.run(settings)
        fixture.preflight.verified.should eq [{fixture.installer.staged_path, "1.1.0"}]
      end
    end

    it "試しの起動が通らなければ置き換えず、その版を覚えて次から入れない" do
      with_updater do |fixture|
        fixture.preflight.result = false
        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::Failed

        File.read(fixture.executable).should eq "実行中の実行ファイル"
        File.exists?(fixture.installer.staged_path).should be_false
        fixture.state.state.rejected.should eq ["1.1.0"]

        fixture.clock.now += 7.hours
        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::Rejected
      end
    end

    it "再起動して新しい版が印を残し、動き続ければ置き換えを終える" do
      with_updater do |fixture|
        start_new_version(fixture)
        result = fixture.updater.run(settings)

        result.outcome.should eq Update::RunOutcome::Restarted
        fixture.service.restarts.should eq 1
        File.read(fixture.executable).should eq fixture.repository.body
        fixture.state.state.rejected.should be_empty
        fixture.clock.slept.should eq Update::AutoUpdater::STABLE_FOR
      end
    end

    it "印を待つ間はポーリングし、現れたら確かめに進む" do
      with_updater do |fixture|
        service = fixture.service
        state = fixture.state
        service.on_restart = ->(_count : Int32) { service.pid = 200_i64; nil }
        polls = 0
        fixture.clock.on_sleep = -> do
          polls += 1
          state.marker = Update::RunningMarker.new("1.1.0", 200_i64) if polls == 3
          nil
        end

        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::Restarted
        fixture.clock.slept.should eq Update::AutoUpdater::POLL_INTERVAL * 3 + Update::AutoUpdater::STABLE_FOR
      end
    end
  end

  describe "巻き戻し" do
    it "新しい版が印を残さなければ元へ戻し、再起動してその版を覚える" do
      with_updater do |fixture|
        fixture.service.on_restart = ->(_count : Int32) { fixture.service.pid = 200_i64; nil }
        result = fixture.updater.run(settings)

        result.outcome.should eq Update::RunOutcome::RolledBack
        File.read(fixture.executable).should eq "実行中の実行ファイル"
        fixture.service.restarts.should eq 2
        fixture.state.state.rejected.should eq ["1.1.0"]
        fixture.clock.slept.should be >= Update::AutoUpdater::START_TIMEOUT
      end
    end

    # 印は古い版のものが残っている。版を見ないと、古い版の印を新しい版の起動と取り違える。
    it "古い版の印が残っていても、新しい版の起動とはみなさない" do
      with_updater do |fixture|
        fixture.state.marker = Update::RunningMarker.new("1.0.0", 100_i64)
        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::RolledBack
      end
    end

    it "起動した後に落ちて systemd が起動し直したなら、元へ戻す" do
      with_updater do |fixture|
        start_new_version(fixture)
        service = fixture.service
        state = fixture.state
        fixture.clock.on_sleep = -> do
          service.pid = 300_i64
          state.marker = Update::RunningMarker.new("1.1.0", 300_i64)
          nil
        end

        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::RolledBack
        File.read(fixture.executable).should eq "実行中の実行ファイル"
      end
    end

    it "再起動の呼び出しが失敗したら元へ戻す" do
      with_updater do |fixture|
        fixture.service.restart_result = false
        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::RolledBack
        File.read(fixture.executable).should eq "実行中の実行ファイル"
      end
    end

    # 記録は巻き戻しの必須条件ではない。投げたまま抜けると、起動しない版が置かれたまま残る。
    it "戻した版を記録できなくても元へ戻す" do
      with_updater do |fixture|
        fixture.service.on_restart = ->(_count : Int32) do
          fixture.state.save_error = File::Error.new("空きが無い", file: "update.json")
          nil
        end
        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::RolledBack
        File.read(fixture.executable).should eq "実行中の実行ファイル"
        fixture.service.restarts.should eq 2
      end
    end

    it "戻す先が無ければ RollbackFailed を返す" do
      with_updater do |fixture|
        installer = fixture.installer
        fixture.service.on_restart = ->(_count : Int32) { File.delete?(installer.backup_path); nil }
        result = fixture.updater.run(settings)

        result.outcome.should eq Update::RunOutcome::RollbackFailed
        result.outcome.failure?.should be_true
        fixture.state.state.rejected.should eq ["1.1.0"]
      end
    end

    it "戻した版は自動では入れないが、手で実行すれば入れる" do
      with_updater do |fixture|
        fixture.state.state.reject("1.1.0")
        fixture.updater.run(settings).outcome.should eq Update::RunOutcome::Rejected

        start_new_version(fixture)
        fixture.updater.run(settings, manual: true).outcome.should eq Update::RunOutcome::Restarted
      end
    end
  end
end

describe Update::ProcessPreflight do
  it "出力が版として一致すれば通す。タグの v は無視する" do
    Update::ProcessPreflight.matches?(true, "1.2.3\n", "v1.2.3").should be_true
    Update::ProcessPreflight.matches?(true, "1.2.3-test4\n", "1.2.3-test4").should be_true
  end

  it "版が違うか、失敗で終わったものは通さない" do
    Update::ProcessPreflight.matches?(true, "1.2.2\n", "1.2.3").should be_false
    Update::ProcessPreflight.matches?(false, "1.2.3\n", "1.2.3").should be_false
    Update::ProcessPreflight.matches?(true, "", "1.2.3").should be_false
  end

  it "実際に起動して出力を見る" do
    directory = File.tempname("kxfcm-preflight")
    Dir.mkdir_p(directory)
    begin
      script = File.join(directory, "kx")
      File.write(script, "#!/bin/sh\n[ \"$1\" = version ] && echo 1.2.3\n")
      File.chmod(script, 0o755)

      preflight = Update::ProcessPreflight.new
      preflight.verify(script, "1.2.3").should be_true
      preflight.verify(script, "1.2.4").should be_false
      preflight.verify(File.join(directory, "missing"), "1.2.3").should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe Update do
  it "check_interval_h は 1 から 168 の範囲だけを受け付ける" do
    Update.validate(settings(interval: 1)).should be_empty
    Update.validate(settings(interval: 168)).should be_empty
    Update.validate(settings(interval: 0)).should_not be_empty
    Update.validate(settings(interval: 169)).should_not be_empty
  end
end

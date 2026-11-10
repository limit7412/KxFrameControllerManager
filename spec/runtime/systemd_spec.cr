require "../spec_helper"

private class FakeSystemctl < Runtime::Systemd::Systemctl
  getter calls = [] of Array(String)
  # 出力を捨てた呼び出し。calls にも同じものを積む。
  getter quiet_calls = [] of Array(String)
  property fail = false

  def run(arguments : Array(String), quiet : Bool = false) : Bool
    @calls << arguments
    @quiet_calls << arguments if quiet
    !@fail
  end

  def active? : Bool
    false
  end
end

describe Runtime::Systemd do
  it "ユニットに実行ファイルの絶対パスを埋め、% を逃がす" do
    unit = Runtime::Systemd.unit("/home/deck/.local/bin/kx%frame")
    unit.should contain %(ExecStart="/home/deck/.local/bin/kx%%frame" run)
    unit.should contain "Restart=on-failure"
    unit.should contain "RestartSec=10"
    unit.should contain "StartLimitBurst=5"
    unit.should contain "WantedBy=default.target"
    unit.should_not contain "@EXECUTABLE@"
  end

  it "自動更新のタイマーが書き出されているかを見る" do
    directory = File.tempname("kxfcm-systemd")
    begin
      Dir.mkdir_p(directory)
      path = File.join(directory, Runtime::Systemd::UNIT_NAME)
      Runtime::Systemd.update_timer_installed?(path).should be_false
      File.write(File.join(directory, Runtime::Systemd::UPDATE_TIMER_NAME), "x")
      Runtime::Systemd.update_timer_installed?(path).should be_true
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "ExecStart を壊す文字を含むパスは受け付けない" do
    expect_raises(ArgumentError) { Runtime::Systemd.unit(%(/home/deck/"x)) }
  end

  it "install はユニットを書いて有効にし、起動し直す" do
    directory = File.tempname("kxfcm-systemd")
    begin
      path = File.join(directory, "systemd", "user", Runtime::Systemd::UNIT_NAME)
      systemctl = FakeSystemctl.new
      Runtime::Systemd.install("/home/deck/.local/bin/kx", path, systemctl).should be_true

      File.read(path).should contain %(ExecStart="/home/deck/.local/bin/kx" run)
      user = File.dirname(path)
      File.read(File.join(user, Runtime::Systemd::UPDATE_UNIT_NAME)).should contain %(ExecStart="/home/deck/.local/bin/kx" update --auto)
      File.read(File.join(user, Runtime::Systemd::UPDATE_TIMER_NAME)).should contain "OnUnitActiveSec=30min"
      systemctl.calls.should eq [
        ["daemon-reload"],
        ["enable", Runtime::Systemd::UNIT_NAME],
        ["restart", Runtime::Systemd::UNIT_NAME],
        ["enable", "--now", Runtime::Systemd::UPDATE_TIMER_NAME],
      ]
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "uninstall は止めてからユニットを消す" do
    directory = File.tempname("kxfcm-systemd")
    begin
      Dir.mkdir_p(directory)
      path = File.join(directory, Runtime::Systemd::UNIT_NAME)
      update_unit = File.join(directory, Runtime::Systemd::UPDATE_UNIT_NAME)
      timer = File.join(directory, Runtime::Systemd::UPDATE_TIMER_NAME)
      [path, update_unit, timer].each { |file| File.write(file, "x") }
      systemctl = FakeSystemctl.new
      # 走っている自動更新を待つのは、タイマーを止めた後、常駐を止める前である。
      waited_after = nil.as(Array(Array(String))?)
      Runtime::Systemd.uninstall(path, systemctl, -> { waited_after = systemctl.calls.dup; nil }).should be_true
      waited_after.should eq [["disable", "--now", Runtime::Systemd::UPDATE_TIMER_NAME]]

      [path, update_unit, timer].each { |file| File.exists?(file).should be_false }
      systemctl.calls.should eq [
        ["disable", "--now", Runtime::Systemd::UPDATE_TIMER_NAME],
        ["disable", "--now", Runtime::Systemd::UNIT_NAME],
        ["daemon-reload"],
      ]
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "自動起動の状態は、enable が default.target.wants に置くリンクで見る" do
    directory = File.tempname("kxfcm-systemd")
    begin
      Dir.mkdir_p(File.join(directory, "default.target.wants"))
      path = File.join(directory, Runtime::Systemd::UNIT_NAME)
      File.write(path, "x")
      Runtime::Systemd.installed?(path).should be_true
      Runtime::Systemd.autostart_enabled?(path).should be_false
      File.symlink(path, File.join(directory, "default.target.wants", Runtime::Systemd::UNIT_NAME))
      Runtime::Systemd.autostart_enabled?(path).should be_true
      Runtime::Systemd.installed?(File.join(directory, "missing.service")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "自動起動の切り替えは enable と disable だけを呼び、常駐の起動と停止はしない" do
    systemctl = FakeSystemctl.new
    Runtime::Systemd.set_autostart(false, systemctl).should be_true
    Runtime::Systemd.set_autostart(true, systemctl).should be_true
    systemctl.calls.should eq [
      ["disable", "--quiet", Runtime::Systemd::UNIT_NAME],
      ["enable", "--quiet", Runtime::Systemd::UNIT_NAME],
    ]
  end

  it "start は起動の回数の制限を解いてから起動し、stop は止めるだけにする" do
    systemctl = FakeSystemctl.new
    Runtime::Systemd.start(systemctl).should be_true
    Runtime::Systemd.stop(systemctl).should be_true
    systemctl.calls.should eq [
      ["reset-failed", Runtime::Systemd::UNIT_NAME],
      ["start", Runtime::Systemd::UNIT_NAME],
      ["stop", Runtime::Systemd::UNIT_NAME],
    ]
    # 読み込まれていないユニットの reset-failed は失敗して警告を出すが、起動には差し支えない。
    systemctl.quiet_calls.should eq [["reset-failed", Runtime::Systemd::UNIT_NAME]]
  end
end

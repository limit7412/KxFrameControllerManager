require "../spec_helper"

private class FakeSystemctl < Runtime::Systemd::Systemctl
  getter calls = [] of Array(String)
  property fail = false

  def run(arguments : Array(String)) : Bool
    @calls << arguments
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
      Runtime::Systemd.uninstall(path, systemctl).should be_true

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
end

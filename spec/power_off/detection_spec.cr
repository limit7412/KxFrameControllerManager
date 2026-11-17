require "../spec_helper"

private def with_file(&)
  directory = File.join(Dir.tempdir, "kxfcm-detection-#{Random::Secure.hex(4)}")
  begin
    yield PowerOff::DetectionFile.new(File.join(directory, "state", "detection.json"))
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def report(state = PowerOff::Detection::Ready)
  PowerOff::DetectionReport.new(state, 4321_i64, Time.utc(2026, 11, 17, 9, 0, 0))
end

describe PowerOff::DetectionReport do
  it "本ツールが run として動いているときだけ、記録を信じる" do
    report.current?("/home/deck/.local/bin/kx-frame-controller-manager\0run\0").should be_true
  end

  it "書いたプロセスがいなければ信じない" do
    report.current?(nil).should be_false
  end

  it "番号を使い回した別のプロセスの記録は信じない" do
    report.current?("/usr/bin/bash\0-c\0sleep 10\0").should be_false
    # status や update も同じ実行ファイルだが、常駐ではない。
    report.current?("/home/deck/.local/bin/kx-frame-controller-manager\0status\0").should be_false
    report.current?("").should be_false
  end
end

describe PowerOff::DetectionFile do
  it "書いた記録を読み戻す" do
    with_file do |file|
      file.save(report(PowerOff::Detection::Failed))
      loaded = file.load.not_nil!
      loaded.state.should eq PowerOff::Detection::Failed
      loaded.pid.should eq 4321
      loaded.since.should eq Time.utc(2026, 11, 17, 9, 0, 0)
      File.exists?("#{file.path}.tmp").should be_false
    end
  end

  it "ファイルが無ければ nil を返す" do
    with_file { |file| file.load.should be_nil }
  end

  it "読めない内容と知らない状態は nil にする" do
    with_file do |file|
      Dir.mkdir_p(File.dirname(file.path))
      File.write(file.path, "{")
      file.load.should be_nil
      File.write(file.path, %({"state":"later_version","pid":1,"since":"2026-11-17T09:00:00Z"}))
      file.load.should be_nil
    end
  end

  it "消した後は読めない。無いファイルを消しても失敗しない" do
    with_file do |file|
      file.save(report)
      file.delete
      file.load.should be_nil
      file.delete
    end
  end
end

describe PowerOff::DetectionRecorder do
  it "状態が変わったときだけ書く" do
    with_file do |file|
      recorder = PowerOff::DetectionRecorder.new(file, 77_i64)
      first = Time.utc(2026, 11, 17, 9, 0, 0)
      recorder.record(PowerOff::Detection::Failed, first)
      recorder.record(PowerOff::Detection::Failed, first + 10.seconds)
      loaded = file.load.not_nil!
      loaded.state.should eq PowerOff::Detection::Failed
      loaded.pid.should eq 77
      # 失敗が続いている間は、初めに失敗した時刻を保つ。
      loaded.since.should eq first

      recorder.record(PowerOff::Detection::Ready, first + 20.seconds)
      loaded = file.load.not_nil!
      loaded.state.should eq PowerOff::Detection::Ready
      loaded.since.should eq first + 20.seconds
    end
  end

  it "消した後は、同じ状態でも書き直す" do
    with_file do |file|
      recorder = PowerOff::DetectionRecorder.new(file, 77_i64)
      recorder.record(PowerOff::Detection::Ready)
      recorder.clear
      file.load.should be_nil
      recorder.record(PowerOff::Detection::Ready)
      file.load.not_nil!.state.should eq PowerOff::Detection::Ready
    end
  end

  it "書けなかった状態は、変わるまで書き直さない" do
    with_file do |file|
      # 置き場所の親をファイルにして、書き込みを失敗させる。
      Dir.mkdir_p(File.dirname(File.dirname(file.path)))
      File.write(File.dirname(file.path), "")
      recorder = PowerOff::DetectionRecorder.new(file, 77_i64)
      expect_raises(File::Error) { recorder.record(PowerOff::Detection::Ready) }
      recorder.record(PowerOff::Detection::Ready)
    end
  end
end

describe PowerOff::Detection do
  it "有効でつながっているのに検出できない状態だけを異常とする" do
    broken = PowerOff::Detection.values.select(&.broken?)
    broken.should eq [PowerOff::Detection::Failed, PowerOff::Detection::Unavailable]
  end
end

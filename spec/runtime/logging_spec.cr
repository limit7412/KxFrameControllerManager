require "../spec_helper"
require "../../src/runtime/logging"

private def entry(message : String, exception : Exception? = nil) : ::Log::Entry
  ::Log::Entry.new("steamvr", ::Log::Severity::Warn, message, ::Log::Metadata.empty, exception)
end

describe Runtime::DailyFileBackend do
  it "日付ごとのファイルへ書き、世代を超えた古いものを消す" do
    directory = File.tempname("kxfcm-spec")
    Dir.mkdir_p(directory)
    (1..3).each { |day| File.write(File.join(directory, "kx-frame-controller-manager-2026-01-0#{day}.log"), "") }

    backend = Runtime::DailyFileBackend.new(directory, generations: 2)
    backend.write(entry("書いた"))
    backend.close

    logs = Dir.children(directory).sort
    logs.size.should eq 2
    logs.last.should eq "kx-frame-controller-manager-#{Time.local.to_s("%Y-%m-%d")}.log"
    File.read(File.join(directory, logs.last)).should contain "[WARN] steamvr - 書いた"
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end

describe Runtime::StderrBackend do
  # 時刻は journald が付けるため書かない。
  it "時刻を付けずに 1 行で書く" do
    io = IO::Memory.new
    backend = Runtime::StderrBackend.new(io)

    backend.write(entry("つながらない", Exception.new("理由")))

    io.to_s.should eq "[WARN] steamvr - つながらない (Exception: 理由)\n"
  end
end

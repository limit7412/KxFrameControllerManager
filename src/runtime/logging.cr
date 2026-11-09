require "log"
require "./paths"

module Runtime
  # 日次ローテーションでログを書き出すバックエンド。
  # 世代数を超えた古いファイルは書き出しのタイミングで消す。
  class DailyFileBackend < ::Log::Backend
    GENERATIONS = 7
    FILE_PREFIX = "kx-frame-controller-manager"

    def initialize(@directory : String, @generations : Int32 = GENERATIONS)
      super(:direct)
      @date = ""
      @file = nil.as(File?)
    end

    def write(entry : ::Log::Entry) : Nil
      file = rotate(entry.timestamp)
      return unless file

      file << entry.timestamp.to_s("%Y-%m-%dT%H:%M:%S.%3N%:z")
      file << " [" << entry.severity.label << "] " << entry.source << " - " << entry.message << '\n'
      if exception = entry.exception
        file << "  " << exception.class << ": " << exception.message << '\n'
      end
      file.flush
    rescue
      # ログの書き出し失敗で常駐を止めるわけにはいかないため、ここでは握りつぶす。
    end

    def close : Nil
      @file.try(&.close)
      @file = nil
    end

    private def rotate(timestamp : Time) : File?
      date = timestamp.to_s("%Y-%m-%d")
      return @file if date == @date && @file

      @file.try(&.close)
      Dir.mkdir_p(@directory)
      @date = date
      @file = File.open(File.join(@directory, "#{FILE_PREFIX}-#{date}.log"), "a")
      prune
      @file
    end

    private def prune : Nil
      logs = Dir.glob(File.join(@directory, "#{FILE_PREFIX}-*.log")).sort
      return if logs.size <= @generations
      logs[0...(logs.size - @generations)].each { |path| File.delete(path) rescue nil }
    end
  end

  # 標準エラーへ書くバックエンド。
  #
  # systemd 下では標準エラーが journald へ渡るため、`journalctl --user -u` でも同じログが読める。
  # 時刻は journald が付けるので書かない。
  class StderrBackend < ::Log::IOBackend
    FORMATTER = ::Log::Formatter.new do |entry, io|
      io << '[' << entry.severity.label << "] " << entry.source << " - " << entry.message
      if exception = entry.exception
        io << " (" << exception.class << ": " << exception.message << ')'
      end
    end

    def initialize(io : IO = STDERR)
      super(io, formatter: FORMATTER, dispatcher: :direct)
    end
  end

  module Logging
    # ログレベルを差し替える。
    # バックエンドは開いたファイルを抱えるため、composition root が持つものを使い回す。
    def self.setup(backends : Array(::Log::Backend), level : String = "info") : Nil
      severity = severity(level)
      ::Log.setup do |config|
        backends.each { |backend| config.bind("*", severity, backend) }
      end
    end

    def self.severity(level : String) : ::Log::Severity
      ::Log::Severity.parse(level)
    rescue
      ::Log::Severity::Info
    end
  end
end

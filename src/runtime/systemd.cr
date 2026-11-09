require "log"
require "./paths"

module Runtime
  # systemd のユーザーユニットの書き出しと systemctl --user の呼び出し（仕様書 3.7 節、6.2 節）。
  #
  # linger は有効にしない。ログアウト中も動かす必要は無い（仕様書 6.2 節）。
  module Systemd
    Log = ::Log.for("systemd")

    UNIT_NAME = "kx-frame-controller-manager.service"

    # 雛形はコンパイル時に埋め込む。配布物の実行ファイルは単体でも install できるようにする。
    TEMPLATE = {{ read_file("#{__DIR__}/../../packaging/kx-frame-controller-manager.service") }}

    # 実行ファイルのパスを埋めたユニットの中身。
    #
    # systemd はユニットの中の % を指定子として読むため、パスの % は %% にする。
    # 引用符と改行は ExecStart の書式を壊すため、そういうパスは受け付けない。
    def self.unit(executable : String) : String
      if executable.includes?('"') || executable.includes?('\n') || executable.includes?('\\')
        raise ArgumentError.new("ユニットに書けない文字が実行ファイルのパスに含まれている: #{executable}")
      end
      TEMPLATE.gsub("@EXECUTABLE@", executable.gsub("%", "%%"))
    end

    # systemctl --user の呼び出し。spec では差し替えて呼び出しを記録する。
    class Systemctl
      # 呼び出しが成功したら true を返す。出力はそのまま利用者へ見せる。
      def run(arguments : Array(String)) : Bool
        Process.run("systemctl", ["--user"] + arguments, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).success?
      rescue exception : File::NotFoundError | IO::Error
        Log.error { "systemctl を呼べなかった: #{exception.message}" }
        false
      end

      # ユニットが動いているか。出力は見せない。
      def active? : Bool
        Process.run("systemctl", ["--user", "is-active", "--quiet", UNIT_NAME]).success?
      rescue File::NotFoundError | IO::Error
        false
      end
    end

    # ユニットを書き出して有効にし、起動する。
    def self.install(executable : String, unit_path : String = Paths.systemd_unit_path, systemctl : Systemctl = Systemctl.new) : Bool
      Dir.mkdir_p(File.dirname(unit_path))
      File.write(unit_path, unit(executable))
      Log.info { "ユニットを書き出した: #{unit_path}" }

      systemctl.run(["daemon-reload"]) &&
        systemctl.run(["enable", UNIT_NAME]) &&
        # 既に動いていれば、書き換えたユニットと実行ファイルで起動し直す。
        systemctl.run(["restart", UNIT_NAME])
    end

    # ユニットを止めて無効にし、消す。
    #
    # 止めるのに失敗しても先へ進む。ユニットが既に無効な場合も disable は失敗を返しうるためである。
    def self.uninstall(unit_path : String = Paths.systemd_unit_path, systemctl : Systemctl = Systemctl.new) : Bool
      systemctl.run(["disable", "--now", UNIT_NAME])
      File.delete?(unit_path)
      Log.info { "ユニットを消した: #{unit_path}" }
      systemctl.run(["daemon-reload"])
    end
  end
end

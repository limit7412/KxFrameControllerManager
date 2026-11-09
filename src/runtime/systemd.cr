require "log"
require "../update/auto_updater"
require "./paths"

module Runtime
  # systemd のユーザーユニットの書き出しと systemctl --user の呼び出し（仕様書 3.7 節、6.2 節）。
  #
  # linger は有効にしない。ログアウト中も動かす必要は無い（仕様書 6.2 節）。
  module Systemd
    Log = ::Log.for("systemd")

    UNIT_NAME = "kx-frame-controller-manager.service"
    # 自動更新のユニットとタイマー。タイマーが 30 分ごとにユニットを起こす。
    UPDATE_UNIT_NAME  = "kx-frame-controller-manager-update.service"
    UPDATE_TIMER_NAME = "kx-frame-controller-manager-update.timer"

    # 雛形はコンパイル時に埋め込む。配布物の実行ファイルは単体でも install できるようにする。
    TEMPLATE              = {{ read_file("#{__DIR__}/../../packaging/kx-frame-controller-manager.service") }}
    UPDATE_UNIT_TEMPLATE  = {{ read_file("#{__DIR__}/../../packaging/kx-frame-controller-manager-update.service") }}
    UPDATE_TIMER_TEMPLATE = {{ read_file("#{__DIR__}/../../packaging/kx-frame-controller-manager-update.timer") }}

    # 実行ファイルのパスを埋めたユニットの中身。
    #
    # systemd はユニットの中の % を指定子として読むため、パスの % は %% にする。
    # 引用符と改行は ExecStart の書式を壊すため、そういうパスは受け付けない。
    def self.unit(executable : String, template : String = TEMPLATE) : String
      if executable.includes?('"') || executable.includes?('\n') || executable.includes?('\\')
        raise ArgumentError.new("ユニットに書けない文字が実行ファイルのパスに含まれている: #{executable}")
      end
      template.gsub("@EXECUTABLE@", executable.gsub("%", "%%"))
    end

    # 書き出すユニットの名前と中身。常駐のユニットと同じディレクトリに置く。
    def self.units(executable : String) : Hash(String, String)
      {
        UNIT_NAME         => unit(executable),
        UPDATE_UNIT_NAME  => unit(executable, UPDATE_UNIT_TEMPLATE),
        UPDATE_TIMER_NAME => UPDATE_TIMER_TEMPLATE,
      }
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

      # ユニットの主プロセスの番号。動いていなければ systemd は 0 を返すので、そのときは nil にする。
      def main_pid : Int64?
        output = IO::Memory.new
        status = Process.run("systemctl", ["--user", "show", "--property=MainPID", "--value", UNIT_NAME], output: output)
        return nil unless status.success?
        pid = output.to_s.strip.to_i64?
        pid && pid > 0 ? pid : nil
      rescue File::NotFoundError | IO::Error
        nil
      end
    end

    # 自動更新のタイマーが書き出されているか。
    # 自動更新より前の版から `update` で上げた環境には無い。`install` をやり直すまで置かれない。
    def self.update_timer_installed?(unit_path : String = Paths.systemd_unit_path) : Bool
      File.exists?(File.join(File.dirname(unit_path), UPDATE_TIMER_NAME))
    end

    # 自動更新から常駐のユニットを操作する。
    class UpdateService < Update::ServiceControl
      def initialize(@systemctl : Systemctl = Systemctl.new)
      end

      def active? : Bool
        @systemctl.active?
      end

      def restart : Bool
        @systemctl.run(["restart", UNIT_NAME])
      end

      def main_pid : Int64?
        @systemctl.main_pid
      end
    end

    # ユニットを書き出して有効にし、起動する。自動更新のタイマーも書き出して有効にする。
    #
    # タイマーは update.auto_update が偽でも有効にする。起きても設定を見て何もせずに終わるだけであり、
    # 設定を真へ戻したときに install をやり直さずに済む。
    def self.install(executable : String, unit_path : String = Paths.systemd_unit_path, systemctl : Systemctl = Systemctl.new) : Bool
      directory = File.dirname(unit_path)
      Dir.mkdir_p(directory)
      units(executable).each do |name, content|
        path = name == UNIT_NAME ? unit_path : File.join(directory, name)
        File.write(path, content)
        Log.info { "ユニットを書き出した: #{path}" }
      end

      systemctl.run(["daemon-reload"]) &&
        systemctl.run(["enable", UNIT_NAME]) &&
        # 既に動いていれば、書き換えたユニットと実行ファイルで起動し直す。
        systemctl.run(["restart", UNIT_NAME]) &&
        systemctl.run(["enable", "--now", UPDATE_TIMER_NAME])
    end

    # ユニットを止めて無効にし、消す。
    #
    # 止めるのに失敗しても先へ進む。ユニットが既に無効な場合も disable は失敗を返しうるためである。
    # タイマーを先に止め、走っている自動更新が終わるのを wait_for_update で待ってから常駐を止める。
    # タイマーを止めても、既に起きた自動更新のユニットは止まらない。待たずに常駐を止めると、
    # 自動更新は取得を終えた後に実行ファイルを置き換え、常駐が止まったのを起動の失敗と取り違えて巻き戻す。
    def self.uninstall(
      unit_path : String = Paths.systemd_unit_path,
      systemctl : Systemctl = Systemctl.new,
      wait_for_update : Proc(Nil) = -> { },
    ) : Bool
      systemctl.run(["disable", "--now", UPDATE_TIMER_NAME])
      wait_for_update.call
      systemctl.run(["disable", "--now", UNIT_NAME])
      directory = File.dirname(unit_path)
      File.delete?(unit_path)
      File.delete?(File.join(directory, UPDATE_UNIT_NAME))
      File.delete?(File.join(directory, UPDATE_TIMER_NAME))
      Log.info { "ユニットを消した: #{unit_path}" }
      systemctl.run(["daemon-reload"])
    end
  end
end

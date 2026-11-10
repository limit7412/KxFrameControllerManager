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
      #
      # quiet が真なら出力を捨てる。失敗しても構わない呼び出し（reset-failed）の警告を見せないために使う。
      def run(arguments : Array(String), quiet : Bool = false) : Bool
        redirect = quiet ? Process::Redirect::Close : Process::Redirect::Inherit
        Process.run("systemctl", ["--user"] + arguments, output: redirect, error: redirect).success?
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

    # 設定画面から始める今すぐの更新のユニット。systemd-run で一時的に作り、終われば消える。
    MANUAL_UPDATE_UNIT_NAME = "kx-frame-controller-manager-update-now"

    # 今すぐの更新を、常駐とは別のユニットで始める。
    #
    # 常駐の子プロセスとして `update` を走らせると、常駐のユニットを再起動したときに一緒に止められる。
    # 新しい版の起動を確かめ、駄目なら戻す者がいなくなるため、systemd-run で別のユニットにする。
    # 同じ名前のユニットが走っていれば systemd-run は断るので、重ねて押しても 2 つは走らない。
    # 手で打った `update` と同じく、設定の無効と間隔、前に戻した版の記録は見ない。
    def self.start_manual_update(executable : String) : Bool
      arguments = ["--user", "--unit=#{MANUAL_UPDATE_UNIT_NAME}", "--collect", "--quiet", executable, "update"]
      status = Process.run("systemd-run", arguments, output: Process::Redirect::Close, error: Process::Redirect::Close)
      Log.error { "今すぐの更新を始められなかった（systemd-run の終了コード #{status.exit_code}）" } unless status.success?
      status.success?
    rescue exception : File::NotFoundError | IO::Error
      Log.error { "systemd-run を呼べなかった: #{exception.message}" }
      false
    end

    # 自動更新のタイマーが書き出されているか。
    # 自動更新より前の版から `update` で上げた環境には無い。`install` をやり直すまで置かれない。
    def self.update_timer_installed?(unit_path : String = Paths.systemd_unit_path) : Bool
      File.exists?(File.join(File.dirname(unit_path), UPDATE_TIMER_NAME))
    end

    # 常駐のユニットが書き出されているか。`install` を経ずに `run` を直接起動した環境には無い。
    def self.installed?(unit_path : String = Paths.systemd_unit_path) : Bool
      File.exists?(unit_path)
    end

    # 自動起動が有効か。`systemctl --user enable` が置くリンクがあるかで見る。
    #
    # systemctl is-enabled を呼ばずにリンクを見るのは、設定画面が状態を 1 秒ごとに読み直すためである。
    # そのたびにプロセスを起こすのは重い。ユニットの WantedBy は default.target なので、リンクはその .wants に置かれる。
    def self.autostart_enabled?(unit_path : String = Paths.systemd_unit_path) : Bool
      link = File.join(File.dirname(unit_path), "default.target.wants", UNIT_NAME)
      !File.info?(link, follow_symlinks: false).nil?
    end

    # 自動起動を切り替える。enable と disable はユニットの起動と停止をしないので、今の常駐はそのまま動き続ける。
    #
    # 自動更新のタイマーは切り替えない。タイマーから起きた更新は、常駐が動いていなければ置き換えるだけで起動しない
    # （Update::AutoUpdater）。自動起動を切っても、更新が常駐を勝手に起こすことは無い。
    def self.set_autostart(enabled : Bool, systemctl : Systemctl = Systemctl.new) : Bool
      systemctl.run([enabled ? "enable" : "disable", "--quiet", UNIT_NAME])
    end

    # 常駐を起動する。起動の回数の制限に掛かっていれば、それを解いてから起動する。
    #
    # reset-failed は、ユニットが読み込まれていなければ「not loaded」と失敗する。
    # 自動起動を切って Frame を起動し直した後がそうであり、起動には差し支えないので、出力を捨てて結果も見ない。
    def self.start(systemctl : Systemctl = Systemctl.new) : Bool
      systemctl.run(["reset-failed", UNIT_NAME], quiet: true)
      systemctl.run(["start", UNIT_NAME])
    end

    # 常駐を止める。止めた常駐は、次にログインするまで（自動起動が有効なら）か `start` まで動かない。
    def self.stop(systemctl : Systemctl = Systemctl.new) : Bool
      systemctl.run(["stop", UNIT_NAME])
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

      def reset_failed : Nil
        @systemctl.run(["reset-failed", UNIT_NAME], quiet: true)
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

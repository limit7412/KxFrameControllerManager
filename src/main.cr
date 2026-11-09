require "log"

require "./config/models"
require "./config/repository"
require "./config/usecase"
require "./error/usecase"
require "./runtime/paths"
require "./runtime/logging"
require "./runtime/i18n"
require "./runtime/scheduler"
require "./steamvr/repository"
require "./steamvr/openvr_repository"
require "./steamvr/usecase"

# composition root。
#
# 各コンテキストを組み立てて依存を注入し、主ループを回す。ロジックは持たない。
# 長押しの判定（power_off）、27062 との通信（frame_link）、省電力（power_save）、
# CLI の残りのコマンド（status、list、disconnect、install、uninstall、update）は、
# それぞれのコンテキストを足すときにここへ組み込む（仕様書 4.1 節、5.4 節）。
module KxFrameControllerManager
  # リリースのワークフローが、タグから決めた値を KXFCM_VERSION で渡す。
  # 渡されなければ手元ビルドとして 0.1.0-dev にする。この綴りは版として比べられず、
  # 更新の確認は「比べられない」と答える。
  VERSION = {{ (env("KXFCM_VERSION") || "") == "" ? "0.1.0-dev" : env("KXFCM_VERSION") }}

  # 常駐（`run` コマンド）。
  class Resident
    Log = ::Log.for("main")

    def initialize
      @file_backend = Runtime::DailyFileBackend.new(Runtime::Paths.log_directory)
      @backends = [@file_backend, Runtime::StderrBackend.new] of ::Log::Backend
      Runtime::Logging.setup(@backends)

      @errors = Error::Usecase.new
      @errors.log_text = ->(key : String) { Runtime::I18n.log_text(key) }

      @config = Config::Usecase.new(Config::FileRepository.new(Runtime::Paths.config_path))

      @openvr = SteamVR::OpenVRRepository.new
      @steamvr = SteamVR::Usecase.new(
        @openvr,
        SteamVR::FileManifestStore.new,
        Runtime::Paths.manifest_path,
        Runtime::Paths.executable_path,
      )
      @scheduler = Runtime::Scheduler.new(@steamvr, @errors)

      # シグナルのハンドラは別のファイバで走る。主ループはこの印を見て動く。
      @stop_requested = false
      @reload_requested = false
    end

    def run : Int32
      Log.info { "KxFrameControllerManager #{VERSION} を起動する: #{Runtime::Paths.executable_path}" }

      load_config
      trap_signals

      until @stop_requested
        reload_config if @reload_requested
        @scheduler.step
        sleep @scheduler.poll_interval
      end

      @steamvr.disconnect
      Log.info { "終了する" }
      0
    ensure
      @file_backend.close
    end

    private def load_config : Nil
      @config.on_apply = ->(root : Config::Root) { apply(root) }
      errors = @config.load
      return if errors.empty?

      # 読めなかったとき、usecase は既定値で動き、on_apply を呼ばない。既定値を自分で反映する。
      apply(@config.current)
      STDERR.puts Runtime::I18n.t("cli.config_invalid")
      errors.each { |error| STDERR.puts "  #{error}" }
    end

    private def reload_config : Nil
      @reload_requested = false
      @errors.guard("error.config_reload") { @config.reload }
    end

    # 検証を通った設定を各所へ配る。
    private def apply(root : Config::Root) : Nil
      Runtime::Logging.setup(@backends, root.log_level)
      Runtime::I18n.locale = Runtime::I18n.resolve(root.language)
      @openvr.library_path = root.steamvr.openvr_library_path
      @scheduler.retry_interval = root.steamvr.retry_interval_s.seconds
      @scheduler.poll_interval = root.input.poll_interval_ms.milliseconds
    end

    # SIGTERM と SIGINT で終わり、SIGHUP で設定を読み直す（仕様書 5.2 節、6.1 節）。
    # systemd の stop は SIGTERM を、reload は SIGHUP を送る。
    private def trap_signals : Nil
      Signal::TERM.trap { @stop_requested = true }
      Signal::INT.trap { @stop_requested = true }
      Signal::HUP.trap { @reload_requested = true }
    end
  end

  # コマンドを解釈して実行し、終了コードを返す（仕様書 3.7 節）。
  def self.main(args : Array(String)) : Int32
    Runtime::I18n.locale = Runtime::I18n.resolve("auto")

    case command = args.first?
    when "run"
      Resident.new.run
    when "version", "--version"
      puts VERSION
      0
    when nil, "help", "--help", "-h"
      puts Runtime::I18n.t("cli.usage")
      command ? 0 : 2
    else
      STDERR.puts Runtime::I18n.t("cli.unknown_command", {"command" => command})
      STDERR.puts Runtime::I18n.t("cli.usage")
      2
    end
  end
end

exit KxFrameControllerManager.main(ARGV)

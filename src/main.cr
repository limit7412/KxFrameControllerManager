require "log"

require "./config/models"
require "./config/repository"
require "./config/usecase"
require "./error/usecase"
require "./frame_link/websocket_repository"
require "./power_off/usecase"
require "./power_save/usecase"
require "./runtime/cli"
require "./runtime/i18n"
require "./runtime/logging"
require "./runtime/paths"
require "./runtime/scheduler"
require "./runtime/systemd"
require "./steamvr/device_repository"
require "./steamvr/input_repository"
require "./steamvr/openvr_repository"
require "./steamvr/repository"
require "./steamvr/settings_repository"
require "./steamvr/usecase"
require "./update/auto_updater"
require "./update/installer"
require "./update/repository"
require "./update/usecase"

# composition root。
#
# 各コンテキストを組み立てて依存を注入し、コマンドを実行する。ロジックは持たない。
module KxFrameControllerManager
  # リリースのワークフローが、タグから決めた値を KXFCM_VERSION で渡す。
  # 渡されなければ手元ビルドとして 0.1.0-dev にする。この綴りは版として比べられず、
  # 更新の確認は「比べられない」と答える。
  VERSION = {{ (env("KXFCM_VERSION") || "") == "" ? "0.1.0-dev" : env("KXFCM_VERSION") }}

  # SteamVR Input のアクションマニフェストと既定バインド（仕様書 5.4 節）。
  # コンパイル時に埋め込み、SteamVR へつながるたびに書き出す。
  ACTION_FILES = {
    "actions.json"                   => {{ read_file("#{__DIR__}/../actions/actions.json") }},
    "bindings_frame_controller.json" => {{ read_file("#{__DIR__}/../actions/bindings_frame_controller.json") }},
  }

  # 常駐と CLI の両方で使う部品の組み立て。
  class Parts
    getter openvr : SteamVR::OpenVRRepository
    getter steamvr : SteamVR::Usecase
    getter actions : SteamVR::InputActions
    getter devices : SteamVR::DeviceRepository
    getter link : FrameLink::WebSocketRepository
    getter power_off : PowerOff::Usecase
    getter power_save : PowerSave::Usecase

    def initialize(root : Config::Root)
      @openvr = SteamVR::OpenVRRepository.new
      @steamvr = SteamVR::Usecase.new(
        @openvr,
        SteamVR::FileManifestStore.new,
        Runtime::Paths.manifest_path,
        Runtime::Paths.executable_path,
        Runtime::Paths.action_manifest_path,
      )
      @steamvr.action_files = ACTION_FILES.to_h { |name, content| {File.join(Runtime::Paths.actions_directory, name), content} }

      @actions = SteamVR::InputActions.new(@openvr, Runtime::Paths.action_manifest_path)
      @devices = SteamVR::DeviceRepository.new(@openvr)
      @link = FrameLink::WebSocketRepository.new(root.frame_link.port)
      @power_off = PowerOff::Usecase.new(
        SteamVR::InputRepository.new(@openvr, @actions),
        SteamVR::HapticRepository.new(@openvr, @actions),
        @devices,
        @link,
        root.power_off,
        root.feedback,
      )
      @power_save = PowerSave::Usecase.new(
        SteamVR::SettingsRepository.new(@openvr),
        PowerSave::FileStateRepository.new(Runtime::Paths.power_save_state_path),
        @link,
        root.power_save,
      )
      apply(root)
    end

    # 検証を通った設定を各所へ配る。
    def apply(root : Config::Root) : Nil
      @openvr.library_path = root.steamvr.openvr_library_path
      @actions.priority = root.input.priority
      @link.port = root.frame_link.port
      @power_off.apply(root.power_off, root.feedback)
      @power_save.apply(root.power_save)
    end

    # どちらかのコントローラーが OpenVR でつながっているか。
    def any_controller_connected? : Bool
      PowerOff::Hand.values.any? { |hand| @devices.connected?(hand) }
    end
  end

  # 常駐（`run` コマンド）。
  class Resident
    Log = ::Log.for("main")

    def initialize
      @file_backend = Runtime::DailyFileBackend.new(Runtime::Paths.log_directory)
      @backends = [@file_backend, Runtime::StderrBackend.new] of ::Log::Backend
      Runtime::Logging.setup(@backends)

      @errors = Error::Usecase.new
      @errors.log_text = ->(key : String) { Runtime::I18n.log_text(key) }

      @config = KxFrameControllerManager.config_usecase(Config::FileRepository.new(Runtime::Paths.config_path))
      @parts = Parts.new(@config.current)
      @scheduler = Runtime::Scheduler.new(@parts.steamvr, @errors)
      wire

      # シグナルのハンドラは別のファイバで走る。主ループはこの印を見て動く。
      @stop_requested = false
      @reload_requested = false
      # 27062 の疎通を確かめた接続の番号。つながるたびに 1 回だけ確かめる（仕様書 4.2 節）。
      @probed_generation = nil.as(Int32?)
    end

    def run : Int32
      Log.info { "KxFrameControllerManager #{VERSION} を起動する: #{Runtime::Paths.executable_path}" }

      load_config
      trap_signals
      mark_running
      check_update

      until @stop_requested
        reload_config if @reload_requested
        @scheduler.step
        sleep @scheduler.poll_interval
      end

      # 省電力で変えた値は、OpenVR を閉じる前に戻す。
      @errors.guard("error.power_save") { @parts.power_save.shutdown }
      @parts.steamvr.disconnect
      Log.info { "終了する" }
      0
    ensure
      @file_backend.close
    end

    private def wire : Nil
      parts = @parts
      @scheduler.on_events = ->(events : Array(SteamVR::Event)) do
        events.each do |event|
          parts.power_off.device_deactivated(event.device_index) if event.kind.tracked_device_deactivated?
        end
      end
      @scheduler.on_tick = ->(now : Time::Instant) do
        probe_link
        @errors.guard("error.power_off") { parts.power_off.tick(now) }
        @errors.guard("error.power_save") { parts.power_save.tick(parts.any_controller_connected?, now) }
      end
      parts.steamvr.before_close = -> do
        parts.power_off.reset
        @errors.guard("error.power_save") { parts.power_save.shutdown }
      end
    end

    # つながるたびに 27062 から一覧を取り、疎通を確かめる。
    # 失敗しても常駐は続け、切断の直前にもう一度試す（仕様書 4.2 節）。
    private def probe_link : Nil
      generation = @parts.openvr.generation
      return if @probed_generation == generation
      @probed_generation = generation
      # 終了のイベントを受けずにつなぎ直した場合に備え、ここでも押下中の判定を捨てる。
      @parts.power_off.reset

      link = @parts.link
      spawn(name: "probe_link") do
        if list = link.list
          Log.info { "27062 に届いた。接続中: #{list.connected.map(&.serial).join(", ").presence || "なし"}" }
        else
          Log.warn { "27062 に届かなかった。切断の直前にもう一度試す" }
        end
      end
    end

    # 起動したことを残す。自動更新は、置き換えた版がここまで来たことで起動を確かめる。
    private def mark_running : Nil
      @errors.guard("error.update") do
        Update::FileStateStore.write_marker(Runtime::Paths.running_marker_path, VERSION, Process.pid)
      end
    end

    # 起動時に 1 回だけ新しい版を探し、見つけたらログに残す。
    # 置き換えは自動更新のタイマーか `update` コマンドが行う。
    private def check_update : Nil
      update = @config.current.update
      return unless update.check_enabled
      # 自動更新が有効でタイマーもあるなら、タイマーが確かめて置き換える。ここで重ねて API を叩かない。
      # タイマーが無い（自動更新より前の版から `update` で上げた）環境では、従来どおりここで確かめて知らせる。
      return if update.auto_update && Runtime::Systemd.update_timer_installed?

      spawn(name: "check_update") do
        usecase = Update::Usecase.new(Update::GitHubRepository.new("KxFrameControllerManager/#{VERSION}"))
        result = usecase.check(VERSION, update.channel)
        if release = result.release
          Log.info { "新しい版 #{release.tag} が出ている。`kx-frame-controller-manager update` で置き換えられる" }
          if update.auto_update
            Log.info { "自動更新のタイマーが無い。`kx-frame-controller-manager install` をやり直すと自動で置き換わる" }
          end
        end
      end
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

    private def apply(root : Config::Root) : Nil
      Runtime::Logging.setup(@backends, root.log_level)
      Runtime::I18n.locale = Runtime::I18n.resolve(root.language)
      @parts.apply(root)
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

  # 常駐以外のコマンド（仕様書 3.7 節）。
  #
  # どれも一度だけ実行して終わる。常駐が動いていても並べて使える。
  # SteamVR へは常駐と別のアプリとしてつなぐ。Background で開くため、SteamVR が動いていなければ起こさない。
  class Tool
    @root : Config::Root

    def initialize
      @root = read_config
      level = %w[trace debug].includes?(@root.log_level) ? @root.log_level : "warn"
      Runtime::Logging.setup([Runtime::StderrBackend.new] of ::Log::Backend, level)
      Runtime::I18n.locale = Runtime::I18n.resolve(@root.language)
    end

    def t(key : String, vars = {} of String => String) : String
      Runtime::I18n.t(key, vars)
    end

    # SteamVR と 27062 の疎通、左右のシリアルと照合の結果を表示する。
    def status : Int32
      with_parts do |parts|
        if parts.steamvr.connected?
          puts t("status.steamvr_connected")
          PowerOff::Hand.each do |hand|
            serial = parts.devices.serial(hand)
            state = parts.devices.connected?(hand) ? t("status.connected") : t("status.not_connected")
            puts t("status.hand", {"hand" => hand.label, "serial" => serial || "-", "state" => state})
          end
        else
          puts t("status.steamvr_unavailable")
        end

        list = parts.link.list
        if list
          puts t("status.link_ok")
          print_list(list)
          if parts.steamvr.connected?
            PowerOff::Hand.each do |hand|
              matched = parts.power_off.resolve([hand], list).size == 1
              puts t(matched ? "status.match_ok" : "status.match_ng", {"hand" => hand.label})
            end
          end
        else
          puts t("status.link_ng")
        end

        puts t("status.power_save_pending") if File.exists?(Runtime::Paths.power_save_state_path)
        list ? 0 : 1
      end
    end

    # 27062 から取ったコントローラーの一覧を表示する。
    def list : Int32
      link = FrameLink::WebSocketRepository.new(@root.frame_link.port)
      list = link.list
      unless list
        STDERR.puts t("status.link_ng")
        return 1
      end
      print_list(list)
      0
    end

    # 長押しを経ずに切断する。
    def disconnect(argument : String) : Int32
      with_parts do |parts|
        power_off = parts.power_off
        targets = case argument
                  when "left"  then power_off.resolve([PowerOff::Hand::Left])
                  when "right" then power_off.resolve([PowerOff::Hand::Right])
                  when "both"  then power_off.resolve([PowerOff::Hand::Left, PowerOff::Hand::Right])
                  else              [power_off.resolve_serial(argument)].compact
                  end
        if targets.empty?
          STDERR.puts t("disconnect.no_target", {"target" => argument})
          next 1
        end

        # 確認を待つ間も OpenVR のイベントを読み、切れたことを早く知る。
        running = true
        if parts.steamvr.connected?
          spawn(name: "cli_events") do
            while running && parts.steamvr.connected?
              parts.steamvr.poll.each do |event|
                power_off.device_deactivated(event.device_index) if event.kind.tracked_device_deactivated?
              end
              sleep 20.milliseconds
            end
          end
        end

        results = power_off.execute(targets)
        running = false
        results.each do |result|
          puts t("disconnect.#{result.outcome.to_s.underscore}", {"target" => result.target.label, "serial" => result.target.serial})
        end
        results.all?(&.outcome.disconnected?) ? 0 : 1
      end
    end

    def install : Int32
      executable = Runtime::Paths.executable_path
      if Runtime::Systemd.install(executable)
        puts t("install.done", {"path" => Runtime::Paths.systemd_unit_path, "executable" => executable})
        0
      else
        STDERR.puts t("install.failed")
        1
      end
    rescue exception : ArgumentError | File::Error
      STDERR.puts exception.message
      1
    end

    def uninstall : Int32
      state = Update::FileStateStore.new(Runtime::Paths.update_state_path, Runtime::Paths.running_marker_path, Runtime::Paths.update_lock_path)
      # 排他は消し終わるまで持つ。その間に手で打った `update` が置き換えを始めないようにする。
      removed = begin
        Runtime::Systemd.uninstall(wait_for_update: -> { state.lock; nil })
      ensure
        state.unlock
      end
      if removed
        puts t("uninstall.done")
        0
      else
        STDERR.puts t("uninstall.failed")
        1
      end
    end

    # GitHub Releases を見て新しい版があれば置き換え、ユニットを再起動して起動を確かめる。
    # 起動しなければ元の版へ戻す。
    #
    # auto が真なのは自動更新のタイマーから呼ばれたときである。設定の有効と間隔に従い、
    # 前に戻した版は入れない。ログは journald で読めるよう、設定のログレベルで標準エラーへ出す。
    def update(auto : Bool = false) : Int32
      if auto
        Runtime::Logging.setup([Runtime::StderrBackend.new] of ::Log::Backend, @root.log_level)
      end

      repository = Update::GitHubRepository.new("KxFrameControllerManager/#{VERSION}")
      installer = Update::Installer.new(repository, VERSION, Runtime::Paths.executable_path, Runtime::Paths.staged_executable_path)
      state = Update::FileStateStore.new(Runtime::Paths.update_state_path, Runtime::Paths.running_marker_path, Runtime::Paths.update_lock_path)
      updater = Update::AutoUpdater.new(repository, installer, state, Runtime::Systemd::UpdateService.new, Update::ProcessPreflight.new, VERSION)

      result = updater.run(@root.update, manual: !auto)
      vars = {"version" => VERSION, "tag" => result.tag || "", "path" => Runtime::Paths.executable_path}
      message = t("update.#{result.outcome.to_s.underscore}", vars)
      if result.outcome.failure? || result.outcome.rejected?
        STDERR.puts message
      elsif !(auto && (result.outcome.disabled? || result.outcome.not_due?))
        # タイマーは 30 分ごとに起きる。何もしなかった回まで journald に残すと読みにくい。
        puts message
      end
      result.outcome.failure? ? 1 : 0
    end

    # 部品を組み立てて SteamVR へ 1 回だけつなぎ、終わったら閉じる。
    # SteamVR が動いていなくても block は呼ぶ。27062 だけでできることはそちらで行う。
    private def with_parts(& : Parts -> Int32) : Int32
      parts = Parts.new(@root)
      parts.steamvr.connect
      begin
        yield parts
      ensure
        parts.steamvr.disconnect
      end
    end

    private def print_list(list : PowerOff::ControllerList) : Nil
      if list.connected.empty?
        puts t("list.no_connected")
      else
        list.connected.each do |controller|
          puts t("list.connected", {"serial" => controller.serial, "hand" => controller.hand.try(&.label) || "?"})
        end
      end
      list.paired.reject { |serial| list.connected?(serial) }.each do |serial|
        puts t("list.paired", {"serial" => serial})
      end
    end

    # 設定を読むだけで書き出さない。無い、または不正なら既定値を使う。
    # CLI が設定ファイルを作ると、常駐の初回の書き出しと食い違う余地が生まれる。
    private def read_config : Config::Root
      repository = Config::FileRepository.new(Runtime::Paths.config_path)
      return Config::Root.default unless repository.exists?
      root = repository.load
      errors = KxFrameControllerManager.config_usecase(repository).validate(root)
      return root if errors.empty?
      STDERR.puts Runtime::I18n.t("cli.config_invalid")
      errors.each { |error| STDERR.puts "  #{error}" }
      Config::Root.default
    rescue exception : JSON::Error | File::Error
      STDERR.puts Runtime::I18n.t("cli.config_invalid")
      STDERR.puts "  #{exception.message}"
      Config::Root.default
    end
  end

  # 設定の usecase に、各コンテキストの検証を登録して返す。
  # 常駐と CLI で同じ検証を通すため、組み立てはここだけで行う。
  def self.config_usecase(repository : Config::Repository) : Config::Usecase
    usecase = Config::Usecase.new(repository)
    usecase.register_validator("update") { |root| Update.validate(root.update) }
    usecase
  end

  # コマンドを解釈して実行し、終了コードを返す（仕様書 3.7 節）。
  def self.main(args : Array(String)) : Int32
    Runtime::I18n.locale = Runtime::I18n.resolve("auto")

    parsed = Runtime::CLI.parse(args)
    if error = parsed.error
      unless error.empty?
        STDERR.puts Runtime::I18n.t(error, {"command" => parsed.argument || "", "argument" => parsed.argument || ""})
      end
      STDERR.puts Runtime::I18n.t("cli.usage")
      return 2
    end

    case parsed.command
    in .run?        then Resident.new.run
    in .status?     then Tool.new.status
    in .list?       then Tool.new.list
    in .disconnect? then Tool.new.disconnect(parsed.argument.not_nil!)
    in .install?    then Tool.new.install
    in .uninstall?  then Tool.new.uninstall
    in .update?     then Tool.new.update(auto: parsed.argument == Runtime::CLI::AUTO)
    in .version?
      puts VERSION
      0
    in .help?
      puts Runtime::I18n.t("cli.usage")
      0
    end
  end
end

exit KxFrameControllerManager.main(ARGV)

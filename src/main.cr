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
require "./runtime/steam_client"
require "./runtime/systemd"
require "./steamvr/bindings"
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
require "./dashboard/cairo"
require "./dashboard/usecase"

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
  # 既定バインドは雛形として使い、長押しのボタンを設定から差し込んでから書き出す。
  ACTION_FILES = {
    "actions.json"                   => {{ read_file("#{__DIR__}/../actions/actions.json") }},
    "bindings_frame_controller.json" => {{ read_file("#{__DIR__}/../actions/bindings_frame_controller.json") }},
  }

  BINDINGS_FILE = "bindings_frame_controller.json"
  ACTIONS_FILE  = "actions.json"

  # 設定 language から使う言語を決める。auto なら Steam の表示言語と環境変数から決める。
  def self.resolve_locale(setting : String) : String
    steam = setting == Runtime::I18n::AUTO ? Runtime::SteamClient.language : nil
    Runtime::I18n.resolve(setting, ENV, steam)
  end

  # 設定の検証の誤りを、今の言語の文にする。
  def self.describe(error : Config::ValidationError) : String
    error.localize(->(key : String, vars : Hash(String, String)) { Runtime::I18n.t(key, vars) })
  end

  # 全言語の辞書から、SteamVR へ渡す文字列の表を作る。
  # SteamVR は Steam の表示言語に合う札の文字列を選ぶため、今の言語に依らず全言語ぶんを渡す。
  def self.steamvr_descriptions : Hash(String, String)
    Runtime::I18n::CODES.to_h do |code|
      {Runtime::I18n.steamvr_tag(code).downcase, Runtime::I18n.t_in(code, "steamvr.description")}
    end
  end

  def self.action_localization : Array(Hash(String, String))
    Runtime::I18n::CODES.map do |code|
      {
        "language_tag"                => Runtime::I18n.steamvr_tag(code),
        "/actions/kxfcm"              => Runtime::I18n.t_in(code, "steamvr.action_set"),
        "/actions/kxfcm/in/power_off" => Runtime::I18n.t_in(code, "steamvr.action.power_off"),
        "/actions/kxfcm/out/haptic"   => Runtime::I18n.t_in(code, "steamvr.action.haptic"),
      }
    end
  end

  # 常駐と CLI の両方で使う部品の組み立て。
  class Parts
    getter openvr : SteamVR::OpenVRRepository
    getter steamvr : SteamVR::Usecase
    getter actions : SteamVR::InputActions
    getter devices : SteamVR::DeviceRepository
    getter link : FrameLink::WebSocketRepository
    getter power_off : PowerOff::Usecase
    getter power_save : PowerSave::Usecase
    getter settings : SteamVR::SettingsRepository

    def initialize(root : Config::Root)
      # 既定バインドを書き換えたら、SteamVR へつなぎ直して読ませる。apply が立て、常駐の主ループが見る。
      @rebind_pending = false
      @openvr = SteamVR::OpenVRRepository.new
      @steamvr = SteamVR::Usecase.new(
        @openvr,
        SteamVR::FileManifestStore.new,
        Runtime::Paths.manifest_path,
        Runtime::Paths.executable_path,
        Runtime::Paths.action_manifest_path,
      )
      @steamvr.action_files = action_files(root.input)
      @steamvr.descriptions = KxFrameControllerManager.steamvr_descriptions

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
      @settings = SteamVR::SettingsRepository.new(@openvr)
      @power_save = PowerSave::Usecase.new(
        @settings,
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

      files = action_files(root.input)
      unless files == @steamvr.action_files
        @steamvr.action_files = files
        @rebind_pending = true
      end
    end

    # 既定バインドを書き換えてから、まだ SteamVR へ読ませていなければ真を返し、印を下ろす。
    def take_rebind : Bool
      pending = @rebind_pending
      @rebind_pending = false
      pending
    end

    # 書き出すアクションマニフェストと既定バインド。キーは書き出す先の絶対パスである。
    private def action_files(input : Config::InputSection) : Hash(String, String)
      ACTION_FILES.to_h do |name, content|
        content = SteamVR::Bindings.render(content, input) if name == BINDINGS_FILE
        content = SteamVR::Bindings.localize(content, KxFrameControllerManager.action_localization) if name == ACTIONS_FILE
        {File.join(Runtime::Paths.actions_directory, name), content}
      end
    end

    # どちらかのコントローラーが OpenVR でつながっているか。
    def any_controller_connected? : Bool
      PowerOff::Hand.values.any? { |hand| @devices.connected?(hand) }
    end
  end

  # 常駐（`run` コマンド）。
  class Resident
    Log = ::Log.for("main")

    @dashboard : Dashboard::Usecase

    def initialize
      @file_backend = Runtime::DailyFileBackend.new(Runtime::Paths.log_directory)
      @backends = [@file_backend, Runtime::StderrBackend.new] of ::Log::Backend
      Runtime::Logging.setup(@backends)

      @errors = Error::Usecase.new
      @errors.log_text = ->(key : String) { Runtime::I18n.log_text(key) }

      @config = KxFrameControllerManager.config_usecase(Config::FileRepository.new(Runtime::Paths.config_path))
      @parts = Parts.new(@config.current)
      @scheduler = Runtime::Scheduler.new(@parts.steamvr, @errors)
      # 最後に 27062 の疎通を確かめた結果と、最後に読んだ設定の誤り。設定画面へ見せる。
      @link_reachable = nil.as(Bool?)
      @config_errors = [] of Config::ValidationError
      @dashboard = build_dashboard
      wire

      # シグナルのハンドラは別のファイバで走る。主ループはこの印を見て動く。
      @stop_requested = false
      @reload_requested = false
      # 27062 の疎通を確かめた接続の番号。つながるたびに 1 回だけ確かめる（仕様書 4.2 節）。
      @probed_generation = nil.as(Int32?)
      # 言語を決め直した接続の番号。Steam の表示言語は SteamVR を起動し直さないと変わらないため、つながるたびに見る。
      @locale_generation = nil.as(Int32?)
    end

    def run : Int32
      Log.info { "KxFrameControllerManager #{VERSION} を起動する: #{Runtime::Paths.executable_path}" }

      load_config
      trap_signals
      mark_running
      check_update

      until @stop_requested
        reload_config if @reload_requested
        # ボタンの割り当ての反映は、設定画面のタブが見えていない間に行う。
        # つなぎ直すとタブが一度消えるため、操作している最中には行わない。
        rebind if !@dashboard.visible? && @parts.take_rebind
        @scheduler.step
        sleep @scheduler.poll_interval
      end

      @errors.guard("error.dashboard") { @dashboard.close }
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
        refresh_locale
        probe_link
        @errors.guard("error.power_off") { parts.power_off.tick(now) }
        @errors.guard("error.power_save") { parts.power_save.tick(parts.any_controller_connected?, now) }
        @errors.guard("error.dashboard") { @dashboard.tick(now) }
      end
      parts.steamvr.before_close = -> do
        @errors.guard("error.dashboard") { @dashboard.close }
        parts.power_off.reset
        @errors.guard("error.power_save") { parts.power_save.shutdown }
      end
    end

    # 既定バインドを書き換えたあと、SteamVR へつなぎ直して読ませる。
    #
    # つなぎ直すのは本ツールの OpenVR の接続だけで、SteamVR そのものは再起動しない（仕様書 2 章）。
    # 閉じる前の後始末は SteamVR の終了を受けたときと同じにする。次の拍で Scheduler がつなぎ直し、
    # そのときに新しい既定バインドを書き出してアクションを読ませ直す。
    private def rebind : Nil
      return unless @parts.steamvr.connected?
      Log.info { "既定バインドを書き換えたため、SteamVR へつなぎ直す" }
      @errors.guard("error.dashboard") { @dashboard.close }
      @parts.power_off.reset
      @errors.guard("error.power_save") { @parts.power_save.shutdown }
      @parts.steamvr.disconnect
      @dashboard.rebound
    end

    # 設定画面（ダッシュボードのタブ）を組み立てる。
    private def build_dashboard : Dashboard::Usecase
      parts = @parts
      translate = ->(key : String, vars : Hash(String, String)) { Runtime::I18n.t(key, vars) }
      names = Runtime::I18n::CODES.to_h { |code| {code, Runtime::I18n.native_name(code)} }
      dashboard = Dashboard::Usecase.new(parts.openvr, @config, Dashboard::View.new(translate, VERSION, names))
      dashboard.languages = Runtime::I18n.settings
      dashboard.buttons = PowerOff::Hand.values.to_h { |hand| {hand, SteamVR::Bindings.buttons(hand)} }
      dashboard.status = -> { snapshot }
      dashboard.disconnect = ->(hands : Array(PowerOff::Hand)) { parts.power_off.manual(hands) }
      dashboard.check_update = -> do
        usecase = Update::Usecase.new(Update::GitHubRepository.new("KxFrameControllerManager/#{VERSION}"))
        result = usecase.check(VERSION, @config.current.update.channel)
        {result.outcome.to_s.underscore, result.release.try(&.tag)}
      end
      dashboard.start_update = -> { Runtime::Systemd.start_manual_update(Runtime::Paths.executable_path) }
      dashboard.canvas_factory = ->(width : Int32, height : Int32) { Dashboard::CairoCanvas.create(width, height).as(Dashboard::Canvas?) }
      dashboard
    end

    private def snapshot : Dashboard::Snapshot
      parts = @parts
      connected = parts.steamvr.connected?
      hands = PowerOff::Hand.values.map do |hand|
        Dashboard::HandStatus.new(
          connected && parts.devices.connected?(hand),
          connected ? parts.devices.serial(hand) : nil,
          SteamVR::Bindings.button(@config.current.input, hand),
        )
      end
      Dashboard::Snapshot.new(
        steamvr_connected: connected,
        left: hands[0],
        right: hands[1],
        link_reachable: @link_reachable,
        power_save_state: parts.power_save.state.to_s.underscore,
        power_save_pending: File.exists?(Runtime::Paths.power_save_state_path),
        gain_range: connected ? parts.settings.gain_range : nil,
        config_errors: @config_errors.map { |error| KxFrameControllerManager.describe(error) },
        update: update_status,
      )
    end

    # 自動更新が残した状態を、設定画面へ見せる形にする。
    private def update_status : Dashboard::UpdateStatus
      state = Update::FileStateStore.new(Runtime::Paths.update_state_path, Runtime::Paths.running_marker_path, Runtime::Paths.update_lock_path).load
      # 途中で落ちた更新の段階は残ったままになる。走らせたプロセスがもう更新をしていなければ捨てる。
      phase = state.progress.try do |progress|
        cmdline = File.read("/proc/#{progress.pid}/cmdline") rescue nil
        progress.current?(Time.utc, cmdline) ? progress.phase.to_s.underscore : nil
      end
      last = state.last_run
      Dashboard::UpdateStatus.new(
        version: VERSION,
        last_checked_at: state.last_checked_at,
        last_outcome: last.try(&.outcome),
        last_tag: last.try(&.tag),
        last_finished_at: last.try(&.finished_at),
        phase: phase,
        service_installed: File.exists?(Runtime::Paths.systemd_unit_path),
        executable: Runtime::Paths.executable_path,
      )
    end

    # つながるたびに、設定が auto なら言語を決め直す。
    # Steam の表示言語を変えると Steam ごと SteamVR が起動し直すため、つなぎ直した時点で読めば追いつく。
    private def refresh_locale : Nil
      generation = @parts.openvr.generation
      return if @locale_generation == generation
      @locale_generation = generation
      apply_locale(@config.current.language)
    end

    private def apply_locale(setting : String) : Nil
      locale = KxFrameControllerManager.resolve_locale(setting)
      return if locale == Runtime::I18n.locale
      Runtime::I18n.locale = locale
      Log.info { "表示言語を #{locale} にする" }
      @dashboard.invalidate
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
        list = link.list
        @link_reachable = !list.nil?
        if list
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
      @config_errors = errors
      STDERR.puts Runtime::I18n.t("cli.config_invalid")
      errors.each { |error| STDERR.puts "  #{KxFrameControllerManager.describe(error)}" }
    end

    private def reload_config : Nil
      @reload_requested = false
      @errors.guard("error.config_reload") { @config_errors = @config.reload }
    end

    # 検証を通った設定を反映する。反映できた時点で、設定ファイルの誤りは解消している。
    private def apply(root : Config::Root) : Nil
      @config_errors = [] of Config::ValidationError
      Runtime::Logging.setup(@backends, root.log_level)
      apply_locale(root.language)
      @parts.apply(root)
      @scheduler.retry_interval = root.steamvr.retry_interval_s.seconds
      @scheduler.poll_interval = root.input.poll_interval_ms.milliseconds
      @dashboard.apply(root.dashboard.enabled)
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
    # 設定ファイルを読めて検証も通ったか。読めずに既定値へ倒したときは偽になる。
    # 設定ファイルが無いときは真とする。無いなら既定値が利用者の設定である。
    @config_loaded = true

    def initialize
      @root = read_config
      level = %w[trace debug].includes?(@root.log_level) ? @root.log_level : "warn"
      Runtime::Logging.setup([Runtime::StderrBackend.new] of ::Log::Backend, level)
      Runtime::I18n.locale = KxFrameControllerManager.resolve_locale(@root.language)
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
            puts t("status.hand", {"hand" => hand_name(hand), "serial" => serial || "-", "state" => state})
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
              puts t(matched ? "status.match_ok" : "status.match_ng", {"hand" => hand_name(hand)})
            end
          end
        else
          puts t("status.link_ng")
        end

        puts t("status.power_save_pending") if File.exists?(Runtime::Paths.power_save_state_path)
        puts t("status.dashboard") if @root.dashboard.enabled
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
          puts t("disconnect.#{result.outcome.to_s.underscore}", {"target" => result.target.hand.try { |hand| hand_name(hand) } || result.target.serial, "serial" => result.target.serial})
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
        # 読めなかった設定の代わりの既定値では auto_update が真になる。
        # 利用者が切っていても置き換えてしまうため、設定を読めないうちは自動では何もしない。
        unless @config_loaded
          STDERR.puts t("update.config_unreadable")
          return 1
        end
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

    # 更新で追うチャンネル（設定 update.channel）を見せる。target を渡せばそのチャンネルへ切り替える。
    #
    # test はプレリリースも取る開発者向けのチャンネルであり、設定画面には切り替えを置いていない。
    # 切り替えはこのコマンドか、設定ファイルを手で書き換えて行う。
    def channel(target : String?) : Int32
      current = @root.update.channel
      unless target
        puts t("channel.current.#{current}")
        return 0
      end

      if target == current
        puts t("channel.unchanged.#{current}")
        return 0
      end

      # 読めなかった設定の代わりの既定値を書き戻すと、利用者の他の設定が消える。
      unless @config_loaded
        STDERR.puts t("channel.config_unreadable")
        return 1
      end

      root = @root.dup_snapshot
      root.update.channel = target
      repository = Config::FileRepository.new(Runtime::Paths.config_path)
      errors = KxFrameControllerManager.config_usecase(repository).save(root)
      unless errors.empty?
        STDERR.puts t("cli.config_invalid")
        errors.each { |error| STDERR.puts "  #{KxFrameControllerManager.describe(error)}" }
        return 1
      end

      forget_last_check
      # 常駐は設定画面の「更新を確認」で今のチャンネルを使う。読み直させないと前のチャンネルで確かめ続ける。
      systemctl = Runtime::Systemd::Systemctl.new
      systemctl.run(["reload", Runtime::Systemd::UNIT_NAME]) if systemctl.active?

      puts t("channel.changed.#{target}")
      # stable へ戻しても、入っているプレリリースは古い安定版へは戻さない。同じ版の正式リリースを待つ。
      running = Update::Version.parse?(VERSION)
      puts t("channel.waits_for_stable", {"version" => VERSION}) if target == "stable" && running && !running.stable?
      0
    rescue exception : File::Error
      STDERR.puts exception.message
      1
    end

    # 自動更新の前回の確認時刻を消し、次のタイマー（30 分以内）で新しいチャンネルを確かめさせる。
    # 消さないと、切り替えても update.check_interval_h が経つまで何も起きない。
    # 更新が走っている最中なら触らない。その更新が時刻を書き戻すためである。
    private def forget_last_check : Nil
      state = Update::FileStateStore.new(Runtime::Paths.update_state_path, Runtime::Paths.running_marker_path, Runtime::Paths.update_lock_path)
      return unless state.try_lock
      begin
        record = state.load
        record.last_checked_at = nil
        state.save(record)
      ensure
        state.unlock
      end
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

    # 手の名前。引数の綴り（left、right）ではなく、今の言語の名前で出す。
    private def hand_name(hand : PowerOff::Hand) : String
      t("dashboard.hand.#{hand.label}")
    end

    private def print_list(list : PowerOff::ControllerList) : Nil
      if list.connected.empty?
        puts t("list.no_connected")
      else
        list.connected.each do |controller|
          puts t("list.connected", {"serial" => controller.serial, "hand" => controller.hand.try { |hand| hand_name(hand) } || "?"})
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
      # この時点の言語は環境変数から決めたものである。設定の language は誤りを含むかもしれず、まだ使わない。
      STDERR.puts Runtime::I18n.t("cli.config_invalid")
      errors.each { |error| STDERR.puts "  #{KxFrameControllerManager.describe(error)}" }
      @config_loaded = false
      Config::Root.default
    rescue exception : JSON::Error | File::Error
      STDERR.puts Runtime::I18n.t("cli.config_invalid")
      STDERR.puts "  #{exception.message}"
      @config_loaded = false
      Config::Root.default
    end
  end

  # 設定の usecase に、各コンテキストの検証を登録して返す。
  # 常駐と CLI で同じ検証を通すため、組み立てはここだけで行う。
  def self.config_usecase(repository : Config::Repository) : Config::Usecase
    usecase = Config::Usecase.new(repository)
    usecase.log_translate = ->(key : String, vars : Hash(String, String)) { Runtime::I18n.log_text(key, vars) }
    usecase.register_validator(Config::ValidationError::GENERAL) { |root| Runtime::I18n.validate(root.language) }
    usecase.register_validator("input") { |root| SteamVR::Bindings.validate(root.input) }
    usecase.register_validator("update") { |root| Update.validate(root.update) }
    usecase
  end

  # コマンドを解釈して実行し、終了コードを返す（仕様書 3.7 節）。
  def self.main(args : Array(String)) : Int32
    Runtime::I18n.locale = resolve_locale(Runtime::I18n::AUTO)

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
    in .channel?    then Tool.new.channel(parsed.argument)
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

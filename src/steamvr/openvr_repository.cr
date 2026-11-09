require "json"
require "log"
require "./ffi"
require "./repository"

module SteamVR
  # libopenvr_api.so を実行時に解決して呼ぶ Repository 実装（仕様書 5.2 節）。
  #
  # インターフェースバージョンは openvr_capi.h の記述に合わせて固定する。
  # libopenvr_api.so は後方互換に保たれているため、本ツールが要求する版が古い分には問題にならないが、
  # 逆に SteamVR 側が古くて要求する版を持たない場合は FnTable の並びが合わない。
  # そのため初期化のたびに VR_IsInterfaceVersionValid で検証し、通らなければ SteamVR 連携を無効にする。
  class OpenVRRepository < Repository
    Log = ::Log.for("steamvr")

    IVRSYSTEM_VERSION       = "IVRSystem_026"
    IVRAPPLICATIONS_VERSION = "IVRApplications_008"

    LIBRARY_NAME = "libopenvr_api.so"

    # SteamVR の bin の下で、この実行ファイルの CPU に合うライブラリが置かれるディレクトリ。
    {% if flag?(:aarch64) %}
      PLATFORM_DIRECTORY = "linuxarm64"
    {% else %}
      PLATFORM_DIRECTORY = "linux64"
    {% end %}

    # Steam Frame の SteamOS で SteamVR が置かれている場所（仕様書 2 章、2026-11-09 に実機で確認）。
    DEFAULT_RUNTIME_DIRECTORY = "/opt/steamvr"

    # 設定 steamvr.openvr_library_path。空なら既定の場所を探す。
    property library_path : String = ""

    def initialize(@env : Hash(String, String) | ENV.class = ENV)
      @library = Pointer(Void).null
      @shutdown_internal = nil.as(Proc(Nil)?)
      @system = Pointer(LibOpenVR::IVRSystemFnTable).null
      @applications = Pointer(LibOpenVR::IVRApplicationsFnTable).null
      @opened = false
      @reported_init_error = nil.as(Int32?)
      @logged_library_path = nil.as(String?)
    end

    def opened? : Bool
      @opened
    end

    # libopenvr_api.so の解決、OpenVR の初期化、FnTable の取得までを行う。
    # どこで失敗しても SteamVR 連携を無効にするだけで、本体の常駐は続けられる。
    #
    # 初期化には Background を渡す。
    # SteamVR が動いていなければ、この種別だけが SteamVR を起こさずに失敗する。
    # 呼び出し側はこの失敗を異常として扱わず、steamvr.retry_interval_s ごとに開き直す。
    def open : Bool
      return true if @opened

      unless load_library
        Log.debug { "#{LIBRARY_NAME} を解決できなかった" }
        return false
      end

      init = resolve("VR_InitInternal2").try do |pointer|
        Proc(Int32*, Int32, UInt8*, UInt64).new(pointer, Pointer(Void).null)
      end
      shutdown = resolve("VR_ShutdownInternal").try do |pointer|
        Proc(Nil).new(pointer, Pointer(Void).null)
      end
      get_generic = resolve("VR_GetGenericInterface").try do |pointer|
        Proc(UInt8*, Int32*, Void*).new(pointer, Pointer(Void).null)
      end
      version_valid = resolve("VR_IsInterfaceVersionValid").try do |pointer|
        Proc(UInt8*, Bool).new(pointer, Pointer(Void).null)
      end

      unless init && shutdown && get_generic && version_valid
        Log.error { "#{LIBRARY_NAME} から必要な関数を解決できなかった" }
        return unload
      end

      error = 0
      init.call(pointerof(error), LibOpenVR::APPLICATION_TYPE_BACKGROUND, Pointer(UInt8).null)
      unless error == LibOpenVR::ERROR_NONE
        report_init_failure(error)
        return unload
      end
      @reported_init_error = nil
      @shutdown_internal = shutdown

      unless version_valid.call(IVRSYSTEM_VERSION.to_unsafe) &&
             version_valid.call(IVRAPPLICATIONS_VERSION.to_unsafe)
        Log.error do
          "SteamVR が #{IVRSYSTEM_VERSION} と #{IVRAPPLICATIONS_VERSION} に対応していないため " \
          "SteamVR 連携を無効にする"
        end
        return close_and_unload
      end

      @system = get_generic
        .call("FnTable:#{IVRSYSTEM_VERSION}".to_unsafe, pointerof(error))
        .as(LibOpenVR::IVRSystemFnTable*)
      @applications = get_generic
        .call("FnTable:#{IVRAPPLICATIONS_VERSION}".to_unsafe, pointerof(error))
        .as(LibOpenVR::IVRApplicationsFnTable*)

      if @system.null? || @applications.null?
        Log.error { "OpenVR の FnTable を取得できなかった" }
        return close_and_unload
      end

      @opened = true
      Log.info { "OpenVR を初期化した" }
      true
    end

    def close : Nil
      return unless @opened
      close_and_unload
    end

    def add_application_manifest(manifest_path : String) : Bool
      return false unless @opened
      call = Proc(UInt8*, Bool, Int32).new(@applications.value.add_application_manifest, Pointer(Void).null)
      check("AddApplicationManifest", call.call(manifest_path.to_unsafe, false))
    end

    def remove_application_manifest(manifest_path : String) : Bool
      return false unless @opened
      call = Proc(UInt8*, Int32).new(@applications.value.remove_application_manifest, Pointer(Void).null)
      check("RemoveApplicationManifest", call.call(manifest_path.to_unsafe))
    end

    def poll_events : Array(Event)
      events = [] of Event
      return events unless @opened

      call = Proc(LibOpenVR::PVREvent, UInt32, Bool).new(@system.value.poll_next_event, Pointer(Void).null)
      event = uninitialized LibOpenVR::VREvent
      while call.call(pointerof(event), sizeof(LibOpenVR::VREvent).to_u32)
        events << Event.new(OpenVRRepository.kind_of(event.event_type), event.event_type, event.tracked_device_index)
      end
      events
    end

    def acknowledge_quit : Nil
      return unless @opened
      Proc(Nil).new(@system.value.acknowledge_quit_exiting, Pointer(Void).null).call
    end

    # イベントの番号を読み分ける。spec から確かめられるよう、クラスに公開しておく。
    def self.kind_of(type : UInt32) : EventKind
      case type
      when LibOpenVR::EVENT_TRACKED_DEVICE_ACTIVATED   then EventKind::TrackedDeviceActivated
      when LibOpenVR::EVENT_TRACKED_DEVICE_DEACTIVATED then EventKind::TrackedDeviceDeactivated
      when LibOpenVR::EVENT_QUIT                       then EventKind::Quit
      else                                                  EventKind::Other
      end
    end

    # libopenvr_api.so を探す順に並べる。
    #
    # 設定で場所を指定したら、そこだけを見る。
    # 指定したのに見つからないとき、黙って別の場所のものを使うと、何を読んだのかが分からなくなる。
    #
    # 指定が無ければ、Steam Frame の既定の場所を先に見て、
    # 次に OpenVR 標準のパス設定ファイル（openvrpaths.vrpath）の runtime 配列を見る。
    # 後者は PC の Linux で SteamVR を動かす場合の置き場所であり、手元での確認に使う。
    def self.library_candidates(configured : String, env = ENV) : Array(String)
      return [configured] unless configured.empty?

      runtimes = [DEFAULT_RUNTIME_DIRECTORY]
      runtimes.concat(runtime_directories(env))
      runtimes.uniq.map { |directory| File.join(directory, "bin", PLATFORM_DIRECTORY, LIBRARY_NAME) }
    end

    # openvrpaths.vrpath の runtime 配列。読めなければ空を返す。
    def self.runtime_directories(env = ENV) : Array(String)
      config_home = env["XDG_CONFIG_HOME"]?.presence || File.join(env["HOME"]?.presence || Path.home.to_s, ".config")
      vrpath = File.join(config_home, "openvr", "openvrpaths.vrpath")
      return [] of String unless File.exists?(vrpath)

      JSON.parse(File.read(vrpath))["runtime"].as_a.compact_map(&.as_s?)
    rescue ex
      Log.warn(exception: ex) { "openvrpaths.vrpath を読めなかった: #{vrpath}" }
      [] of String
    end

    private def load_library : Bool
      return true unless @library.null?

      OpenVRRepository.library_candidates(@library_path, @env).each do |path|
        next unless File.exists?(path)

        handle = LibC.dlopen(path, LibC::RTLD_NOW | LibC::RTLD_LOCAL)
        if handle.null?
          Log.warn { "#{path} を開けなかった: #{dl_error}" }
          next
        end

        @library = handle
        report_library_loaded(path)
        return true
      end
      false
    end

    private def dl_error : String
      message = LibC.dlerror
      message.null? ? "(理由不明)" : String.new(message)
    end

    private def resolve(name : String) : Void*?
      pointer = LibC.dlsym(@library, name)
      pointer.null? ? nil : pointer
    end

    # 解決できた場所を出す。ただし場所が変わったときだけ書く。
    #
    # SteamVR を起動していない間、open は毎回失敗し、その後始末でライブラリを手放す。
    # 次の再試行は読み込むところからやり直すため、そのたびに書くと
    # VR を使わない間のログがこの 1 行だけで埋まる。
    #
    # 手放すのをやめて読み込んだままにする手は採らない。
    # SteamVR の更新でライブラリが置き換わっても、古いものを掴んだままになる。
    private def report_library_loaded(path : String) : Nil
      if @logged_library_path == path
        Log.debug { "#{LIBRARY_NAME} をロードした: #{path}" }
        return
      end

      @logged_library_path = path
      Log.info { "#{LIBRARY_NAME} をロードした: #{path}" }
    end

    # 初期化の失敗を、SteamVR が動いていないだけの場合と切り分けて出す。
    #
    # Background で初期化するため、SteamVR を起動していない間はここを必ず通る。
    # 既定のログレベルは info であり、そちらへ上げると VR を使わない間のログが
    # 再試行ごとの同じ 1 行で埋まる。異常ではないので debug に留める。
    #
    # それ以外の失敗は目に触れる必要がある。
    # ただし再試行のたびに繰り返されるため、番号が変わったときだけ書く。
    private def report_init_failure(error : Int32) : Nil
      if error == LibOpenVR::ERROR_NO_SERVER_FOR_BACKGROUND_APP
        Log.debug { "SteamVR が動いていないため OpenVR を初期化しなかった" }
        @reported_init_error = nil
        return
      end

      if @reported_init_error == error
        Log.debug { "OpenVR の初期化に失敗した (#{error})" }
        return
      end

      @reported_init_error = error
      Log.warn { "OpenVR の初期化に失敗した (#{error})" }
    end

    private def check(operation : String, error : Int32) : Bool
      return true if error == LibOpenVR::ERROR_NONE
      Log.error { "#{operation} が失敗した (#{error})" }
      false
    end

    private def close_and_unload : Bool
      @shutdown_internal.try(&.call)
      @shutdown_internal = nil
      @system = Pointer(LibOpenVR::IVRSystemFnTable).null
      @applications = Pointer(LibOpenVR::IVRApplicationsFnTable).null
      @opened = false
      unload
    end

    private def unload : Bool
      LibC.dlclose(@library) unless @library.null?
      @library = Pointer(Void).null
      false
    end
  end
end

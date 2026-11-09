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
    # IVRInput と IVRSettings は、使えなくても接続は保つ。
    # 版が合わなければその機能だけを止め、イベントの受け取りと vrmanifest の登録は続ける。
    IVRINPUT_VERSION    = "IVRInput_011"
    IVRSETTINGS_VERSION = "IVRSettings_003"
    # 設定画面（ダッシュボードのタブ）。使えなければ設定画面だけを出さない。
    IVROVERLAY_VERSION = "IVROverlay_028"

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
      @input = Pointer(LibOpenVR::IVRInputFnTable).null
      @settings = Pointer(LibOpenVR::IVRSettingsFnTable).null
      @overlay = Pointer(LibOpenVR::IVROverlayFnTable).null
      @opened = false
      @generation = 0
      @reported_init_error = nil.as(Int32?)
      @logged_library_path = nil.as(String?)
      @repeated_errors = {} of String => Int32
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

      @input = optional_table(get_generic, version_valid, IVRINPUT_VERSION, "長押しの検出").as(LibOpenVR::IVRInputFnTable*)
      @settings = optional_table(get_generic, version_valid, IVRSETTINGS_VERSION, "省電力").as(LibOpenVR::IVRSettingsFnTable*)
      @overlay = optional_table(get_generic, version_valid, IVROVERLAY_VERSION, "設定画面").as(LibOpenVR::IVROverlayFnTable*)

      @generation += 1
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

    def generation : Int32
      @generation
    end

    def input_available? : Bool
      @opened && !@input.null?
    end

    def settings_available? : Bool
      @opened && !@settings.null?
    end

    def set_action_manifest_path(path : String) : Bool
      return false unless input_available?
      call = Proc(UInt8*, Int32).new(@input.value.set_action_manifest_path, Pointer(Void).null)
      check("SetActionManifestPath", call.call(path.to_unsafe))
    end

    def action_set_handle(name : String) : UInt64?
      handle_of("GetActionSetHandle", name) { @input.value.get_action_set_handle }
    end

    def action_handle(name : String) : UInt64?
      handle_of("GetActionHandle", name) { @input.value.get_action_handle }
    end

    def input_source_handle(path : String) : UInt64?
      handle_of("GetInputSourceHandle", path) { @input.value.get_input_source_handle }
    end

    def update_action_state(action_set : UInt64, priority : Int32) : Bool
      return false unless input_available?
      set = LibOpenVR::VRActiveActionSet.new
      set.action_set = action_set
      set.priority = priority
      call = Proc(LibOpenVR::VRActiveActionSet*, UInt32, UInt32, Int32).new(@input.value.update_action_state, Pointer(Void).null)
      error = call.call(pointerof(set), sizeof(LibOpenVR::VRActiveActionSet).to_u32, 1_u32)
      # 20 ミリ秒ごとに呼ぶため、失敗を毎回書くとログが埋まる。番号が変わったときだけ書く。
      report_repeated("UpdateActionState", error)
      error == LibOpenVR::INPUT_ERROR_NONE
    end

    def digital_action_state(action : UInt64, restrict_to : UInt64) : Bool?
      return nil unless input_available?
      data = LibOpenVR::InputDigitalActionData.new
      call = Proc(UInt64, LibOpenVR::InputDigitalActionData*, UInt32, UInt64, Int32).new(@input.value.get_digital_action_data, Pointer(Void).null)
      error = call.call(action, pointerof(data), sizeof(LibOpenVR::InputDigitalActionData).to_u32, restrict_to)
      report_repeated("GetDigitalActionData", error)
      return nil unless error == LibOpenVR::INPUT_ERROR_NONE && data.active
      data.state
    end

    def trigger_haptic(action : UInt64, start_s : Float32, duration_s : Float32, frequency : Float32, amplitude : Float32, restrict_to : UInt64) : Bool
      return false unless input_available?
      call = Proc(UInt64, Float32, Float32, Float32, Float32, UInt64, Int32).new(@input.value.trigger_haptic_vibration_action, Pointer(Void).null)
      check("TriggerHapticVibrationAction", call.call(action, start_s, duration_s, frequency, amplitude, restrict_to))
    end

    def controller_index(role : Int32) : UInt32?
      return nil unless @opened
      call = Proc(Int32, UInt32).new(@system.value.get_tracked_device_index_for_controller_role, Pointer(Void).null)
      index = call.call(role)
      index == LibOpenVR::TRACKED_DEVICE_INDEX_INVALID ? nil : index
    end

    def device_connected?(index : UInt32) : Bool
      return false unless @opened
      Proc(UInt32, Bool).new(@system.value.is_tracked_device_connected, Pointer(Void).null).call(index)
    end

    def string_property(index : UInt32, property : Int32) : String?
      return nil unless @opened
      call = Proc(UInt32, Int32, UInt8*, UInt32, Int32*, UInt32).new(@system.value.get_string_tracked_device_property, Pointer(Void).null)
      buffer = Bytes.new(LibOpenVR::MAX_PROPERTY_STRING_SIZE)
      error = 0
      size = call.call(index, property, buffer.to_unsafe, buffer.size.to_u32, pointerof(error))
      return nil unless error == LibOpenVR::PROPERTY_SUCCESS && size > 0
      String.new(buffer.to_unsafe)
    end

    def float_property(index : UInt32, property : Int32) : Float32?
      return nil unless @opened
      call = Proc(UInt32, Int32, Int32*, Float32).new(@system.value.get_float_tracked_device_property, Pointer(Void).null)
      error = 0
      value = call.call(index, property, pointerof(error))
      error == LibOpenVR::PROPERTY_SUCCESS ? value : nil
    end

    def bool_property(index : UInt32, property : Int32) : Bool?
      return nil unless @opened
      call = Proc(UInt32, Int32, Int32*, Bool).new(@system.value.get_bool_tracked_device_property, Pointer(Void).null)
      error = 0
      value = call.call(index, property, pointerof(error))
      error == LibOpenVR::PROPERTY_SUCCESS ? value : nil
    end

    def get_float_setting(section : String, key : String) : {Float32, Int32}
      return {0.0_f32, -1} unless settings_available?
      call = Proc(UInt8*, UInt8*, Int32*, Float32).new(@settings.value.get_float, Pointer(Void).null)
      error = 0
      value = call.call(section.to_unsafe, key.to_unsafe, pointerof(error))
      {value, error}
    end

    def get_string_setting(section : String, key : String) : {String, Int32}
      return {"", -1} unless settings_available?
      call = Proc(UInt8*, UInt8*, UInt8*, UInt32, Int32*, Nil).new(@settings.value.get_string, Pointer(Void).null)
      buffer = Bytes.new(LibOpenVR::MAX_PROPERTY_STRING_SIZE)
      error = 0
      call.call(section.to_unsafe, key.to_unsafe, buffer.to_unsafe, buffer.size.to_u32, pointerof(error))
      {String.new(buffer.to_unsafe), error}
    end

    def set_float_setting(section : String, key : String, value : Float32) : Int32
      return -1 unless settings_available?
      call = Proc(UInt8*, UInt8*, Float32, Int32*, Nil).new(@settings.value.set_float, Pointer(Void).null)
      error = 0
      call.call(section.to_unsafe, key.to_unsafe, value, pointerof(error))
      error
    end

    def set_string_setting(section : String, key : String, value : String) : Int32
      return -1 unless settings_available?
      call = Proc(UInt8*, UInt8*, UInt8*, Int32*, Nil).new(@settings.value.set_string, Pointer(Void).null)
      error = 0
      call.call(section.to_unsafe, key.to_unsafe, value.to_unsafe, pointerof(error))
      error
    end

    def remove_setting(section : String, key : String) : Int32
      return -1 unless settings_available?
      call = Proc(UInt8*, UInt8*, Int32*, Nil).new(@settings.value.remove_key_in_section, Pointer(Void).null)
      error = 0
      call.call(section.to_unsafe, key.to_unsafe, pointerof(error))
      error
    end

    def overlay_available? : Bool
      @opened && !@overlay.null?
    end

    # ダッシュボードのタブを作る。
    #
    # 前の接続で作ったものが SteamVR に残っていると、同じキーでは作れない（KeyInUse）。
    # そのときは残っているものを消して 1 回だけ作り直す。Babble-Frame-Runtime と同じ扱いである。
    def create_dashboard_overlay(key : String, name : String) : {UInt64, UInt64}?
      return nil unless overlay_available?
      create = Proc(UInt8*, UInt8*, UInt64*, UInt64*, Int32).new(@overlay.value.create_dashboard_overlay, Pointer(Void).null)
      main = LibOpenVR::OVERLAY_HANDLE_INVALID
      thumbnail = LibOpenVR::OVERLAY_HANDLE_INVALID
      error = create.call(key.to_unsafe, name.to_unsafe, pointerof(main), pointerof(thumbnail))
      if error == LibOpenVR::OVERLAY_ERROR_KEY_IN_USE
        find = Proc(UInt8*, UInt64*, Int32).new(@overlay.value.find_overlay, Pointer(Void).null)
        stale = LibOpenVR::OVERLAY_HANDLE_INVALID
        destroy_overlay(stale) if find.call(key.to_unsafe, pointerof(stale)) == LibOpenVR::ERROR_NONE
        error = create.call(key.to_unsafe, name.to_unsafe, pointerof(main), pointerof(thumbnail))
      end
      return {main, thumbnail} if check("CreateDashboardOverlay", error)
      nil
    end

    def destroy_overlay(handle : UInt64) : Nil
      return unless overlay_available?
      hide = Proc(UInt64, Int32).new(@overlay.value.hide_overlay, Pointer(Void).null)
      destroy = Proc(UInt64, Int32).new(@overlay.value.destroy_overlay, Pointer(Void).null)
      hide.call(handle)
      destroy.call(handle)
    end

    def configure_overlay(handle : UInt64, width_m : Float32, mouse_width : Int32, mouse_height : Int32) : Bool
      return false unless overlay_available?
      width = Proc(UInt64, Float32, Int32).new(@overlay.value.set_overlay_width_in_meters, Pointer(Void).null)
      method = Proc(UInt64, Int32, Int32).new(@overlay.value.set_overlay_input_method, Pointer(Void).null)
      scale = Proc(UInt64, LibOpenVR::HmdVector2*, Int32).new(@overlay.value.set_overlay_mouse_scale, Pointer(Void).null)
      vector = LibOpenVR::HmdVector2.new(x: mouse_width.to_f32, y: mouse_height.to_f32)
      check("SetOverlayWidthInMeters", width.call(handle, width_m)) &&
        check("SetOverlayInputMethod", method.call(handle, LibOpenVR::OVERLAY_INPUT_METHOD_MOUSE)) &&
        check("SetOverlayMouseScale", scale.call(handle, pointerof(vector)))
    end

    def set_overlay_raw(handle : UInt64, pixels : Bytes, width : Int32, height : Int32) : Bool
      return false unless overlay_available?
      return false unless pixels.size == width * height * 4
      call = Proc(UInt64, Void*, UInt32, UInt32, UInt32, Int32).new(@overlay.value.set_overlay_raw, Pointer(Void).null)
      check("SetOverlayRaw", call.call(handle, pixels.to_unsafe.as(Void*), width.to_u32, height.to_u32, 4_u32))
    end

    def overlay_visible?(handle : UInt64) : Bool
      return false unless overlay_available?
      Proc(UInt64, Bool).new(@overlay.value.is_overlay_visible, Pointer(Void).null).call(handle)
    end

    # オーバーレイのイベントを読み切る。マウスのイベントでは data の先頭が VREvent_Mouse_t（x、y、button）である。
    def poll_overlay_events(handle : UInt64) : Array(OverlayEvent)
      events = [] of OverlayEvent
      return events unless overlay_available?

      call = Proc(UInt64, LibOpenVR::PVREvent, UInt32, Bool).new(@overlay.value.poll_next_overlay_event, Pointer(Void).null)
      event = uninitialized LibOpenVR::VREvent
      while call.call(handle, pointerof(event), sizeof(LibOpenVR::VREvent).to_u32)
        # data は event_type、tracked_device_index、event_age_seconds の 12 バイトの後ろにある。
        mouse = (pointerof(event).as(UInt8*) + 12).as(Float32*)
        kind = case event.event_type
               when LibOpenVR::EVENT_MOUSE_BUTTON_UP then OverlayEventKind::MouseButtonUp
               when LibOpenVR::EVENT_OVERLAY_SHOWN   then OverlayEventKind::Shown
               else                                       OverlayEventKind::Other
               end
        events << OverlayEvent.new(kind, mouse[0], mouse[1])
      end
      events
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

    # 無くても接続を保てるインターフェースを取る。版が合わなければ null を返し、その機能を止める。
    private def optional_table(get_generic, version_valid, version : String, feature : String) : Void*
      unless version_valid.call(version.to_unsafe)
        Log.error { "SteamVR が #{version} に対応していないため#{feature}を無効にする" }
        return Pointer(Void).null
      end
      error = 0
      table = get_generic.call("FnTable:#{version}".to_unsafe, pointerof(error))
      if table.null?
        Log.error { "#{version} の FnTable を取得できなかったため#{feature}を無効にする (#{error})" }
      end
      table
    end

    # 名前からハンドルを引く 3 つの関数（GetActionSetHandle など）は同じ形をしている。
    private def handle_of(operation : String, name : String, & : -> Void*) : UInt64?
      return nil unless input_available?
      call = Proc(UInt8*, UInt64*, Int32).new(yield, Pointer(Void).null)
      handle = 0_u64
      return nil unless check(operation, call.call(name.to_unsafe, pointerof(handle)))
      handle
    end

    # 繰り返し呼ぶ関数の失敗を、番号が変わったときだけ書く。
    private def report_repeated(operation : String, error : Int32) : Nil
      return if @repeated_errors[operation]? == error
      @repeated_errors[operation] = error
      return if error == LibOpenVR::INPUT_ERROR_NONE
      Log.warn { "#{operation} が失敗した (#{error})" }
    end

    private def close_and_unload : Bool
      @shutdown_internal.try(&.call)
      @shutdown_internal = nil
      @system = Pointer(LibOpenVR::IVRSystemFnTable).null
      @applications = Pointer(LibOpenVR::IVRApplicationsFnTable).null
      @input = Pointer(LibOpenVR::IVRInputFnTable).null
      @settings = Pointer(LibOpenVR::IVRSettingsFnTable).null
      @overlay = Pointer(LibOpenVR::IVROverlayFnTable).null
      @repeated_errors.clear
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

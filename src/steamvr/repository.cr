module SteamVR
  # OpenVR から受け取ったイベントのうち、本ツールが読み分けるもの。
  enum EventKind
    # コントローラーなどのデバイスがつながった。
    TrackedDeviceActivated
    # デバイスが切れた。切断の確認に使う（仕様書 3.4 節）。
    TrackedDeviceDeactivated
    # SteamVR が終了する。OpenVR を閉じて再試行へ戻る（仕様書 3.6 節）。
    Quit
    # 上のどれでもない。
    Other
  end

  # OpenVR のイベント 1 件。
  # 番号のままでは扱いにくいため、読み分けたものと元の番号を一緒に持つ。
  struct Event
    getter kind : EventKind
    getter type : UInt32
    getter device_index : UInt32

    def initialize(@kind : EventKind, @type : UInt32, @device_index : UInt32)
    end
  end

  # オーバーレイに届くイベントのうち、設定画面が読み分けるもの。
  enum OverlayEventKind
    # ポインタのボタンを離した。押したことはこれで判定する。
    MouseButtonUp
    # タブが見えるようになった。
    Shown
    Other
  end

  # オーバーレイに届いたイベント 1 件。
  # x と y はマウスの座標で、左下が原点である。マウス以外のイベントでは意味を持たない。
  record OverlayEvent, kind : OverlayEventKind, x : Float32, y : Float32

  # OpenVR 呼び出しの境界（仕様書 3.6 節、4.1 節）。
  # 実装は openvr_repository.cr が libopenvr_api.so の動的ロードで提供する。
  abstract class Repository
    # OpenVR を VRApplication_Background で初期化する。成功したら true を返す。
    #
    # SteamVR が動いていなければ失敗する。この種別を選んだのはそのためである。
    abstract def open : Bool

    abstract def close : Nil

    # 初期化に成功していて、以降の呼び出しが有効か。
    abstract def opened? : Bool

    abstract def add_application_manifest(manifest_path : String) : Bool
    abstract def remove_application_manifest(manifest_path : String) : Bool

    # 溜まっているイベントを読み切って返す。
    abstract def poll_events : Array(Event)

    # OpenVR を閉じる前に、SteamVR の終了要求へ応答する（AcknowledgeQuit_Exiting）。
    abstract def acknowledge_quit : Nil

    # 開き直すたびに 1 つ進む番号。
    # SteamVR を再起動するとアクションのハンドルが無効になるため、
    # 入力の側はこの番号が変わったのを見てハンドルを取り直す。
    abstract def generation : Int32

    # IVRInput（SteamVR Input）を使えるか。SteamVR が版に対応していなければ偽になる。
    abstract def input_available? : Bool

    # IVRSettings を使えるか。
    abstract def settings_available? : Bool

    # --- IVRInput（仕様書 3.1 節） ---

    abstract def set_action_manifest_path(path : String) : Bool
    abstract def action_set_handle(name : String) : UInt64?
    abstract def action_handle(name : String) : UInt64?
    abstract def input_source_handle(path : String) : UInt64?

    # アクションセット 1 つ分の状態を取り込む。
    abstract def update_action_state(action_set : UInt64, priority : Int32) : Bool

    # boolean のアクションが押されているか。restrict_to に手の入力ソースを渡すと片手ずつ読める。
    # アクションが有効でない（どのボタンにも割り当てられていない）ときと、読めなかったときは nil を返す。
    abstract def digital_action_state(action : UInt64, restrict_to : UInt64) : Bool?

    abstract def trigger_haptic(action : UInt64, start_s : Float32, duration_s : Float32, frequency : Float32, amplitude : Float32, restrict_to : UInt64) : Bool

    # --- IVRSystem のデバイス情報（仕様書 3.3 節） ---

    # 役割（左手、右手）に割り当たったデバイス番号。割り当てが無ければ nil。
    abstract def controller_index(role : Int32) : UInt32?
    abstract def device_connected?(index : UInt32) : Bool
    abstract def string_property(index : UInt32, property : Int32) : String?
    abstract def float_property(index : UInt32, property : Int32) : Float32?
    abstract def bool_property(index : UInt32, property : Int32) : Bool?

    # --- IVRSettings（仕様書 3.8 節） ---
    #
    # 読み出しは値とエラー番号の組を返す。未設定と読み出しの失敗を呼び出し側で読み分けるためである。

    abstract def get_float_setting(section : String, key : String) : {Float32, Int32}
    abstract def get_string_setting(section : String, key : String) : {String, Int32}
    abstract def set_float_setting(section : String, key : String, value : Float32) : Int32
    abstract def set_string_setting(section : String, key : String, value : String) : Int32
    abstract def remove_setting(section : String, key : String) : Int32

    # IVROverlay（設定画面）。
    #
    # 設定画面を持たない境界の実装（spec の偽物など）でも書かずに済むよう、使えないことを返す既定を置く。
    def overlay_available? : Bool
      false
    end

    # ダッシュボードのタブを作り、本体とサムネイルのハンドルを返す。
    def create_dashboard_overlay(key : String, name : String) : {UInt64, UInt64}?
      nil
    end

    def destroy_overlay(handle : UInt64) : Nil
    end

    # 幅（メートル）、マウスでの操作、マウスの座標の大きさをまとめて決める。
    def configure_overlay(handle : UInt64, width_m : Float32, mouse_width : Int32, mouse_height : Int32) : Bool
      false
    end

    # RGBA の画素をそのまま渡す。
    def set_overlay_raw(handle : UInt64, pixels : Bytes, width : Int32, height : Int32) : Bool
      false
    end

    def overlay_visible?(handle : UInt64) : Bool
      false
    end

    def poll_overlay_events(handle : UInt64) : Array(OverlayEvent)
      [] of OverlayEvent
    end
  end

  # vrmanifest ファイルの読み書きの境界。
  abstract class ManifestStore
    abstract def write(path : String, content : String) : Nil
    abstract def delete(path : String) : Nil
    abstract def exists?(path : String) : Bool
  end

  # 実ファイルに対する ManifestStore 実装。
  class FileManifestStore < ManifestStore
    def write(path : String, content : String) : Nil
      Dir.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def delete(path : String) : Nil
      File.delete?(path)
    end

    def exists?(path : String) : Bool
      File.exists?(path)
    end
  end
end

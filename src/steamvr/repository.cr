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

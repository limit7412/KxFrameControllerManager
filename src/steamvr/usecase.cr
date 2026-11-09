require "json"
require "log"
require "./repository"

# SteamVR 連携コンテキスト。
module SteamVR
  # OpenVR への接続、vrmanifest の登録、イベントの受け取りを担う（仕様書 3.6 節）。
  #
  # vrmanifest を登録する目的は、SteamVR のコントローラーバインド画面に本ツールを出すことである。
  # 自動起動には使わない。常駐の管理は systemd が持つ。
  class Usecase
    Log = ::Log.for("steamvr")

    APP_KEY  = "kairo.kxframecontrollermanager"
    APP_NAME = "KxFrameControllerManager"

    # SteamVR の終了を受けて OpenVR を閉じる直前に呼ぶ。
    # 省電力で変えた設定値を、閉じる前に戻すために使う（仕様書 3.8 節）。
    property before_close : Proc(Nil) = -> { }

    # アクションマニフェストと既定バインドの中身。キーは書き出す先の絶対パスである。
    # 実行ファイルへ埋め込んだものを、vrmanifest と一緒に接続のたびに書き出す。
    property action_files : Hash(String, String) = {} of String => String

    # バインド画面などに出す説明文。キーは SteamVR の言語の札（en_us、ja_jp など、小文字）である。
    # composition root が辞書から全言語ぶんを渡す。
    property descriptions : Hash(String, String) = DEFAULT_DESCRIPTIONS

    DEFAULT_DESCRIPTIONS = {
      "en_us" => "Turns off Steam Frame controllers with a long press.",
      "ja_jp" => "長押しで Steam Frame のコントローラーを切断します。",
    }

    def initialize(
      @repository : Repository,
      @store : ManifestStore,
      @manifest_path : String,
      @exe_path : String,
      @action_manifest_path : String? = nil,
    )
    end

    # vrmanifest の内容を組み立てる。
    # 配布物には含めず、起動時に解決した実行ファイルの絶対パスを埋めて書き出す。
    #
    # binary_path_linux は SteamVR がこのアプリをどの実行ファイルとして扱うかを示す。
    # SteamVR から起動させることはしないが、バインド画面がアプリを識別するのに要る。
    # action_manifest_path はアクションマニフェストを用意したときだけ書く。
    def self.build_manifest(exe_path : String, action_manifest_path : String? = nil,
                            descriptions : Hash(String, String) = DEFAULT_DESCRIPTIONS) : String
      JSON.build(indent: 2) do |json|
        json.object do
          json.field "source", "builtin"
          json.field "applications" do
            json.array do
              json.object do
                json.field "app_key", APP_KEY
                json.field "launch_type", "binary"
                json.field "binary_path_linux", exe_path
                json.field "action_manifest_path", action_manifest_path if action_manifest_path
                json.field "is_dashboard_overlay", true
                json.field "strings" do
                  json.object do
                    descriptions.each do |tag, description|
                      json.field tag do
                        json.object do
                          json.field "name", APP_NAME
                          json.field "description", description
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # OpenVR へ接続し、つながったら vrmanifest を登録する。つながったら true を返す。
    #
    # SteamVR が動いていないときは false を返すだけで、呼び出し側が後でやり直す。
    # 登録に失敗しても接続そのものは保つ。入力と切断の確認には登録が要らないためである。
    def connect : Bool
      return true if @repository.opened?
      return false unless @repository.open

      register
      true
    end

    def connected? : Bool
      @repository.opened?
    end

    # 接続を閉じる。SteamVR の終了を受けたときと、本体の終了時に呼ぶ。
    def disconnect : Nil
      @repository.close
    end

    # vrmanifest を書き出してから OpenVR へ登録する。
    #
    # 接続のたびに書き出し直す。SteamVR の再インストールで登録が消えていても、
    # 実行ファイルを移していても、次につながった時点で揃う。
    def register : Bool
      return false unless @repository.opened?

      @action_files.each { |path, content| @store.write(path, content) }
      @store.write(@manifest_path, self.class.build_manifest(@exe_path, @action_manifest_path, @descriptions))
      unless @repository.add_application_manifest(@manifest_path)
        Log.error { "vrmanifest の登録に失敗した: #{@manifest_path}" }
        return false
      end
      Log.info { "vrmanifest を登録した: #{@manifest_path}" }
      true
    end

    # 登録を外し、生成した vrmanifest も消す。
    #
    # ファイルを消せなくても、SteamVR 側の解除は終わっている。
    # その場合は解除できたことを返し、ファイルの件はログに残すだけにする。
    def unregister : Bool
      return false unless @repository.opened?

      unless @repository.remove_application_manifest(@manifest_path)
        Log.error { "vrmanifest の登録解除に失敗した: #{@manifest_path}" }
        return false
      end

      begin
        @store.delete(@manifest_path)
      rescue exception
        Log.warn(exception: exception) { "vrmanifest を消せなかった: #{@manifest_path}" }
      end

      Log.info { "vrmanifest の登録を外した" }
      true
    end

    # 溜まっているイベントを読み切って返す。
    #
    # SteamVR の終了要求が含まれていれば、応答してから OpenVR を閉じる。
    # KxNotifyUtils と違い、ここでプロセスは終わらない。
    # 呼び出し側は connected? が偽になったのを見て、再試行へ戻る。
    def poll : Array(Event)
      return [] of Event unless @repository.opened?

      events = @repository.poll_events
      if events.any?(&.kind.quit?)
        begin
          @before_close.call
        rescue exception
          Log.error(exception: exception) { "OpenVR を閉じる前の処理に失敗した" }
        end
        @repository.acknowledge_quit
        @repository.close
        Log.info { "SteamVR の終了を検知したため OpenVR を閉じた" }
      end
      events
    end

    def exe_path : String
      @exe_path
    end

    def manifest_path : String
      @manifest_path
    end
  end
end

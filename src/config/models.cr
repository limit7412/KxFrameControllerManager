require "json"

# 設定コンテキスト。
# 設定スキーマ（仕様書 6.1 節）の定義を担う。
#
# どのセクションも全項目に既定値を持ち、設定ファイルに書かれていない項目はその既定値になる。
# 範囲の検証は usecase 側にあり、ここは形と既定値だけを決める。
module Config
  # 切断の対象（仕様書 3.3 節）。
  enum PowerOffTarget
    # 押した側だけを切る。
    Pressed
    # 左右の両方を切る。
    Both
  end

  # SteamVR Input のアクションセットの優先度（仕様書 3.1 節）。
  enum InputPriority
    # 既定の優先度。
    Normal
    # k_nActionSetOverlayGlobalPriorityMin を使う。
    # 他アプリがフォーカス中でも読めるが、そのボタンはゲーム側で効かなくなる。
    OverlayGlobal
  end

  # power_off セクション。長押しの判定と切断の確認に使う時間を持つ（仕様書 3.2 節、3.4 節）。
  class PowerOffSection
    include JSON::Serializable

    property enabled : Bool = true
    property target : PowerOffTarget = PowerOffTarget::Pressed
    # 押し始めてから切断するまでの時間。
    property hold_ms : Int32 = 2000
    # 押し始めてから予告の振動を出すまでの時間。
    property warn_ms : Int32 = 1000
    # 切断の後、次の判定を始めるまでの時間。
    property cooldown_ms : Int32 = 3000
    # 切断要求を送ってから、切れたことを確かめるまで待つ時間。
    property confirm_timeout_ms : Int32 = 3000

    def initialize
    end
  end

  # power_save セクション。両方のコントローラーが切れている間の省電力（仕様書 3.8 節）。
  #
  # 既定は無効とする。明るさと画質を変えるため、使う人が有効にしたときだけ動かす。
  class PowerSaveSection
    include JSON::Serializable

    property enabled : Bool = false
    # 両方が切れてから省電力へ入るまでの秒数。
    property delay_s : Int32 = 10
    # 明るさを下げるか。省電力を有効にしても、明るさは使う人が選んだときだけ下げる。
    property brightness : Bool = false
    # 省電力中の analogGain。nil なら HMD の最小値を使う。
    # null でも書き出す。省くと、設定ファイルを開いた利用者がこの項目を見つけられない。
    @[JSON::Field(emit_null: true)]
    property brightness_gain : Float64? = nil
    # 描画のプロファイルを省電力のものへ切り替えるか。
    property performance_profile : Bool = true

    def initialize
    end
  end

  # input セクション（仕様書 3.1 節、3.2 節）。
  class InputSection
    include JSON::Serializable

    property priority : InputPriority = InputPriority::Normal
    # UpdateActionState を呼ぶ間隔。主ループの周期でもある。
    property poll_interval_ms : Int32 = 20
    # 既定バインドで長押しに使うボタン。frame_controller の入力の名前（/input/ の後ろ）で書く。
    # 使える名前は SteamVR::Bindings が決め、検証もそちらが登録する。
    # SteamVR のバインド画面で利用者が別のバインドを選んでいれば、そちらが優先される。
    property left_button : String = "view"
    property right_button : String = "menu"

    def initialize
    end
  end

  # feedback セクション（仕様書 3.5 節）。
  class FeedbackSection
    include JSON::Serializable

    property haptics : Bool = true
    property amplitude : Float64 = 0.5

    def initialize
    end
  end

  # steamvr セクション（仕様書 3.6 節）。
  class SteamVRSection
    include JSON::Serializable

    # libopenvr_api.so の場所。空なら既定の場所を探す。
    property openvr_library_path : String = ""
    # SteamVR が動いていない間に初期化をやり直す間隔。
    property retry_interval_s : Int32 = 10

    def initialize
    end
  end

  # frame_link セクション。ヘッドセット内の SteamVR ウェブサーバーへの接続（仕様書 3.4 節）。
  class FrameLinkSection
    include JSON::Serializable

    property port : Int32 = 27062

    def initialize
    end
  end

  # dashboard セクション。SteamVR のダッシュボードに出す設定画面のタブ。
  class DashboardSection
    include JSON::Serializable

    property enabled : Bool = true

    def initialize
    end
  end

  # update セクション。
  class UpdateSection
    include JSON::Serializable

    property check_enabled : Bool = true
    # 追うチャンネル。"stable" は安定版だけ、"test" はプレリリースも見る。
    property channel : String = "stable"
    # 新しい版を見つけたら、systemd のタイマーが置き換えて再起動するか。
    # check_enabled が偽なら、これが真でも確かめない。
    property auto_update : Bool = true
    # 自動更新で確かめる間隔（時間）。タイマーは 30 分ごとに起き、この間隔が経っていなければ何もしない。
    property check_interval_h : Int32 = 6

    def initialize
    end
  end

  # 設定ファイル全体。
  #
  # 反映はスナップショットの差し替えで行うため、読み込んだ後は書き換えない。
  # 部分的に変えたいときは dup_snapshot で複製してから変える。
  class Root
    include JSON::Serializable

    property power_off : PowerOffSection = PowerOffSection.new
    property power_save : PowerSaveSection = PowerSaveSection.new
    property input : InputSection = InputSection.new
    property feedback : FeedbackSection = FeedbackSection.new
    property steamvr : SteamVRSection = SteamVRSection.new
    property frame_link : FrameLinkSection = FrameLinkSection.new
    property dashboard : DashboardSection = DashboardSection.new
    property update : UpdateSection = UpdateSection.new
    property log_level : String = "info"
    # CLI とログの表示言語。"auto" は環境変数 LANG などに従う。
    property language : String = "auto"

    def initialize
    end

    # 設定ファイルが存在しないときに書き出す初期設定。
    # 全項目を既定値で書き出すのは、ファイルを開いた利用者が項目を見つけられるようにするためである。
    def self.default : Root
      Root.new
    end

    # 設定スナップショットの複製。
    def dup_snapshot : Root
      Root.from_json(to_json)
    end
  end
end

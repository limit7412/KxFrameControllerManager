require "json"
require "../config/models"
require "../power_off/models"

# 設定画面のコンテキスト。
#
# ヘッドセット内のブラウザから開く Web 画面で、常駐の状態を見せ、設定を書き換え、手動で切断する。
# 待ち受けと HTTP の扱いは server.cr、画面が呼ぶ操作は usecase.cr にある。
# ここは画面とやりとりする値の形と、設定の書き換えの規則だけを持つ。
module WebUI
  # 片手ぶんの状態。
  #
  # 値が無いことも null として書く。省くと、画面の側で「無い」と「まだ届いていない」を区別できない。
  @[JSON::Serializable::Options(emit_nulls: true)]
  struct HandStatus
    include JSON::Serializable

    getter connected : Bool
    getter serial : String?
    # 既定バインドで長押しに使うボタン。
    getter button : String

    def initialize(@connected : Bool, @serial : String?, @button : String)
    end
  end

  # 画面へ見せる常駐の状態。主ループの外から読むため、組み立てたときの値の写しである。
  @[JSON::Serializable::Options(emit_nulls: true)]
  struct Snapshot
    include JSON::Serializable

    getter version : String
    getter locale : String
    getter steamvr_connected : Bool
    getter hands : Hash(String, HandStatus)
    # 最後に 27062 の疎通を確かめた結果。まだ確かめていなければ nil。
    getter link_reachable : Bool?
    # 省電力の状態（idle / waiting / checking / active）。
    getter power_save_state : String
    # 省電力で変えた値が戻されずに残っているか。
    getter power_save_pending : Bool
    # HMD の明るさの範囲。読めなければ nil。
    getter gain_range : Array(Float64)?
    # 切断を処理中か。
    getter busy : Bool
    # 最後に読んだ設定ファイルの誤り。
    getter config_errors : Array(String)

    def initialize(
      *,
      @version : String,
      @locale : String,
      @steamvr_connected : Bool,
      @hands : Hash(String, HandStatus),
      @link_reachable : Bool?,
      @power_save_state : String,
      @power_save_pending : Bool,
      @gain_range : Array(Float64)?,
      @busy : Bool,
      @config_errors : Array(String),
    )
    end
  end

  # 書き換えの要求が受け付けられない形だったことを表す。
  class PatchError < Exception
  end

  # 設定画面から書き換えられる項目。
  #
  # 画面から変えるのは利用者が日常的に触る項目だけにする。
  # ui を変えられると、保存した瞬間に画面へつながらなくなりうる。
  # steamvr、frame_link、update は環境に合わせて一度決めるものであり、設定ファイルで変える。
  EDITABLE = {
    "power_off"  => %w[enabled target hold_ms warn_ms cooldown_ms],
    "power_save" => %w[enabled delay_s brightness brightness_gain performance_profile],
    "input"      => %w[left_button right_button priority],
    "feedback"   => %w[haptics amplitude],
  }

  # 現在の設定から、画面が扱う項目だけを抜き出す。
  def self.editable(root : Config::Root) : Hash(String, Hash(String, JSON::Any))
    current = JSON.parse(root.to_json).as_h
    EDITABLE.to_h do |section, keys|
      values = current[section].as_h
      {section, keys.to_h { |key| {key, values[key]} }}
    end
  end

  # 現在の設定へ画面からの変更を重ねた、新しい設定を返す。
  #
  # 変更は設定ファイルと同じ入れ子の形で受け取り、書かれた項目だけを差し替える。
  # EDITABLE に無い項目や型の合わない値は PatchError にする。黙って捨てると、
  # 画面は保存できたと見せるのに設定は変わらない、という食い違いが起きる。
  # 範囲の検証はここでは行わない。config の usecase が保存の前に行う。
  def self.merge(root : Config::Root, patch : JSON::Any) : Config::Root
    changes = patch.as_h? || raise PatchError.new("変更はオブジェクトで渡す")
    merged = JSON.parse(root.to_json).as_h
    changes.each do |section, values|
      keys = EDITABLE[section]? || raise PatchError.new("#{section} は画面から変えられない")
      entries = values.as_h? || raise PatchError.new("#{section} はオブジェクトで渡す")
      target = merged[section].as_h
      entries.each do |key, value|
        raise PatchError.new("#{section}.#{key} は画面から変えられない") unless keys.includes?(key)
        target[key] = value
      end
    end
    Config::Root.from_json(merged.to_json)
  rescue exception : JSON::Error | TypeCastError
    raise PatchError.new("値の型が合わない: #{exception.message}")
  end
end

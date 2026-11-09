require "json"

# 両方のコントローラーが切れている間の省電力（仕様書 3.8 節）。
#
# 画面の明るさ（steamvr/analogGain）と描画のプロファイル（steamvr/performanceProfile）を下げ、
# どちらかのコントローラーがつながったら元に戻す。
# どちらも SteamVR ダッシュボードのスライダーと同じキーであり、反映は vrserver に任せる。
module PowerSave
  SECTION = "steamvr"

  # 明るさ。未設定なら SteamVR の既定（実機では 1.3）で動いている。
  ANALOG_GAIN_KEY = "analogGain"
  # 描画のプロファイル。実機の値は Performance だった（2026-11-09）。
  PERFORMANCE_PROFILE_KEY = "performanceProfile"
  # 省電力（Playtime）のプロファイルの名前が入っているキー。
  POWERSAVE_PROFILE_KEY = "powersaveSteamOSManagerCustomProfile"

  # 設定値を読んだ結果の種類。
  enum ReadStatus
    # 値が読めた。
    Value
    # 書かれておらず既定値も無い。戻すときは RemoveKeyInSection で消す。
    Unset
    # 読めなかった。そのキーには触らない。
    Failed
  end

  record FloatReading, status : ReadStatus, value : Float64 = 0.0
  record StringReading, status : ReadStatus, value : String = ""

  # 変える前の値 1 件。
  struct SavedValue
    include JSON::Serializable

    getter section : String
    getter key : String
    # 変える前に未設定だったか。真なら戻すときにキーを消す。
    getter unset : Bool
    getter float : Float64?
    getter string : String?

    def initialize(@section : String, @key : String, @unset : Bool, @float : Float64? = nil, @string : String? = nil)
    end

    def self.of_float(section : String, key : String, reading : FloatReading) : SavedValue
      new(section, key, reading.status.unset?, float: reading.status.value? ? reading.value : nil)
    end

    def self.of_string(section : String, key : String, reading : StringReading) : SavedValue
      new(section, key, reading.status.unset?, string: reading.status.value? ? reading.value : nil)
    end
  end

  # 戻し忘れを防ぐために書き出す状態（仕様書 3.8 節）。
  # 値を変える前に書き、戻し終えたら消す。
  struct SavedState
    include JSON::Serializable

    getter values : Array(SavedValue)

    def initialize(@values : Array(SavedValue))
    end
  end
end

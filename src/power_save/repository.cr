require "json"
require "./models"

module PowerSave
  # SteamVR の設定値の読み書きの境界。
  # 実装は steamvr/settings_repository.cr が IVRSettings で提供する。
  abstract class SettingsRepository
    # 設定値を読み書きできる状態か。
    abstract def available? : Bool

    abstract def read_float(section : String, key : String) : FloatReading
    abstract def read_string(section : String, key : String) : StringReading
    abstract def write_float(section : String, key : String, value : Float64) : Bool
    abstract def write_string(section : String, key : String, value : String) : Bool
    abstract def remove(section : String, key : String) : Bool

    # HMD の analogGain の下限と上限（DisplayMinAnalogGain_Float と DisplayMaxAnalogGain_Float）。
    # HMD が analogGain に対応していない、または読めないときは nil を返す。
    abstract def gain_range : {Float64, Float64}?
  end

  # 戻し忘れを防ぐファイルの境界。
  abstract class StateRepository
    abstract def exists? : Bool
    abstract def load : SavedState
    abstract def save(state : SavedState) : Nil
    abstract def delete : Nil
  end

  # 実ファイルに対する StateRepository 実装。
  class FileStateRepository < StateRepository
    getter path : String

    def initialize(@path : String)
    end

    def exists? : Bool
      File.exists?(@path)
    end

    def load : SavedState
      SavedState.from_json(File.read(@path))
    end

    # 書き込み中に落ちても読めない状態を残さないよう、一時ファイルを経由して置き換える。
    def save(state : SavedState) : Nil
      Dir.mkdir_p(File.dirname(@path))
      temporary = "#{@path}.tmp"
      File.write(temporary, state.to_pretty_json)
      File.rename(temporary, @path)
    end

    def delete : Nil
      File.delete?(@path)
    end
  end
end

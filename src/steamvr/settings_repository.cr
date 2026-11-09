require "../power_save/repository"
require "./ffi"
require "./repository"

module SteamVR
  # IVRSettings で SteamVR の設定値を読み書きする（仕様書 3.8 節）。
  #
  # SteamVR の設定ファイルには直接書かない（仕様書 7.1 節）。
  # IVRSettings を通せば、反映と永続化は vrserver が行い、ダッシュボードの表示とも食い違わない。
  class SettingsRepository < PowerSave::SettingsRepository
    def initialize(@repository : Repository)
    end

    def available? : Bool
      @repository.settings_available?
    end

    def read_float(section : String, key : String) : PowerSave::FloatReading
      value, error = @repository.get_float_setting(section, key)
      PowerSave::FloatReading.new(status_of(error), value.to_f64)
    end

    def read_string(section : String, key : String) : PowerSave::StringReading
      value, error = @repository.get_string_setting(section, key)
      PowerSave::StringReading.new(status_of(error), value)
    end

    def write_float(section : String, key : String, value : Float64) : Bool
      @repository.set_float_setting(section, key, value.to_f32) == LibOpenVR::SETTINGS_ERROR_NONE
    end

    def write_string(section : String, key : String, value : String) : Bool
      @repository.set_string_setting(section, key, value) == LibOpenVR::SETTINGS_ERROR_NONE
    end

    def remove(section : String, key : String) : Bool
      @repository.remove_setting(section, key) == LibOpenVR::SETTINGS_ERROR_NONE
    end

    def gain_range : {Float64, Float64}?
      hmd = LibOpenVR::TRACKED_DEVICE_INDEX_HMD
      return nil unless @repository.bool_property(hmd, LibOpenVR::PROP_DISPLAY_SUPPORTS_ANALOG_GAIN_BOOL)
      min = @repository.float_property(hmd, LibOpenVR::PROP_DISPLAY_MIN_ANALOG_GAIN_FLOAT)
      max = @repository.float_property(hmd, LibOpenVR::PROP_DISPLAY_MAX_ANALOG_GAIN_FLOAT)
      return nil unless min && max && min.finite? && max.finite? && 0 < min && min <= max
      {min.to_f64, max.to_f64}
    end

    # 未設定でも既定値を持つキーは、エラーにならず既定値が返る。
    # その場合は「値が読めた」として扱い、戻すときもその値を書く。
    # 未設定と分かるのは、既定値も無いキー（UnsetSettingHasNoDefault）だけである。
    private def status_of(error : Int32) : PowerSave::ReadStatus
      case error
      when LibOpenVR::SETTINGS_ERROR_NONE                 then PowerSave::ReadStatus::Value
      when LibOpenVR::SETTINGS_ERROR_UNSET_HAS_NO_DEFAULT then PowerSave::ReadStatus::Unset
      else                                                     PowerSave::ReadStatus::Failed
      end
    end
  end
end

require "../power_off/repository"
require "./ffi"
require "./repository"

module SteamVR
  # OpenVR からコントローラーの左右、接続、シリアルを引く（仕様書 3.3 節）。
  class DeviceRepository < PowerOff::DeviceRepository
    def initialize(@repository : Repository)
    end

    def available? : Bool
      @repository.opened?
    end

    def device_index(hand : PowerOff::Hand) : UInt32?
      role = hand.left? ? LibOpenVR::CONTROLLER_ROLE_LEFT_HAND : LibOpenVR::CONTROLLER_ROLE_RIGHT_HAND
      @repository.controller_index(role)
    end

    def connected?(hand : PowerOff::Hand) : Bool
      index = device_index(hand)
      !index.nil? && @repository.device_connected?(index)
    end

    def serial(hand : PowerOff::Hand) : String?
      index = device_index(hand)
      return nil unless index
      @repository.string_property(index, LibOpenVR::PROP_SERIAL_NUMBER_STRING).presence
    end
  end
end

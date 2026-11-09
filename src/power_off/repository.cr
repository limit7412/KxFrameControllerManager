require "./models"

module PowerOff
  # 長押しを読む入力の境界（仕様書 3.1 節）。
  # 実装は steamvr/input_repository.cr が SteamVR Input で提供する。
  abstract class InputRepository
    # 入力を読める状態か。SteamVR につながっていて、アクションを読ませ終えているとき真になる。
    abstract def ready? : Bool

    # 入力の状態を取り込む（UpdateActionState）。取り込めたら true を返す。
    abstract def update : Bool

    # 直近の update の時点で、その手で切断のアクションが押されているか。
    abstract def pressed?(hand : Hand) : Bool
  end

  # 振動の境界（仕様書 3.5 節）。
  abstract class HapticRepository
    # start_s 秒後から duration_s 秒、amplitude（0.0 から 1.0）の強さで振動させる。
    abstract def vibrate(hand : Hand, start_s : Float64, duration_s : Float64, amplitude : Float64) : Nil
  end

  # コントローラーの左右とシリアルを引く境界（仕様書 3.3 節）。
  # 実装は steamvr/device_repository.cr が OpenVR で提供する。
  abstract class DeviceRepository
    # OpenVR が使える状態か。
    abstract def available? : Bool

    # その手のデバイス番号。割り当てが無ければ nil。
    abstract def device_index(hand : Hand) : UInt32?

    # その手のコントローラーがつながっているか。
    abstract def connected?(hand : Hand) : Bool

    # その手のコントローラーの OpenVR 側のシリアル（Prop_SerialNumber_String）。
    abstract def serial(hand : Hand) : String?
  end

  # 切断要求を送る境界（仕様書 3.4 節）。
  # 実装は frame_link/websocket_repository.cr が 27062 との WebSocket で提供する。
  abstract class DisconnectRepository
    # コントローラーの一覧を取る。取れなければ nil を返す。
    abstract def list : ControllerList?

    # 切断要求を送る。送れたら true を返す。切れたかどうかはこの戻り値では分からない。
    abstract def disconnect(serial : String) : Bool
  end
end

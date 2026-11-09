# 長押しによる切断の中立ドメイン（仕様書 4.1 節）。
#
# 長押しの判定、切断の対象の決定、切断の実行と確認を担う。
# OpenVR にも 27062 にも依存せず、外部とのやりとりは repository.cr の抽象を通す。
module PowerOff
  # 左右のどちらの手か。
  enum Hand
    Left
    Right

    # 反対側の手。
    def other : Hand
      left? ? Right : Left
    end

    # CLI の引数とログに使う綴り。
    def label : String
      left? ? "left" : "right"
    end
  end

  # 27062 の一覧に載っている、接続中のコントローラー 1 台（仕様書 4.3 節）。
  struct LinkedController
    # 27062 側のシリアル。OpenVR のシリアルから先頭の「cv.」を外した形である。
    getter serial : String
    # 27062 が報告した左右。報告が無ければ nil。
    getter hand : Hand?

    def initialize(@serial : String, @hand : Hand? = nil)
    end
  end

  # 27062 から取ったコントローラーの一覧（種別 44）。
  struct ControllerList
    # 接続中のもの（field3）。
    getter connected : Array(LinkedController)
    # ペアリング済みのもの（field4）のシリアル。切断したものもここに残る。
    getter paired : Array(String)

    def initialize(@connected : Array(LinkedController) = [] of LinkedController, @paired : Array(String) = [] of String)
    end

    def connected?(serial : String) : Bool
      @connected.any? { |controller| controller.serial == serial }
    end

    def find(serial : String) : LinkedController?
      @connected.find { |controller| controller.serial == serial }
    end
  end

  # 切断する 1 台。対象を決めた時点の値をまとめて持つ。
  struct Target
    # どちらの手として切るか。シリアルで直接指定したときは nil。
    getter hand : Hand?
    # 27062 へ送るシリアル。
    getter serial : String
    # OpenVR のデバイス番号。切れたことを VREvent_TrackedDeviceDeactivated で確かめるのに使う。
    # OpenVR を使わずに決めたときは nil。
    getter device_index : UInt32?

    def initialize(@hand : Hand?, @serial : String, @device_index : UInt32? = nil)
    end

    def label : String
      hand.try(&.label) || serial
    end
  end

  # 切断 1 台ごとの結末。
  enum Outcome
    # 切れたことを確かめた。
    Disconnected
    # 要求は送ったが、送り直しても切れたことを確かめられなかった。
    Unconfirmed
    # 27062 へ要求を送れなかった。
    SendFailed
  end

  struct Result
    getter target : Target
    getter outcome : Outcome

    def initialize(@target : Target, @outcome : Outcome)
    end
  end

  # OpenVR のシリアルを 27062 のシリアルの形へ直す（仕様書 3.3 節）。
  #
  # 実機では、OpenVR の cv.91481bedcdfa が 27062 の 91481bedcdfa と一致した（2026-11-09）。
  # 先頭の「cv.」だけを外し、それ以外は手を加えない。
  # 大文字と小文字を揃えるような推測の変換はしない。違うコントローラーと一致させてしまうと、
  # 押していない側を切ることになる。
  def self.link_serial(openvr_serial : String) : String
    openvr_serial.lchop("cv.")
  end
end

require "../power_off/models"

# ヘッドセット内の SteamVR ウェブサーバー（127.0.0.1:27062）との通信（仕様書 3.4 節、4.3 節）。
module FrameLink
  # 27062 のバイナリメッセージの符号化と復号（仕様書 4.3 節）。
  #
  # メッセージは「ヘッダの長さ（varint）、ヘッダ、本体」の並びである。
  # ヘッダと本体はどちらも protobuf の形式で、ヘッダの field1 が種別を表す。
  # 実機で取った `02 08 2d 0a 00` は、長さ 2 のヘッダ `08 2d`（種別 45）と本体 `0a 00` に分かれる。
  #
  # protobuf のライブラリは入れず、使う分だけの varint と長さ付きフィールドを自前で扱う。
  # 必要なのは数種類のメッセージの数個のフィールドだけで、スキーマも公開されていない。
  module Codec
    # 送る要求の種別。
    TYPE_REQUEST = 45
    # 一覧の応答の種別。
    TYPE_CONTROLLER_LIST = 44

    # 要求（種別 45）の本体のフィールド。
    REQUEST_FIELD_UPDATE     = 1
    REQUEST_FIELD_DISCONNECT = 5

    # 一覧（種別 44）の本体のフィールド。
    LIST_FIELD_CONNECTED = 3
    LIST_FIELD_PAIRED    = 4

    # 一覧の要素のフィールド。
    CONTROLLER_FIELD_SERIAL = 1
    CONTROLLER_FIELD_HAND   = 2

    WIRE_VARINT = 0
    WIRE_I64    = 1
    WIRE_LENGTH = 2
    WIRE_I32    = 5

    # 復号できない入力。
    class Error < Exception
    end

    # 1 件のフィールド。varint なら value に、長さ付きなら bytes に値が入る。
    record Field, number : Int32, wire : Int32, value : UInt64, bytes : Bytes

    # 復号したメッセージ。
    record Message, type : Int32, body : Bytes

    # 一覧の要求。`02 08 2d 0a 00`。
    def self.list_request : Bytes
      encode(TYPE_REQUEST, length_field(REQUEST_FIELD_UPDATE, Bytes.empty))
    end

    # 切断の要求。field5（disconnect_controller）の中の field1 にシリアルを入れる。
    def self.disconnect_request(serial : String) : Bytes
      inner = length_field(CONTROLLER_FIELD_SERIAL, serial.to_slice)
      encode(TYPE_REQUEST, length_field(REQUEST_FIELD_DISCONNECT, inner))
    end

    def self.encode(type : Int32, body : Bytes) : Bytes
      header = varint_field(1, type.to_u64)
      io = IO::Memory.new
      write_varint(io, header.size.to_u64)
      io.write(header)
      io.write(body)
      io.to_slice
    end

    # メッセージを復号する。形が合わなければ Error を上げる。
    def self.decode(data : Bytes) : Message
      io = IO::Memory.new(data, writeable: false)
      header_size = read_varint(io)
      raise Error.new("ヘッダの長さが残りより長い") if header_size > io.size - io.pos
      header = data[io.pos, header_size.to_i]
      body = data[(io.pos + header_size.to_i)..]

      type = fields(header).find { |field| field.number == 1 && field.wire == WIRE_VARINT }
      raise Error.new("ヘッダに種別が無い") unless type
      Message.new(type.value.to_i, body)
    end

    # 一覧（種別 44）の本体を読む。
    #
    # 接続中の要素の field2 は 1 が左、2 が右である（2026-11-09 に実機で確認）。
    # それ以外の値と、field2 が無い場合は左右不明として扱う。
    def self.parse_controller_list(body : Bytes) : PowerOff::ControllerList
      connected = [] of PowerOff::LinkedController
      paired = [] of String
      fields(body).each do |field|
        next unless field.wire == WIRE_LENGTH
        case field.number
        when LIST_FIELD_CONNECTED
          item = fields(field.bytes)
          serial = string_of(item, CONTROLLER_FIELD_SERIAL)
          next unless serial
          hand = case item.find { |f| f.number == CONTROLLER_FIELD_HAND && f.wire == WIRE_VARINT }.try(&.value)
                 when 1 then PowerOff::Hand::Left
                 when 2 then PowerOff::Hand::Right
                 end
          connected << PowerOff::LinkedController.new(serial, hand)
        when LIST_FIELD_PAIRED
          serial = string_of(fields(field.bytes), CONTROLLER_FIELD_SERIAL)
          paired << serial if serial
        end
      end
      PowerOff::ControllerList.new(connected, paired)
    end

    # protobuf の本体をフィールドの並びに分ける。知らない種類のフィールドも読み飛ばせるよう、
    # 4 つの wire type をすべて扱う。
    def self.fields(data : Bytes) : Array(Field)
      io = IO::Memory.new(data, writeable: false)
      result = [] of Field
      while io.pos < io.size
        key = read_varint(io)
        number = (key >> 3).to_i
        wire = (key & 0x7).to_i
        case wire
        when WIRE_VARINT
          result << Field.new(number, wire, read_varint(io), Bytes.empty)
        when WIRE_LENGTH
          size = read_varint(io)
          raise Error.new("フィールド #{number} の長さが残りより長い") if size > io.size - io.pos
          bytes = data[io.pos, size.to_i]
          io.skip(size)
          result << Field.new(number, wire, 0_u64, bytes)
        when WIRE_I64
          raise Error.new("フィールド #{number} が途中で切れている") if io.size - io.pos < 8
          io.skip(8)
        when WIRE_I32
          raise Error.new("フィールド #{number} が途中で切れている") if io.size - io.pos < 4
          io.skip(4)
        else
          raise Error.new("扱えない wire type #{wire}")
        end
      end
      result
    end

    # ログに残す 16 進表記（仕様書 4.3 節）。
    def self.hex(data : Bytes) : String
      data.map { |byte| byte.to_s(16).rjust(2, '0') }.join(" ")
    end

    private def self.string_of(fields : Array(Field), number : Int32) : String?
      field = fields.find { |f| f.number == number && f.wire == WIRE_LENGTH }
      return nil unless field
      value = String.new(field.bytes)
      value.valid_encoding? && !value.empty? ? value : nil
    end

    private def self.varint_field(number : Int32, value : UInt64) : Bytes
      io = IO::Memory.new
      write_varint(io, (number.to_u64 << 3) | WIRE_VARINT)
      write_varint(io, value)
      io.to_slice
    end

    private def self.length_field(number : Int32, value : Bytes) : Bytes
      io = IO::Memory.new
      write_varint(io, (number.to_u64 << 3) | WIRE_LENGTH)
      write_varint(io, value.size.to_u64)
      io.write(value)
      io.to_slice
    end

    private def self.write_varint(io : IO, value : UInt64) : Nil
      loop do
        byte = (value & 0x7f).to_u8
        value >>= 7
        if value.zero?
          io.write_byte(byte)
          break
        end
        io.write_byte(byte | 0x80)
      end
    end

    private def self.read_varint(io : IO) : UInt64
      result = 0_u64
      shift = 0
      loop do
        byte = io.read_byte
        raise Error.new("varint が途中で切れている") unless byte
        raise Error.new("varint が長すぎる") if shift >= 64
        result |= (byte & 0x7f).to_u64 << shift
        return result if byte & 0x80 == 0
        shift += 7
      end
    end
  end
end

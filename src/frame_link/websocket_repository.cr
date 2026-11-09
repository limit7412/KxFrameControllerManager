require "base64"
require "http/web_socket"
require "log"
require "socket"
require "../power_off/repository"
require "./codec"

module FrameLink
  # 27062 との WebSocket で一覧の取得と切断要求を行う（仕様書 3.4 節）。
  #
  # 接続は要求のたびに張り、終わったら閉じる。常時接続にしないのは、
  # Steam UI が使うサーバーに余計な負荷と状態を持ち込まないためである。
  #
  # 標準ライブラリの HTTP::WebSocket.new は、接続と読み出しに時限を付けられない。
  # サーバーが受け付けたまま応えないと、待っているファイバが戻らなくなる。
  # そのためソケットは自分で開いて時限を付け、ハンドシェイクもここで行う。
  class WebSocketRepository < PowerOff::DisconnectRepository
    Log = ::Log.for("frame_link")

    HOST = "127.0.0.1"

    # 27062 へつなぐ前に送るテキスト。Steam UI と同じ手順である。
    HELLO = "steam_connect"

    CONNECT_TIMEOUT = 2.seconds
    # 一覧の応答を待つ長さ。
    LIST_TIMEOUT = 3.seconds
    # 切断要求を送った後、応答を読んでおく長さ。応答の中身は確認に使わず、ログに残すだけである。
    DISCONNECT_LINGER = 500.milliseconds

    property port : Int32

    def initialize(@port : Int32 = 27062)
    end

    def list : PowerOff::ControllerList?
      session do |protocol|
        send(protocol, Codec.list_request)
        message = receive_until(protocol, Time.instant + LIST_TIMEOUT) { |m| m.type == Codec::TYPE_CONTROLLER_LIST }
        unless message
          Log.warn { "27062 から一覧の応答が来なかった" }
          next nil
        end
        Codec.parse_controller_list(message.body)
      end
    end

    def disconnect(serial : String) : Bool
      result = session do |protocol|
        send(protocol, Codec.disconnect_request(serial))
        # 応答は待たなくてよいが、読まずに閉じると送った要求が届く前に切れることがある。
        receive_until(protocol, Time.instant + DISCONNECT_LINGER) { false }
        true
      end
      result == true
    end

    # 接続を張って block を呼び、必ず閉じる。どこかで失敗したら nil を返す。
    private def session(& : HTTP::WebSocket::Protocol -> T) : T? forall T
      protocol = open
      begin
        protocol.send(HELLO)
        yield protocol
      ensure
        begin
          protocol.close
        rescue IO::Error
        end
      end
      # 標準ライブラリは不正なフレームを素の Exception で知らせるため、種類を絞らずに受ける。
      # どの失敗でも、切断しない側へ倒すだけで常駐は続ける。


    rescue exception
      Log.warn { "27062 との通信に失敗した: #{exception.message}" }
      nil
    end

    private def open : HTTP::WebSocket::Protocol
      socket = TCPSocket.new(HOST, @port, connect_timeout: CONNECT_TIMEOUT)
      begin
        socket.read_timeout = LIST_TIMEOUT
        socket.write_timeout = CONNECT_TIMEOUT
        handshake(socket)
      rescue exception
        socket.close
        raise exception
      end
      HTTP::WebSocket::Protocol.new(socket, masked: true)
    end

    # RFC 6455 のハンドシェイク。
    # Origin を同じサーバーにしておくと、Web シークレットを求められない（仕様書 3.4 節）。
    private def handshake(socket : TCPSocket) : Nil
      key = Base64.strict_encode(Random::Secure.random_bytes(16))
      headers = HTTP::Headers{
        "Host"                  => "#{HOST}:#{@port}",
        "Origin"                => "http://#{HOST}:#{@port}",
        "Connection"            => "Upgrade",
        "Upgrade"               => "websocket",
        "Sec-WebSocket-Version" => HTTP::WebSocket::Protocol::VERSION,
        "Sec-WebSocket-Key"     => key,
      }
      HTTP::Request.new("GET", "/", headers).to_io(socket)
      socket.flush

      response = HTTP::Client::Response.from_io(socket, ignore_body: true)
      unless response.status.switching_protocols?
        raise Socket::Error.new("ハンドシェイクを断られた（#{response.status.code}）")
      end
      unless response.headers["Sec-WebSocket-Accept"]? == HTTP::WebSocket::Protocol.key_challenge(key)
        raise Socket::Error.new("ハンドシェイクの応答が合わない")
      end
    end

    private def send(protocol : HTTP::WebSocket::Protocol, data : Bytes) : Nil
      Log.debug { "27062 へ送る: #{Codec.hex(data)}" }
      protocol.send(data)
    end

    # 期限まで受け取り続け、条件に合うメッセージが来たら返す。
    # 読み出しの時限に掛かったら、それ以上は待たずに nil を返す。
    private def receive_until(protocol : HTTP::WebSocket::Protocol, deadline : Time::Instant, & : Codec::Message -> Bool) : Codec::Message?
      buffer = Bytes.new(4096)
      message = IO::Memory.new
      while Time.instant < deadline
        info = begin
          protocol.receive(buffer)
        rescue IO::TimeoutError
          return nil
        end

        case info.opcode
        when .binary?
          message.write(buffer[0, info.size])
          next unless info.final
          data = message.to_slice.dup
          message.clear
          Log.debug { "27062 から受けた: #{Codec.hex(data)}" }
          decoded = begin
            Codec.decode(data)
          rescue exception : Codec::Error
            Log.debug { "27062 のメッセージを読めなかった: #{exception.message}" }
            next
          end
          return decoded if yield decoded
        when .close?
          return nil
        when .ping?
          protocol.pong(String.new(buffer[0, info.size])) if info.final
        else
          # テキストなど、使わないものは読み捨てる。
          message.clear if info.final
        end
      end
      nil
    end
  end
end

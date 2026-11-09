require "../spec_helper"
require "http/server"

# 27062 の代わりに立てるローカルの WebSocket サーバー。
# 受け取ったものを記録し、一覧の要求には決まった一覧を返す。
private class FakeServer
  getter origins = [] of String?
  getter texts = [] of String
  getter binaries = [] of Bytes
  getter port : Int32
  property connected = ["91481bedcdfa"]
  # 真にすると、一覧の要求に応えない。
  property silent = false

  def initialize
    handler = HTTP::WebSocketHandler.new do |socket, context|
      @origins << context.request.headers["Origin"]?
      socket.on_message { |text| @texts << text }
      socket.on_binary do |data|
        @binaries << data.dup
        next if @silent
        message = FrameLink::Codec.decode(data)
        fields = FrameLink::Codec.fields(message.body)
        if fields.any? { |field| field.number == 1 }
          socket.send(FrameLink::Codec.encode(44, list_body))
        elsif fields.any? { |field| field.number == 5 }
          serial = String.new(FrameLink::Codec.fields(fields.first.bytes).first.bytes)
          @connected.delete(serial)
          socket.send(FrameLink::Codec.encode(44, list_body))
        end
      end
    end
    @server = HTTP::Server.new([handler] of HTTP::Handler)
    @port = @server.bind_tcp("127.0.0.1", 0).port
    spawn { @server.listen }
    Fiber.yield
  end

  def close : Nil
    @server.close
  end

  private def list_body : Bytes
    io = IO::Memory.new
    @connected.each do |serial|
      io.write_byte(0x1a_u8)
      io.write_byte((serial.bytesize + 4).to_u8)
      io.write_byte(0x0a_u8)
      io.write_byte(serial.bytesize.to_u8)
      io.write(serial.to_slice)
      io.write_byte(0x10_u8)
      io.write_byte(1_u8)
    end
    io.to_slice
  end
end

describe FrameLink::WebSocketRepository do
  it "Origin を付けてつなぎ、steam_connect の後に一覧の要求を送る" do
    server = FakeServer.new
    begin
      list = FrameLink::WebSocketRepository.new(server.port).list.not_nil!
      list.connected.map(&.serial).should eq ["91481bedcdfa"]
      list.connected.first.hand.should eq PowerOff::Hand::Left

      server.origins.should eq ["http://127.0.0.1:#{server.port}"]
      server.texts.should eq ["steam_connect"]
      server.binaries.should eq [FrameLink::Codec.list_request]
    ensure
      server.close
    end
  end

  it "切断の要求を送る" do
    server = FakeServer.new
    begin
      repository = FrameLink::WebSocketRepository.new(server.port)
      repository.disconnect("91481bedcdfa").should be_true
      server.binaries.should eq [FrameLink::Codec.disconnect_request("91481bedcdfa")]
      repository.list.not_nil!.connected.should be_empty
    ensure
      server.close
    end
  end

  it "サーバーが無ければ nil と false を返す" do
    server = FakeServer.new
    port = server.port
    server.close
    repository = FrameLink::WebSocketRepository.new(port)
    repository.list.should be_nil
    repository.disconnect("91481bedcdfa").should be_false
  end

  it "一覧の応答が来なければ時限で nil を返す" do
    server = FakeServer.new
    server.silent = true
    begin
      started = Time.instant
      FrameLink::WebSocketRepository.new(server.port).list.should be_nil
      (Time.instant - started).should be < 5.seconds
    ensure
      server.close
    end
  end
end

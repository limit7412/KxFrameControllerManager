require "../spec_helper"

private def bytes(hex : String) : Bytes
  hex.split.map(&.to_u8(16)).to_a.to_unsafe.to_slice(hex.split.size).dup
end

# 種別 44 の本体を組み立てる。仕様書 4.3 節の構造（field3 が接続中、field4 がペアリング済み）に従う。
private def controller_list_body(connected : Array({String, Int32}), paired : Array(String)) : Bytes
  io = IO::Memory.new
  connected.each do |serial, hand|
    item = IO::Memory.new
    item.write_byte(0x0a_u8)
    item.write_byte(serial.bytesize.to_u8)
    item.write(serial.to_slice)
    item.write_byte(0x10_u8)
    item.write_byte(hand.to_u8)
    io.write_byte(0x1a_u8)
    io.write_byte(item.size.to_u8)
    io.write(item.to_slice)
  end
  paired.each do |serial|
    io.write_byte(0x22_u8)
    io.write_byte((serial.bytesize + 2).to_u8)
    io.write_byte(0x0a_u8)
    io.write_byte(serial.bytesize.to_u8)
    io.write(serial.to_slice)
  end
  io.to_slice
end

describe FrameLink::Codec do
  it "一覧の要求は実機で確かめたバイト列と一致する" do
    FrameLink::Codec.list_request.should eq bytes("02 08 2d 0a 00")
  end

  it "切断の要求は field5 の中の field1 にシリアルを入れる" do
    expected = bytes("02 08 2d 2a 0e 0a 0c") + "91481bedcdfa".to_slice
    FrameLink::Codec.disconnect_request("91481bedcdfa").should eq expected
  end

  it "ヘッダの長さに従って種別と本体を分ける" do
    message = FrameLink::Codec.decode(bytes("02 08 2c 1a 00"))
    message.type.should eq 44
    message.body.should eq bytes("1a 00")
  end

  it "知らないフィールドを読み飛ばして一覧を読む" do
    body = controller_list_body([{"91481bedcdfa", 1}, {"5dd5caddfde0", 2}], ["91481bedcdfa", "5dd5caddfde0", "000000000000"])
    # 64 ビット固定長と 32 ビット固定長と varint のフィールドを足しても読める。
    extra = bytes("09 01 02 03 04 05 06 07 08 15 01 02 03 04 28 07")
    message = FrameLink::Codec.decode(FrameLink::Codec.encode(44, body + extra))
    list = FrameLink::Codec.parse_controller_list(message.body)

    list.connected.map(&.serial).should eq ["91481bedcdfa", "5dd5caddfde0"]
    list.connected.map(&.hand).should eq [PowerOff::Hand::Left, PowerOff::Hand::Right]
    list.paired.should eq ["91481bedcdfa", "5dd5caddfde0", "000000000000"]
  end

  it "field2 が 1 でも 2 でもなければ左右不明とする" do
    list = FrameLink::Codec.parse_controller_list(controller_list_body([{"91481bedcdfa", 3}], [] of String))
    list.connected.first.hand.should be_nil
  end

  it "途中で切れた入力は Error にする" do
    expect_raises(FrameLink::Codec::Error) { FrameLink::Codec.decode(bytes("05 08 2c")) }
    expect_raises(FrameLink::Codec::Error) { FrameLink::Codec.fields(bytes("1a 05 0a")) }
    expect_raises(FrameLink::Codec::Error) { FrameLink::Codec.fields(bytes("08 ff")) }
  end

  it "16 進表記はバイトごとに空白で区切る" do
    FrameLink::Codec.hex(bytes("02 08 2d 0a 00")).should eq "02 08 2d 0a 00"
  end
end

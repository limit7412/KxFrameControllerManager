module Runtime
  # コマンドの解釈（仕様書 3.7 節）。
  #
  # 引数を読んで何を実行するかを決めるだけで、実行は composition root（main.cr）が行う。
  module CLI
    enum Command
      Run
      Status
      List
      Disconnect
      Install
      Uninstall
      Update
      Channel
      Version
      Help
    end

    # 解釈の結果。argument は disconnect の対象（left、right、both、シリアル）、update の --auto、
    # channel の切り替え先（stable、test）に使う。
    # error が入っていれば、使い方の誤りとして終了コード 2 で終える。
    record Parsed, command : Command, argument : String? = nil, error : String? = nil

    AUTO = "--auto"

    # channel が受け付ける綴り。設定 update.channel の値（Update::CHANNELS）と同じものを並べる。
    # CLI は update を知らないため、同じ並びであることは spec で確かめる。
    CHANNELS = %w[stable test]

    def self.parse(args : Array(String)) : Parsed
      name = args.first?
      rest = args[1..]? || [] of String
      case name
      when "run"       then no_argument(Command::Run, rest)
      when "status"    then no_argument(Command::Status, rest)
      when "list"      then no_argument(Command::List, rest)
      when "install"   then no_argument(Command::Install, rest)
      when "uninstall" then no_argument(Command::Uninstall, rest)
      when "update"
        # --auto は自動更新のタイマーが付ける。設定の有効と間隔に従い、置き換えた版の起動を確かめる。
        return Parsed.new(Command::Update, AUTO) if rest == [AUTO]
        no_argument(Command::Update, rest)
      when "channel"
        # 引数が無ければ今のチャンネルを見せ、あればそのチャンネルへ切り替える。
        return Parsed.new(Command::Channel) if rest.empty?
        target = rest.first
        return Parsed.new(Command::Channel, target, "cli.channel_invalid") if rest.size > 1 || !CHANNELS.includes?(target)
        Parsed.new(Command::Channel, target)
      when "version", "--version" then Parsed.new(Command::Version)
      when nil                    then Parsed.new(Command::Help, error: "")
      when "help", "--help", "-h" then Parsed.new(Command::Help)
      when "disconnect"
        target = rest.first?
        return Parsed.new(Command::Disconnect, error: "cli.disconnect_needs_target") if target.nil? || target.empty? || rest.size > 1
        Parsed.new(Command::Disconnect, target)
      else
        Parsed.new(Command::Help, name, "cli.unknown_command")
      end
    end

    private def self.no_argument(command : Command, rest : Array(String)) : Parsed
      return Parsed.new(command) if rest.empty?
      Parsed.new(command, rest.first, "cli.unexpected_argument")
    end
  end
end

require "../spec_helper"

describe Runtime::CLI do
  it "コマンドを読み分ける" do
    Runtime::CLI.parse(["run"]).command.should eq Runtime::CLI::Command::Run
    Runtime::CLI.parse(["status"]).command.should eq Runtime::CLI::Command::Status
    Runtime::CLI.parse(["--version"]).command.should eq Runtime::CLI::Command::Version
    Runtime::CLI.parse(["help"]).error.should be_nil
  end

  it "disconnect は対象を 1 つ取る" do
    parsed = Runtime::CLI.parse(["disconnect", "left"])
    parsed.command.should eq Runtime::CLI::Command::Disconnect
    parsed.argument.should eq "left"
    parsed.error.should be_nil

    Runtime::CLI.parse(["disconnect"]).error.should eq "cli.disconnect_needs_target"
    Runtime::CLI.parse(["disconnect", "left", "right"]).error.should eq "cli.disconnect_needs_target"
  end

  it "update は --auto だけを受け付ける" do
    Runtime::CLI.parse(["update"]).argument.should be_nil
    auto = Runtime::CLI.parse(["update", "--auto"])
    auto.command.should eq Runtime::CLI::Command::Update
    auto.argument.should eq Runtime::CLI::AUTO
    auto.error.should be_nil
    Runtime::CLI.parse(["update", "--force"]).error.should eq "cli.unexpected_argument"
    Runtime::CLI.parse(["update", "--auto", "x"]).error.should eq "cli.unexpected_argument"
  end

  it "channel は引数なしで今のチャンネルを見せ、stable か test で切り替える" do
    show = Runtime::CLI.parse(["channel"])
    show.command.should eq Runtime::CLI::Command::Channel
    show.argument.should be_nil
    show.error.should be_nil

    %w[stable test].each do |name|
      parsed = Runtime::CLI.parse(["channel", name])
      parsed.argument.should eq name
      parsed.error.should be_nil
    end

    Runtime::CLI.parse(["channel", "beta"]).error.should eq "cli.channel_invalid"
    Runtime::CLI.parse(["channel", "test", "stable"]).error.should eq "cli.channel_invalid"
  end

  it "channel が受け付ける綴りは、設定 update.channel の値と同じ" do
    Runtime::CLI::CHANNELS.should eq Update::CHANNELS
    Runtime::CLI::CHANNELS.should eq Config::Usecase::UPDATE_CHANNELS
  end

  it "引数を取らないコマンドへの引数と、不明なコマンドを誤りにする" do
    Runtime::CLI.parse(["status", "x"]).error.should eq "cli.unexpected_argument"
    unknown = Runtime::CLI.parse(["foo"])
    unknown.error.should eq "cli.unknown_command"
    unknown.argument.should eq "foo"
  end

  it "引数が無ければ使い方を出して終了コード 2 にする" do
    Runtime::CLI.parse([] of String).error.should eq ""
  end

  it "使い方とエラーの文字列は日本語と英語の両方にある" do
    %w[cli.usage cli.unknown_command cli.unexpected_argument cli.disconnect_needs_target].each do |key|
      Runtime::I18n::LOCALES["ja"].has_key?(key).should be_true
      Runtime::I18n::LOCALES["en"].has_key?(key).should be_true
    end
    Runtime::I18n::LOCALES["ja"].keys.sort.should eq Runtime::I18n::LOCALES["en"].keys.sort
  end
end

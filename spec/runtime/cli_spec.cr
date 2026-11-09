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

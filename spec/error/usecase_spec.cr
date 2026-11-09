require "../spec_helper"
require "log/spec"

describe Error::Usecase do
  it "例外を握りつぶして後続を止めない" do
    reached = false
    usecase = Error::Usecase.new

    usecase.guard("error.steamvr_poll") { raise "壊れた" }
    reached = true

    reached.should be_true
  end

  it "文脈のキーをログ用の解決に通し、例外と一緒に error で残す" do
    usecase = Error::Usecase.new
    usecase.log_text = ->(key : String) { "ログ: #{key}" }

    Log.capture("error") do |logs|
      usecase.guard("error.steamvr_poll") { raise "壊れた" }

      logs.check(:error, "ログ: error.steamvr_poll")
      logs.entry.exception.try(&.message).should eq "壊れた"
    end
  end

  it "解決を差し込む前はキーをそのまま残す" do
    usecase = Error::Usecase.new

    Log.capture("error") do |logs|
      usecase.guard("error.steamvr_poll") { raise "壊れた" }

      logs.check(:error, "error.steamvr_poll")
    end
  end

  it "例外が出なければ何も残さない" do
    usecase = Error::Usecase.new

    Log.capture("error") do |logs|
      usecase.guard("error.steamvr_poll") { }

      logs.empty
    end
  end
end

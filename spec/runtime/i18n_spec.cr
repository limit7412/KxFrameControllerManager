require "../spec_helper"
require "../../src/runtime/i18n"

# 辞書は ja を正とする。
# キーやプレースホルダの食い違いはコンパイルでは見つからないため、ここで機械的に守る。
describe Runtime::I18n do
  after_each { Runtime::I18n.locale = Runtime::I18n::DEFAULT_LOCALE }

  it "全ロケールでキーの集合が一致する" do
    ja_keys = Runtime::I18n::LOCALES["ja"].keys.sort!
    Runtime::I18n::LOCALES.each do |locale, table|
      table.keys.sort!.should eq(ja_keys), "ロケール #{locale} のキーが ja と食い違っている"
    end
  end

  # プレースホルダが翻訳で欠けると、値が埋まらないまま表示される。
  it "全ロケールでプレースホルダが一致する" do
    ja = Runtime::I18n::LOCALES["ja"]
    mismatched = [] of String
    Runtime::I18n::LOCALES.each do |locale, table|
      next if locale == "ja"
      table.each do |key, text|
        placeholders = text.scan(Runtime::I18n::PLACEHOLDER).map(&.[0]).sort!
        expected = ja[key].scan(Runtime::I18n::PLACEHOLDER).map(&.[0]).sort!
        mismatched << "#{locale}: #{key}" unless placeholders == expected
      end
    end
    mismatched.should be_empty
  end

  it "ロケールに応じた文字列を返す" do
    Runtime::I18n.t("cli.unknown_command").should start_with "不明なコマンド"

    Runtime::I18n.locale = "en"
    Runtime::I18n.t("cli.unknown_command").should start_with "Unknown command"
  end

  # ログは開発者が読むものなので、選択言語に依らず既定の言語で引く。
  it "ログ用の文字列は選択言語に依らない" do
    Runtime::I18n.locale = "en"
    Runtime::I18n.log_text("error.steamvr_poll").should eq Runtime::I18n::LOCALES["ja"]["error.steamvr_poll"]
  end

  it "どのロケールにも無いキーはキー名のまま返す" do
    Runtime::I18n.t("no.such.key").should eq "no.such.key"
  end

  it "プレースホルダを値で置き換え、値の無いものは残す" do
    text = Runtime::I18n.t("cli.unknown_command", {"command" => "{x}"})
    text.should contain "{x}"
    text.should_not contain "{command}"

    kept = Runtime::I18n.t("cli.unknown_command", {} of String => String)
    kept.should contain "{command}"
  end

  it "知らないロケールを設定しようとしたら既定へ倒す" do
    Runtime::I18n.locale = "fr"
    Runtime::I18n.locale.should eq Runtime::I18n::DEFAULT_LOCALE
  end

  describe ".resolve" do
    it "明示された ja と en はそのまま使う" do
      Runtime::I18n.resolve("ja", {"LANG" => "en_US.UTF-8"}).should eq "ja"
      Runtime::I18n.resolve("en", {"LANG" => "ja_JP.UTF-8"}).should eq "en"
    end

    it "auto と想定外の値は環境変数のロケールに従う" do
      Runtime::I18n.resolve("auto", {"LANG" => "ja_JP.UTF-8"}).should eq "ja"
      Runtime::I18n.resolve("fr", {"LANG" => "en_US.UTF-8"}).should eq "en"
    end
  end

  describe ".system_locale" do
    it "LC_ALL、LC_MESSAGES、LANG の順に見る" do
      env = {"LC_ALL" => "ja_JP.UTF-8", "LC_MESSAGES" => "en_US.UTF-8", "LANG" => "en_US.UTF-8"}
      Runtime::I18n.system_locale(env).should eq "ja"

      env = {"LC_ALL" => "", "LC_MESSAGES" => "en_US.UTF-8", "LANG" => "ja_JP.UTF-8"}
      Runtime::I18n.system_locale(env).should eq "en"
    end

    it "どれも無ければ en にする" do
      Runtime::I18n.system_locale({} of String => String).should eq "en"
      Runtime::I18n.system_locale({"LANG" => "C"}).should eq "en"
    end
  end
end

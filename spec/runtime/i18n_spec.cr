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
    Runtime::I18n.locale = "xx"
    Runtime::I18n.locale.should eq Runtime::I18n::DEFAULT_LOCALE
  end

  # 言語を足すときは locales/ にファイルを置き、CODES に足す。どちらかを忘れたら落とす。
  it "locales/ のファイルと CODES が揃っている" do
    files = Dir.glob(File.join(__DIR__, "..", "..", "locales", "*.json")).map { |path| File.basename(path, ".json") }
    files.sort.should eq Runtime::I18n::CODES.sort
    Runtime::I18n::LOCALES.keys.should eq Runtime::I18n::CODES
  end

  # 機械翻訳の言語は、画面にそう出す。ja と en は人が書いたものとして扱う。
  it "ja と en 以外は機械翻訳と明記している" do
    Runtime::I18n::CODES.each do |code|
      expected = %w[ja en].includes?(code) ? "false" : "true"
      Runtime::I18n::LOCALES[code]["meta.machine_translated"].should eq(expected), "ロケール #{code} の meta.machine_translated"
    end
  end

  it "どの言語も SteamVR の札と書体を持つ" do
    Runtime::I18n::CODES.each do |code|
      Runtime::I18n.steamvr_tag(code).should match(/\A[a-z]{2}_[A-Z]{2}\z/)
      Runtime::I18n::LOCALES[code]["meta.font_family"].should start_with "Noto Sans CJK"
    end
  end

  it "t_in は今の言語を変えずに指定した言語で引き、知らない言語は en で引く" do
    Runtime::I18n.t_in("de", "cli.unknown_command").should start_with "Unbekannter Befehl"
    Runtime::I18n.t_in("xx", "cli.unknown_command").should start_with "Unknown command"
  end

  it ".validate は auto と辞書のある言語だけを受け付ける" do
    Runtime::I18n.validate("auto").should be_empty
    Runtime::I18n.validate("zh-Hant").should be_empty
    Runtime::I18n.validate("xx").first[0].should eq "config.error.choice"
  end

  describe ".resolve" do
    it "明示された言語はそのまま使う" do
      Runtime::I18n.resolve("ja", {"LANG" => "en_US.UTF-8"}, "english").should eq "ja"
      Runtime::I18n.resolve("en", {"LANG" => "ja_JP.UTF-8"}, "japanese").should eq "en"
      Runtime::I18n.resolve("ko", {"LANG" => "en_US.UTF-8"}).should eq "ko"
    end

    # SteamOS ではシステムのロケールが英語のまま、Steam だけを日本語にしていることが多い。
    it "auto は Steam の表示言語を環境変数より先に見る" do
      Runtime::I18n.resolve("auto", {"LANG" => "en_US.UTF-8"}, "japanese").should eq "ja"
      Runtime::I18n.resolve("auto", {"LANG" => "ja_JP.UTF-8"}, "schinese").should eq "zh-Hans"
    end

    it "Steam の表示言語が無いか扱えなければ環境変数に従う" do
      Runtime::I18n.resolve("auto", {"LANG" => "ja_JP.UTF-8"}).should eq "ja"
      Runtime::I18n.resolve("auto", {"LANG" => "de_DE.UTF-8"}, "polish").should eq "de"
      Runtime::I18n.resolve("xx", {"LANG" => "fr_FR.UTF-8"}).should eq "fr"
    end

    it "どれも決め手にならなければ en にする" do
      Runtime::I18n.resolve("auto", {} of String => String).should eq "en"
      Runtime::I18n.resolve("auto", {"LANG" => "C"}, "polish").should eq "en"
    end
  end

  describe ".from_steam" do
    it "Steam の言語名をロケールにする" do
      {
        "english" => "en", "japanese" => "ja", "schinese" => "zh-Hans", "tchinese" => "zh-Hant",
        "koreana" => "ko", "german" => "de", "french" => "fr", "spanish" => "es", "latam" => "es",
        "russian" => "ru", "Japanese" => "ja",
      }.each do |name, code|
        Runtime::I18n.from_steam(name).should eq(code), name
      end
      Runtime::I18n.from_steam("polish").should be_nil
      Runtime::I18n.from_steam(nil).should be_nil
    end
  end

  describe ".from_environment" do
    it "LC_ALL、LC_MESSAGES、LANG の順に見る" do
      env = {"LC_ALL" => "ja_JP.UTF-8", "LC_MESSAGES" => "en_US.UTF-8", "LANG" => "en_US.UTF-8"}
      Runtime::I18n.from_environment(env).should eq "ja"

      env = {"LC_ALL" => "", "LC_MESSAGES" => "en_US.UTF-8", "LANG" => "ja_JP.UTF-8"}
      Runtime::I18n.from_environment(env).should eq "en"
    end

    it "中国語は地域で簡体字と繁体字を分ける" do
      Runtime::I18n.from_posix("zh_CN.UTF-8").should eq "zh-Hans"
      Runtime::I18n.from_posix("zh_TW.UTF-8").should eq "zh-Hant"
      Runtime::I18n.from_posix("zh_HK.UTF-8").should eq "zh-Hant"
      Runtime::I18n.from_posix("zh").should eq "zh-Hans"
      Runtime::I18n.from_posix("ko_KR.UTF-8").should eq "ko"
      Runtime::I18n.from_posix("ru_RU.UTF-8@euro").should eq "ru"
    end

    it "どれも無いか扱えなければ nil にする" do
      Runtime::I18n.from_environment({} of String => String).should be_nil
      Runtime::I18n.from_environment({"LANG" => "C"}).should be_nil
      Runtime::I18n.from_environment({"LANG" => "pl_PL.UTF-8"}).should be_nil
    end
  end
end

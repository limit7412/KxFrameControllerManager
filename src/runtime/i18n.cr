require "json"

module Runtime
  # 表示する文字列の辞書。
  #
  # 対象は CLI の表示と、例外をログへ落とすときの文脈である。
  # ログは選択言語に依らず既定の言語で引く（log_text）。開発者が読み比べるためである。
  #
  # 日本語の CLI の文字列は敬体で書く。
  # このリポジトリの文書はである体で書くが、ここの文字列は利用者へ宛てるものであり、
  # 同じ文体を持ち込むと指示が事実の記述に読める。
  #
  # 翻訳はコンパイル時に埋め込む。配布物の実行ファイルは単体でも動くようにしてあり、
  # 翻訳ファイルを隣へ置く方式はそれと衝突するためである。
  module I18n
    LOCALES = {
      "ja" => Hash(String, String).from_json({{ read_file("#{__DIR__}/../../locales/ja.json") }}),
      "en" => Hash(String, String).from_json({{ read_file("#{__DIR__}/../../locales/en.json") }}),
    }

    # ja を正とする。en に無いキーは ja の文字列で表示される。
    DEFAULT_LOCALE = "ja"

    PLACEHOLDER = /\{(\w+)\}/

    # ロケールを表す環境変数。先にあるものほど優先する（POSIX の決まりと同じ順）。
    LOCALE_VARIABLES = %w[LC_ALL LC_MESSAGES LANG]

    @@locale : String = DEFAULT_LOCALE

    def self.locale : String
      @@locale
    end

    def self.locale=(locale : String) : String
      @@locale = LOCALES.has_key?(locale) ? locale : DEFAULT_LOCALE
    end

    # 設定の language の値から使うロケールを決める。
    # "auto" と想定外の値は環境変数に従う。想定外の値は検証が弾くため、
    # ここへ来るのは検証を通らない経路（読めなかった設定の既定値など）に限られる。
    def self.resolve(setting : String, env = ENV) : String
      LOCALES.has_key?(setting) ? setting : system_locale(env)
    end

    # 環境変数のロケールが日本語なら ja、それ以外は en とする。
    # どれも設定されていない、または C や POSIX のときは en になる。
    def self.system_locale(env = ENV) : String
      LOCALE_VARIABLES.each do |variable|
        value = env[variable]?
        next if value.nil? || value.empty?
        return value.starts_with?("ja") ? "ja" : "en"
      end
      "en"
    end

    def self.t(key : String) : String
      LOCALES[@@locale][key]? || LOCALES[DEFAULT_LOCALE][key]? || key
    end

    # ログへ出すための文字列。選択言語に依らず既定の言語で引く。
    def self.log_text(key : String) : String
      LOCALES[DEFAULT_LOCALE][key]? || key
    end

    # プレースホルダ（{version} など）を値で置き換える。
    # 1 回の走査で置き換えるのは、値に含まれる { } を再解釈しないためである。
    def self.t(key : String, vars : Hash(String, String)) : String
      t(key).gsub(PLACEHOLDER) do |match, m|
        vars[m[1]]? || match
      end
    end
  end
end

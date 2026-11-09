require "json"

module Runtime
  # 表示する文字列の辞書。
  #
  # 対象は CLI の表示、設定画面（ダッシュボードのタブ）、SteamVR のバインド画面に出る名前と、
  # 例外をログへ落とすときの文脈である。
  # ログは選択言語に依らず日本語で引く（log_text）。開発者が読み比べるためである。
  #
  # 日本語の文字列は敬体で書く。
  # このリポジトリの文書はである体で書くが、ここの文字列は利用者へ宛てるものであり、
  # 同じ文体を持ち込むと指示が事実の記述に読める。
  #
  # 翻訳はコンパイル時に埋め込む。配布物の実行ファイルは単体でも動くようにしてあり、
  # 翻訳ファイルを隣へ置く方式はそれと衝突するためである。
  #
  # 言語を足すときは、locales/ に <コード>.json を置き、CODES に足す。
  # 言語ごとの情報（自動の判定に使う名前や、画面の書体）は、ファイルの meta.* に書く。
  module I18n
    # 並びは設定画面で言語を切り替える順でもある。
    CODES = %w[ja en zh-Hans zh-Hant ko de fr es ru]

    LOCALES = {% begin %}
      {
        {% for code in CODES %}
          {{ code }} => Hash(String, String).from_json({{ read_file("#{__DIR__}/../../locales/#{code.id}.json") }}),
        {% end %}
      }
    {% end %}

    # ja を正とする。キーの集合は spec が全言語で揃っていることを確かめる。
    DEFAULT_LOCALE = "ja"

    # 揃っていないキーを引いたときに代わりに使う言語。
    # ja ではなく en に倒すのは、日本語を読めない利用者のほうが多いと見込むためである。
    FALLBACK_LOCALE = "en"

    # 設定 language の値のうち、言語を自動で決めるもの。
    AUTO = "auto"

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

    # 設定 language に書ける値。
    def self.settings : Array(String)
      [AUTO] + CODES
    end

    # 設定 language の検証。誤りの鍵と埋める値を返す。
    def self.validate(setting : String) : Array({String, Hash(String, String)})
      return [] of {String, Hash(String, String)} if settings.includes?(setting)
      [{"config.error.choice", {"key" => "language", "choices" => settings.join(" / ")}}]
    end

    # 設定 language の値から使うロケールを決める。
    #
    # "auto" と想定外の値は、Steam の表示言語、環境変数の順に見る。どちらも決め手にならなければ en にする。
    # Steam の表示言語を先に見るのは、SteamVR とダッシュボードがそれに従うためである。
    # SteamOS ではシステムのロケールが英語のまま、Steam だけを日本語にしていることが多い。
    # 想定外の値は検証が弾くため、ここへ来るのは検証を通らない経路（読めなかった設定の既定値など）に限られる。
    def self.resolve(setting : String, env = ENV, steam_language : String? = nil) : String
      return setting if LOCALES.has_key?(setting)
      from_steam(steam_language) || from_environment(env) || FALLBACK_LOCALE
    end

    # Steam の言語名（japanese、schinese など）に当たるロケール。知らない名前なら nil。
    def self.from_steam(name : String?) : String?
      return nil unless name
      name = name.downcase
      CODES.find { |code| meta_list(code, "meta.steam_languages").includes?(name) }
    end

    # 環境変数のロケール（ja_JP.UTF-8 など）に当たるロケール。
    #
    # 最初に値のある変数だけを見る。その値を扱えなければ nil を返し、後ろの変数は見ない。
    # POSIX でも後ろの変数は前の変数に上書きされており、利用者の意図ではないためである。
    def self.from_environment(env = ENV) : String?
      LOCALE_VARIABLES.each do |variable|
        value = env[variable]?
        next if value.nil? || value.empty?
        return from_posix(value)
      end
      nil
    end

    # POSIX のロケール名に当たるロケール。
    # 地域まで書いた候補（zh_TW）を、言語だけの候補（zh）より先に見る。
    def self.from_posix(value : String) : String?
      name = value.split('.').first.split('@').first
      language = name.split('_').first
      CODES.find { |code| meta_list(code, "meta.posix").includes?(name) } ||
        CODES.find { |code| meta_list(code, "meta.posix").includes?(language) }
    end

    # その言語の文字列が機械で翻訳したものか。
    def self.machine_translated?(code : String = @@locale) : Bool
      LOCALES[code]?.try(&.["meta.machine_translated"]?) == "true"
    end

    # その言語の、その言語での名前（日本語、English など）。
    def self.native_name(code : String) : String
      LOCALES[code]?.try(&.["meta.name"]?) || code
    end

    # SteamVR の文字列の表で使う言語の札（ja_JP など）。
    def self.steamvr_tag(code : String) : String
      LOCALES[code]["meta.steamvr_tag"]
    end

    # 指定した言語で引く。今の言語は変えない。SteamVR へ全言語ぶんの文字列を渡すときに使う。
    def self.t_in(code : String, key : String) : String
      LOCALES[code]?.try(&.[key]?) || LOCALES[FALLBACK_LOCALE][key]? || LOCALES[DEFAULT_LOCALE][key]? || key
    end

    def self.t(key : String) : String
      t_in(@@locale, key)
    end

    # ログへ出すための文字列。選択言語に依らず既定の言語で引く。
    def self.log_text(key : String) : String
      LOCALES[DEFAULT_LOCALE][key]? || key
    end

    def self.log_text(key : String, vars : Hash(String, String)) : String
      fill(log_text(key), vars)
    end

    def self.t(key : String, vars : Hash(String, String)) : String
      fill(t(key), vars)
    end

    # プレースホルダ（{version} など）を値で置き換える。
    # 1 回の走査で置き換えるのは、値に含まれる { } を再解釈しないためである。
    def self.fill(text : String, vars : Hash(String, String)) : String
      text.gsub(PLACEHOLDER) do |match, m|
        vars[m[1]]? || match
      end
    end

    # meta.* のうち、カンマで区切った並びを書くもの。
    private def self.meta_list(code : String, key : String) : Array(String)
      (LOCALES[code][key]? || "").split(',').map(&.strip).reject(&.empty?)
    end
  end
end

require "log"
require "json"
require "./models"
require "./repository"

module Config
  # 検証エラー 1 件。
  # section は設定ファイルのどのセクションの誤りかを表す。ログと CLI の表示で見出しに使う。
  struct ValidationError
    getter section : String
    getter message : String

    def initialize(@section : String, @message : String)
    end

    def to_s(io : IO) : Nil
      io << section << ": " << message
    end
  end

  # 設定の検証、保存、再読み込み、各 usecase への反映を担う。
  #
  # 設定は不変のスナップショット（Root）として持ち、反映はスナップショットの差し替えで行う。
  # 検証を通らない設定は反映せず、直前の設定で動作を続ける。
  class Usecase
    Log = ::Log.for("config")

    LOG_LEVELS      = %w[trace debug info notice warn error fatal none]
    LANGUAGES       = %w[auto ja en]
    UPDATE_CHANNELS = %w[stable test]

    # 範囲の決まった数値の項目（仕様書 6.1 節）。
    # ここに無い範囲は仕様書が決めていないものであり、
    # 明らかに動作が成り立たない値だけを弾くよう広めに取ってある。
    HOLD_MS_RANGE            = 500..10_000
    COOLDOWN_MS_RANGE        = 0..60_000
    CONFIRM_TIMEOUT_MS_RANGE = 100..30_000
    DELAY_S_RANGE            = 0..600
    POLL_INTERVAL_MS_RANGE   = 1..100
    RETRY_INTERVAL_S_RANGE   = 1..600
    PORT_RANGE               = 1..65_535

    # 予告の振動から切断までに空ける最小の時間（仕様書 7.1 節）。
    # 予告を感じてから離すまでの猶予であり、これより短いと中止が間に合わない。
    MIN_WARN_TO_HOLD_MS = 500

    # 検証を通った設定を各 usecase へ流すためのフック。
    # composition root がスナップショットの差し替えを登録する。
    property on_apply : Proc(Root, Nil) = ->(_root : Root) { }

    getter current : Root
    getter repository : Repository

    def initialize(@repository : Repository, @current : Root = Root.default)
      @section_validators = {} of String => Proc(Root, Array(String))
    end

    # セクションごとの追加の検証をコンテキストから登録する。
    #
    # 共通の範囲は validate が見る。ここで足すのは、そのコンテキストにしか分からない条件である。
    # 登録は composition root が行い、config は登録元のコンテキストを知らない。
    def register_validator(section : String, &block : Root -> Array(String)) : Nil
      @section_validators[section] = block
    end

    # 起動時の読み込み。
    # 設定ファイルが無ければ初期設定を書き出し、壊れていれば初期設定で起動する。
    #
    # 壊れたファイルは書き戻さない。利用者が直せるよう、そのまま残しておく。
    def load : Array(ValidationError)
      unless @repository.exists?
        @current = Root.default
        @repository.save(@current)
        Log.info { "初期設定を書き出した: #{@repository.path}" }
        @on_apply.call(@current)
        return [] of ValidationError
      end

      read_and_apply("初期設定で起動する")
    end

    # 手動編集後の取り込み（SIGHUP）。
    # 不正な内容を読んだ場合は直前の有効な設定で動作を続ける（仕様書 6.1 節）。
    def reload : Array(ValidationError)
      errors = read_and_apply("直前の設定を維持する")
      Log.info { "設定を再読み込みした" } if errors.empty?
      errors
    end

    # 保存は全項目が有効なときだけ行う。
    # 保存が通ったときだけスナップショットを差し替えるため、検証エラーは現在の動作に影響しない。
    def save(root : Root) : Array(ValidationError)
      errors = validate(root)
      return errors unless errors.empty?

      @repository.save(root)
      @current = root
      @on_apply.call(@current)
      Log.info { "設定を保存した" }
      errors
    end

    private def read_and_apply(fallback : String) : Array(ValidationError)
      root = @repository.load
      errors = validate(root)
      if errors.empty?
        @current = root
        @on_apply.call(@current)
      else
        Log.error { "設定の検証に失敗したため#{fallback}: #{errors.join(" / ")}" }
      end
      errors
    rescue ex : JSON::Error | File::Error
      Log.error(exception: ex) { "設定ファイルを読めなかったため#{fallback}" }
      [ValidationError.new("全般", "設定ファイルを読めなかった: #{ex.message}")]
    end

    def validate(root : Root) : Array(ValidationError)
      errors = [] of ValidationError
      validate_power_off(root.power_off, errors)
      validate_power_save(root.power_save, errors)
      validate_input(root.input, errors)
      validate_feedback(root.feedback, errors)
      validate_steamvr(root.steamvr, errors)
      validate_frame_link(root.frame_link, errors)
      validate_general(root, errors)

      @section_validators.each do |section, validator|
        validator.call(root).each { |message| errors << ValidationError.new(section, message) }
      end
      errors
    end

    private def validate_power_off(section : PowerOffSection, errors : Array(ValidationError)) : Nil
      label = "power_off"
      unless HOLD_MS_RANGE.includes?(section.hold_ms)
        errors << range_error(label, "hold_ms", HOLD_MS_RANGE)
      end
      if section.warn_ms < 0
        errors << ValidationError.new(label, "warn_ms は 0 以上で指定する")
      end
      if section.warn_ms >= section.hold_ms
        errors << ValidationError.new(label, "warn_ms は hold_ms 未満で指定する")
      elsif section.hold_ms - section.warn_ms < MIN_WARN_TO_HOLD_MS
        errors << ValidationError.new(label, "hold_ms と warn_ms の差は #{MIN_WARN_TO_HOLD_MS} 以上で指定する")
      end
      unless COOLDOWN_MS_RANGE.includes?(section.cooldown_ms)
        errors << range_error(label, "cooldown_ms", COOLDOWN_MS_RANGE)
      end
      unless CONFIRM_TIMEOUT_MS_RANGE.includes?(section.confirm_timeout_ms)
        errors << range_error(label, "confirm_timeout_ms", CONFIRM_TIMEOUT_MS_RANGE)
      end
    end

    private def validate_power_save(section : PowerSaveSection, errors : Array(ValidationError)) : Nil
      label = "power_save"
      unless DELAY_S_RANGE.includes?(section.delay_s)
        errors << range_error(label, "delay_s", DELAY_S_RANGE)
      end
      # 数値なら HMD の範囲へ収めて使う。ここでは収める前の値として成り立つかだけを見る。
      if (gain = section.brightness_gain) && !positive_finite?(gain)
        errors << ValidationError.new(label, "brightness_gain は null か 0 より大きい有限の値で指定する")
      end
    end

    private def validate_input(section : InputSection, errors : Array(ValidationError)) : Nil
      unless POLL_INTERVAL_MS_RANGE.includes?(section.poll_interval_ms)
        errors << range_error("input", "poll_interval_ms", POLL_INTERVAL_MS_RANGE)
      end
    end

    private def validate_feedback(section : FeedbackSection, errors : Array(ValidationError)) : Nil
      amplitude = section.amplitude
      unless amplitude.finite? && 0.0 <= amplitude && amplitude <= 1.0
        errors << ValidationError.new("feedback", "amplitude は 0.0 から 1.0 の範囲で指定する")
      end
    end

    private def validate_steamvr(section : SteamVRSection, errors : Array(ValidationError)) : Nil
      unless RETRY_INTERVAL_S_RANGE.includes?(section.retry_interval_s)
        errors << range_error("steamvr", "retry_interval_s", RETRY_INTERVAL_S_RANGE)
      end
    end

    private def validate_frame_link(section : FrameLinkSection, errors : Array(ValidationError)) : Nil
      unless PORT_RANGE.includes?(section.port)
        errors << range_error("frame_link", "port", PORT_RANGE)
      end
    end

    private def validate_general(root : Root, errors : Array(ValidationError)) : Nil
      unless LOG_LEVELS.includes?(root.log_level)
        errors << ValidationError.new("全般", "log_level は #{LOG_LEVELS.join(" / ")} のいずれかで指定する")
      end
      unless LANGUAGES.includes?(root.language)
        errors << ValidationError.new("全般", "language は #{LANGUAGES.join(" / ")} のいずれかで指定する")
      end
      unless UPDATE_CHANNELS.includes?(root.update.channel)
        errors << ValidationError.new("update", "channel は #{UPDATE_CHANNELS.join(" / ")} のいずれかで指定する")
      end
    end

    private def range_error(section : String, key : String, range : Range(Int32, Int32)) : ValidationError
      ValidationError.new(section, "#{key} は #{range.begin} から #{range.end} の範囲で指定する")
    end

    # 大小の比較だけでは NaN を弾けない。
    # NaN はどの比較でも偽になるため、範囲を外れているとみなされずに検証を通ってしまう。
    private def positive_finite?(value : Float64) : Bool
      value.finite? && value > 0.0
    end
  end
end

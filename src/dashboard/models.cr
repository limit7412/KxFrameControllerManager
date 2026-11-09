require "../config/models"
require "../power_off/models"

module Dashboard
  # 片手ぶんの状態。
  record HandStatus, connected : Bool, serial : String?, button : String

  # 更新の状態。自動更新が状態のファイルへ残したものの写しである。
  record UpdateStatus,
    # 走っている実行ファイルの版。
    version : String,
    # 最後に GitHub Releases を確かめた時刻。
    last_checked_at : Time?,
    # 最後に走った更新の結末（RunOutcome の名前を小文字とアンダースコアにしたもの）と、その版と時刻。
    last_outcome : String?,
    last_tag : String?,
    last_finished_at : Time?,
    # 走っている更新の段階（Phase の名前を小文字とアンダースコアにしたもの）。走っていなければ nil。
    phase : String?,
    # 常駐が systemd のユニットとして入っているか。入っていなければ、画面からの更新は再起動ができない。
    service_installed : Bool,
    # 置き換える実行ファイルのパス。戻せなかったときの文言に使う。
    executable : String

  # 画面へ見せる常駐の状態。組み立てたときの値の写しである。
  # 前回と比べて変わったときだけ描き直すため、値として比べられる record にしてある。
  record Snapshot,
    steamvr_connected : Bool,
    left : HandStatus,
    right : HandStatus,
    # 最後に 27062 の疎通を確かめた結果。まだ確かめていなければ nil。
    link_reachable : Bool?,
    # 省電力の状態（idle / waiting / checking / active）。
    power_save_state : String,
    # 省電力で変えた値が戻されずに残っているか。
    power_save_pending : Bool,
    # HMD の明るさの範囲。読めなければ nil。
    gain_range : {Float64, Float64}?,
    # 最後に読んだ設定ファイルの誤り。
    config_errors : Array(String),
    update : UpdateStatus do
    def hand(hand : PowerOff::Hand) : HandStatus
      hand.left? ? left : right
    end
  end

  # 画面に並べる設定の項目の種類。
  enum FieldKind
    # 有効と無効を切り替える。
    Toggle
    # 決まった値を順に切り替える。
    Choice
    # 数値を一定の幅で増減する。
    Stepper
  end

  # 設定の項目 1 つ。key は設定ファイルの "セクション.キー" である。
  record Field, key : String, kind : FieldKind, step : Float64 = 0.0, min : Float64 = 0.0, max : Float64 = 0.0

  # 画面から変える設定の項目と、その操作の規則。
  #
  # 値の範囲は config の検証（仕様書 6.1 節）に合わせ、画面からは範囲外の値を作れないようにする。
  # 範囲外を作ってから保存で弾くと、押したのに何も変わらないように見える。
  # 画面から変えないもの（dashboard、steamvr、frame_link、update.channel など）はここに載せない。
  module Editor
    FIELDS = {
      "power_off.enabled"              => Field.new("power_off.enabled", FieldKind::Toggle),
      "input.left_button"              => Field.new("input.left_button", FieldKind::Choice),
      "input.right_button"             => Field.new("input.right_button", FieldKind::Choice),
      "power_off.hold_ms"              => Field.new("power_off.hold_ms", FieldKind::Stepper, 100.0, 500.0, 10_000.0),
      "power_off.warn_ms"              => Field.new("power_off.warn_ms", FieldKind::Stepper, 100.0, 0.0, 9_500.0),
      "power_off.cooldown_ms"          => Field.new("power_off.cooldown_ms", FieldKind::Stepper, 500.0, 0.0, 60_000.0),
      "power_off.target"               => Field.new("power_off.target", FieldKind::Choice),
      "input.priority"                 => Field.new("input.priority", FieldKind::Choice),
      "feedback.haptics"               => Field.new("feedback.haptics", FieldKind::Toggle),
      "feedback.amplitude"             => Field.new("feedback.amplitude", FieldKind::Stepper, 0.05, 0.0, 1.0),
      "power_save.enabled"             => Field.new("power_save.enabled", FieldKind::Toggle),
      "power_save.delay_s"             => Field.new("power_save.delay_s", FieldKind::Stepper, 5.0, 0.0, 600.0),
      "power_save.brightness"          => Field.new("power_save.brightness", FieldKind::Toggle),
      "power_save.brightness_gain"     => Field.new("power_save.brightness_gain", FieldKind::Stepper, 0.05, 0.05, 3.0),
      "power_save.performance_profile" => Field.new("power_save.performance_profile", FieldKind::Toggle),
      "update.auto_update"             => Field.new("update.auto_update", FieldKind::Toggle),
      "update.check_interval_h"        => Field.new("update.check_interval_h", FieldKind::Stepper, 1.0, 1.0, 168.0),
    }

    # 自動更新の間隔（時間）の段。1 時間ずつでは 168 時間まで遠いため、決まった段を順に動く。
    # 設定ファイルで段の間の値にしてあれば、押した向きにある最も近い段へ移る。
    CHECK_INTERVALS_H = [1, 2, 3, 6, 12, 24, 48, 72, 168]

    # 予告の振動から切断までに空ける最小の時間。config の検証と同じ値である（仕様書 7.1 節）。
    MIN_WARN_TO_HOLD_MS = 500

    # 操作を受けた後の新しい設定を返す。元の設定は書き換えない。
    #
    # direction は +1 か -1 で、Toggle では使わない。
    # buttons は長押しに割り当てられるボタンで、Choice の input.*_button が使う。
    # gain_range は HMD の明るさの範囲で、分からなければ nil を渡す。
    def self.apply(root : Config::Root, key : String, direction : Int32,
                   buttons : Hash(PowerOff::Hand, Array(String)),
                   gain_range : {Float64, Float64}? = nil) : Config::Root
      field = FIELDS[key]? || raise ArgumentError.new("知らない項目: #{key}")
      next_root = root.dup_snapshot
      case key
      when "power_off.enabled"
        next_root.power_off.enabled = !root.power_off.enabled
      when "feedback.haptics"
        next_root.feedback.haptics = !root.feedback.haptics
      when "power_save.enabled"
        next_root.power_save.enabled = !root.power_save.enabled
      when "power_save.brightness"
        next_root.power_save.brightness = !root.power_save.brightness
      when "power_save.performance_profile"
        next_root.power_save.performance_profile = !root.power_save.performance_profile
      when "update.auto_update"
        next_root.update.auto_update = !root.update.auto_update
      when "update.check_interval_h"
        next_root.update.check_interval_h = step_interval(root.update.check_interval_h, direction)
      when "input.left_button"
        next_root.input.left_button = cycle(buttons[PowerOff::Hand::Left], root.input.left_button, direction)
      when "input.right_button"
        next_root.input.right_button = cycle(buttons[PowerOff::Hand::Right], root.input.right_button, direction)
      when "power_off.target"
        next_root.power_off.target = cycle(Config::PowerOffTarget.values, root.power_off.target, direction)
      when "input.priority"
        next_root.input.priority = cycle(Config::InputPriority.values, root.input.priority, direction)
      when "power_off.hold_ms"
        hold = step(root.power_off.hold_ms, field, direction).to_i
        next_root.power_off.hold_ms = hold
        # 切断までを縮めて予告との間が足りなくなったら、予告のほうを早める。
        # 押した側の値だけが変わり、もう一方が勝手に変わらないようにするのは無理なので、
        # 保存で弾かれて何も変わらないよりはこちらを選ぶ。
        next_root.power_off.warn_ms = Math.min(root.power_off.warn_ms, hold - MIN_WARN_TO_HOLD_MS)
      when "power_off.warn_ms"
        limit = root.power_off.hold_ms - MIN_WARN_TO_HOLD_MS
        next_root.power_off.warn_ms = Math.min(step(root.power_off.warn_ms, field, direction).to_i, limit)
      when "power_off.cooldown_ms"
        next_root.power_off.cooldown_ms = step(root.power_off.cooldown_ms, field, direction).to_i
      when "feedback.amplitude"
        next_root.feedback.amplitude = round(step(root.feedback.amplitude, field, direction))
      when "power_save.delay_s"
        next_root.power_save.delay_s = step(root.power_save.delay_s, field, direction).to_i
      when "power_save.brightness_gain"
        next_root.power_save.brightness_gain = step_gain(root.power_save.brightness_gain, field, direction, gain_range)
      end
      next_root
    end

    # 明るさは「HMD の最小値」（nil）と数値を 1 本の並びとして扱う。
    # 最小値から下げても nil のまま、nil から上げると最小値の 1 段上になる。
    private def self.step_gain(current : Float64?, field : Field, direction : Int32, range : {Float64, Float64}?) : Float64?
      min = range.try(&.[0]) || field.min
      max = range.try(&.[1]) || field.max
      if current.nil?
        return nil if direction < 0
        return round(Math.min(min + field.step, max))
      end
      value = round(current + field.step * direction)
      return nil if value <= min
      round(Math.min(value, max))
    end

    private def self.step_interval(current : Int32, direction : Int32) : Int32
      if direction > 0
        CHECK_INTERVALS_H.find { |value| value > current } || CHECK_INTERVALS_H.last
      else
        CHECK_INTERVALS_H.reverse.find { |value| value < current } || CHECK_INTERVALS_H.first
      end
    end

    private def self.step(value : Number, field : Field, direction : Int32) : Float64
      (value.to_f + field.step * direction).clamp(field.min, field.max)
    end

    private def self.cycle(values : Array(T), current : T, direction : Int32) : T forall T
      index = values.index(current) || 0
      values[(index + direction) % values.size]
    end

    # 0.05 刻みの足し引きで出る 0.30000000000000004 のような端数を落とす。
    private def self.round(value : Float64) : Float64
      (value * 100).round / 100
    end
  end
end

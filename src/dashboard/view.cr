require "../config/models"
require "../config/usecase"
require "../power_off/models"
require "./canvas"
require "./models"

module Dashboard
  # 右の列のタブ。
  enum Tab
    # 長押しの切断とボタンの割り当て。
    Hold
    # 振動と省電力。
    Power
    # 自動更新。
    Update
    # 表示言語。
    General
  end

  # 知らせの色分け。
  enum Tone
    Info
    Ok
    Warn
    Error
  end

  # 押せる場所 1 つ。action は usecase が読み分ける綴りである。
  #
  # - "tab:hold" / "tab:power" / "tab:update" / "tab:general"
  # - "disconnect:left" / "disconnect:right" / "disconnect:both"
  # - "update:check"（新しい版があるかだけを見る） / "update:run"（今すぐ更新する）
  # - "set:<セクション.キー>:<+1 か -1>"（Toggle は +1 だけ）
  record Hit, x : Float64, y : Float64, w : Float64, h : Float64, action : String do
    def contains?(px : Float64, py : Float64) : Bool
      px >= x && px < x + w && py >= y && py < y + h
    end
  end

  # 画面の状態のうち、設定と常駐の状態のどちらでもないもの。
  class ViewState
    property tab : Tab = Tab::Hold
    property snapshot : Snapshot? = nil
    # 1 回目を押して確かめ待ちの対象（left / right / both、または今すぐの更新の update）。
    property armed : String? = nil
    # 切断を処理しているか。
    property? running : Bool = false
    property message : String? = nil
    property tone : Tone = Tone::Info
    # ボタンを変えて、まだ SteamVR に読ませていないか。
    property? rebind_pending : Bool = false
    # 新しい版があるかを見ているか。
    property? checking : Bool = false
    # 更新のタブに出す知らせ。切断の知らせとは別に持つ。
    property update_message : String? = nil
    property update_tone : Tone = Tone::Info
    # 画面の「更新を確認」で確かめられた時刻。
    #
    # 自動更新の状態の last_checked_at には書かない。あれは自動更新の間隔を数える起点であり、
    # 画面で確かめたせいで、見つけた版の自動での置き換えが間隔ぶん遅れないようにするためである。
    # 表示ではどちらか新しいほうを「最後の確認」に出す。
    property checked_at : Time? = nil
  end

  # 画面を描き、押せる場所の一覧を返す。
  #
  # 描くだけで状態は持たない。同じ入力からは同じ画面と同じ押せる場所ができる。
  # 文字は translate を通して引き、言語の扱いは呼び出し側に任せる。
  class View
    WIDTH  = 1024
    HEIGHT =  640

    BACKGROUND = Color.hex(0x15171c)
    PANEL      = Color.hex(0x1f232b)
    LINE       = Color.hex(0x333944)
    TEXT       = Color.hex(0xe8eaee)
    MUTED      = Color.hex(0x9aa3b2)
    ACCENT     = Color.hex(0x5aa9ff)
    OK         = Color.hex(0x4cc38a)
    WARN       = Color.hex(0xe5b454)
    NG         = Color.hex(0xef6b6b)
    DANGER     = Color.hex(0xd9534f)
    BUTTON     = Color.hex(0x2a2f39)

    # 右の列の設定の並び。
    HOLD_FIELDS    = %w[power_off.enabled input.left_button input.right_button power_off.hold_ms power_off.warn_ms power_off.cooldown_ms power_off.target input.priority]
    POWER_FIELDS   = %w[feedback.haptics feedback.amplitude power_save.enabled power_save.delay_s power_save.brightness power_save.brightness_gain power_save.performance_profile]
    UPDATE_FIELDS  = %w[update.auto_update update.check_interval_h]
    GENERAL_FIELDS = %w[language]

    LEFT_X       =  24.0
    LEFT_W       = 380.0
    RIGHT_X      = 424.0
    RIGHT_W      = 576.0
    ROW_H        =  54.0
    FIELDS_TOP   = 148.0
    CONTROL_H    =  42.0
    ARROW_W      =  48.0
    VALUE_W      = 168.0
    TOGGLE_W     = 104.0
    TITLE_SIZE   =  26.0
    HEADING_SIZE =  22.0
    BODY_SIZE    =  20.0
    SMALL_SIZE   =  16.0

    # 長い文字列を枠へ収めるとき、ここまでは字を小さくする。それでも収まらなければ末尾を「…」で切る。
    MIN_FIT_RATIO = 0.72

    # language_names は設定 language の値（ja など）と、その言語での名前（日本語 など）の対応である。
    def initialize(@translate : Proc(String, Hash(String, String), String), @version : String,
                   @language_names = {} of String => String)
    end

    def t(key : String, vars = {} of String => String) : String
      @translate.call(key, vars)
    end

    # 設定の検証の誤りを、今の言語の文にする。
    def describe(error : Config::ValidationError) : String
      error.localize(@translate)
    end

    def render(canvas : Canvas, state : ViewState, root : Config::Root) : Array(Hit)
      hits = [] of Hit
      # 書体は言語の辞書が決める。同じ漢字でも、簡体字と繁体字と日本語では字形が違う。
      canvas.font_family = t("meta.font_family")
      canvas.clear(BACKGROUND)
      header(canvas)
      status(canvas, state.snapshot)
      disconnect(canvas, state, hits)
      tabs(canvas, state.tab, hits)
      fields = case state.tab
               in .hold?    then HOLD_FIELDS
               in .power?   then POWER_FIELDS
               in .update?  then UPDATE_FIELDS
               in .general? then GENERAL_FIELDS
               end
      fields.each_with_index do |key, index|
        row(canvas, root, state.snapshot, key, FIELDS_TOP + index * ROW_H, hits)
      end
      update_panel(canvas, state, root, hits) if state.tab.update?
      footer(canvas, state)
      hits
    end

    # ダッシュボードの下の並びに出る小さな絵。電源の印を描く。
    def self.thumbnail(canvas : Canvas) : Nil
      size = canvas.width.to_f
      canvas.clear(Color.hex(0x000000, 0.0))
      canvas.fill_rect(size * 0.06, size * 0.06, size * 0.88, size * 0.88, PANEL, size * 0.2)
      center = size / 2
      radius = size * 0.26
      width = size * 0.08
      # 上を空けた円と、その空きから下りる縦の線。
      canvas.arc(center, center + size * 0.03, radius, -Math::PI / 2 + 0.75, Math::PI * 1.5 - 0.75, ACCENT, width)
      canvas.line(center, center - radius - size * 0.02, center, center + size * 0.03, ACCENT, width)
    end

    private def header(canvas : Canvas) : Nil
      canvas.text(LEFT_X, 40.0, "KxFrameControllerManager", TITLE_SIZE, TEXT, bold: true)
      canvas.text(RIGHT_X + RIGHT_W, 40.0, @version, SMALL_SIZE, MUTED, align: Align::Right)
    end

    private def status(canvas : Canvas, snapshot : Snapshot?) : Nil
      top = 80.0
      canvas.fill_rect(LEFT_X, top, LEFT_W, 268.0, PANEL, 14.0)
      canvas.text(LEFT_X + 20, top + 30, t("dashboard.status"), HEADING_SIZE, TEXT, bold: true)
      return canvas.text(LEFT_X + 20, top + 76, t("dashboard.loading"), BODY_SIZE, MUTED) unless snapshot

      rows = [] of {String, String, Color}
      rows << {t("dashboard.steamvr"), t(snapshot.steamvr_connected ? "dashboard.connected" : "dashboard.not_connected"), snapshot.steamvr_connected ? OK : NG}
      PowerOff::Hand.each do |hand|
        info = snapshot.hand(hand)
        value = t(info.connected ? "dashboard.connected" : "dashboard.not_connected")
        rows << {t("dashboard.hand.#{hand.label}"), value, info.connected ? OK : MUTED}
      end
      link = snapshot.link_reachable
      rows << {t("dashboard.link"), t(link.nil? ? "dashboard.link_unknown" : (link ? "dashboard.link_ok" : "dashboard.link_ng")), link.nil? ? MUTED : (link ? OK : NG)}
      power_save = t("dashboard.power_save.#{snapshot.power_save_state}")
      power_save_color = snapshot.power_save_state == "active" ? WARN : TEXT
      if snapshot.power_save_pending && snapshot.power_save_state != "active"
        power_save = t("dashboard.power_save.pending")
        power_save_color = WARN
      end
      rows << {t("dashboard.power_save"), power_save, power_save_color}

      rows.each_with_index do |(label, value, color), index|
        y = top + 74 + index * 40
        fit_text(canvas, LEFT_X + 20, y, label, BODY_SIZE, MUTED, 142.0)
        fit_text(canvas, LEFT_X + 170, y, value, BODY_SIZE, color, LEFT_W - 190)
      end
    end

    private def disconnect(canvas : Canvas, state : ViewState, hits : Array(Hit)) : Nil
      top = 364.0
      canvas.fill_rect(LEFT_X, top, LEFT_W, 252.0, PANEL, 14.0)
      canvas.text(LEFT_X + 20, top + 30, t("dashboard.disconnect"), HEADING_SIZE, TEXT, bold: true)

      width = (LEFT_W - 40 - 2 * 12) / 3
      %w[left right both].each_with_index do |target, index|
        x = LEFT_X + 20 + index * (width + 12)
        y = top + 58
        armed = state.armed == target
        enabled = !state.running?
        fill = armed ? DANGER : BUTTON
        canvas.fill_rect(x, y, width, 64.0, fill, 10.0)
        canvas.stroke_rect(x, y, width, 64.0, enabled ? DANGER : LINE, 10.0, 2.0)
        label = armed ? t("dashboard.disconnect.confirm") : t("dashboard.disconnect.#{target}")
        fit_text(canvas, x + width / 2, y + 32, label, armed ? SMALL_SIZE : BODY_SIZE, enabled ? TEXT : MUTED, width - 12, bold: armed, align: Align::Center)
        hits << Hit.new(x, y, width, 64.0, "disconnect:#{target}") if enabled
      end

      message = state.message
      text = message || t("dashboard.disconnect.note")
      color = message ? tone_color(state.tone) : MUTED
      wrap(canvas, text, LEFT_W - 40, SMALL_SIZE).first(3).each_with_index do |line, index|
        canvas.text(LEFT_X + 20, top + 152 + index * 26, line, SMALL_SIZE, color)
      end
    end

    private def tabs(canvas : Canvas, current : Tab, hits : Array(Hit)) : Nil
      width = RIGHT_W / Tab.values.size
      Tab.each do |tab|
        x = RIGHT_X + tab.value * width
        selected = tab == current
        canvas.fill_rect(x + 2, 80.0, width - 4, 52.0, selected ? ACCENT : PANEL, 12.0)
        fit_text(canvas, x + width / 2, 106.0, t("dashboard.tab.#{tab.to_s.underscore}"), BODY_SIZE, selected ? BACKGROUND : TEXT, width - 16, bold: selected, align: Align::Center)
        hits << Hit.new(x, 80.0, width, 52.0, "tab:#{tab.to_s.underscore}")
      end
    end

    private def row(canvas : Canvas, root : Config::Root, snapshot : Snapshot?, key : String, top : Float64, hits : Array(Hit)) : Nil
      field = Editor::FIELDS[key]
      center = top + ROW_H / 2
      canvas.line(RIGHT_X, top + ROW_H, RIGHT_X + RIGHT_W, top + ROW_H, LINE, 1.0)
      right = RIGHT_X + RIGHT_W - 4
      control_top = center - CONTROL_H / 2
      # 項目名は操作の部品の左端までに収める。
      controls_left = field.kind.toggle? ? right - TOGGLE_W : right - ARROW_W * 2 - VALUE_W
      fit_text(canvas, RIGHT_X + 8, center, t("dashboard.field.#{key}"), BODY_SIZE, TEXT, controls_left - RIGHT_X - 20)
      case field.kind
      in .toggle?
        on = value_of(root, key) == "true"
        x = right - TOGGLE_W
        canvas.fill_rect(x, control_top, TOGGLE_W, CONTROL_H, on ? OK : BUTTON, CONTROL_H / 2)
        fit_text(canvas, x + TOGGLE_W / 2, center, t(on ? "dashboard.on" : "dashboard.off"), BODY_SIZE, on ? BACKGROUND : MUTED, TOGGLE_W - 12, bold: true, align: Align::Center)
        hits << Hit.new(x, control_top, TOGGLE_W, CONTROL_H, "set:#{key}:+1")
      in .choice?, .stepper?
        plus_x = right - ARROW_W
        value_x = plus_x - VALUE_W
        minus_x = value_x - ARROW_W
        less, more = field.kind.choice? ? {"◀", "▶"} : {"−", "+"}
        arrow(canvas, minus_x, control_top, less)
        arrow(canvas, plus_x, control_top, more)
        fit_text(canvas, value_x + VALUE_W / 2, center, display(root, snapshot, key), BODY_SIZE, TEXT, VALUE_W - 8, align: Align::Center)
        hits << Hit.new(minus_x, control_top, ARROW_W, CONTROL_H, "set:#{key}:-1")
        hits << Hit.new(plus_x, control_top, ARROW_W, CONTROL_H, "set:#{key}:+1")
      end
    end

    private def arrow(canvas : Canvas, x : Float64, y : Float64, label : String) : Nil
      canvas.fill_rect(x, y, ARROW_W, CONTROL_H, BUTTON, 10.0)
      canvas.text(x + ARROW_W / 2, y + CONTROL_H / 2, label, BODY_SIZE, ACCENT, bold: true, align: Align::Center)
    end

    private def footer(canvas : Canvas, state : ViewState) : Nil
      y = FIELDS_TOP + 8 * ROW_H + 22
      errors = state.snapshot.try(&.config_errors) || [] of String
      if !errors.empty?
        canvas.text(RIGHT_X + 8, y, t("dashboard.config_errors"), SMALL_SIZE, NG)
        canvas.text(RIGHT_X + 8, y + 22, wrap(canvas, errors.first, RIGHT_W - 16, SMALL_SIZE).first, SMALL_SIZE, NG)
      elsif state.rebind_pending?
        note(canvas, y, t("dashboard.rebind_pending"), WARN)
      elsif state.tab.general?
        # 自動で決める言語の説明を、項目のすぐ下に置く。8 行ぶん下の footer の位置では項目から離れすぎる。
        top = FIELDS_TOP + GENERAL_FIELDS.size * ROW_H + 26
        lines = wrap(canvas, t("dashboard.language.note"), RIGHT_W - 16, SMALL_SIZE).first(3)
        lines.each_with_index do |line, index|
          canvas.text(RIGHT_X + 8, top + index * 22, line, SMALL_SIZE, MUTED)
        end
        # 機械翻訳の言語では、そうと分かるように段落を分けて添える。
        if t("meta.machine_translated") == "true"
          top += lines.size * 22 + 14
          wrap(canvas, t("dashboard.language.machine_translated"), RIGHT_W - 16, SMALL_SIZE).first(3).each_with_index do |line, index|
            canvas.text(RIGHT_X + 8, top + index * 22, line, SMALL_SIZE, WARN)
          end
        end
      else
        key = case state.tab
              when .hold?   then "dashboard.binding_note"
              when .update? then "dashboard.update.note"
              else               "dashboard.power_save_note"
              end
        note(canvas, y, t(key), MUTED)
      end
    end

    # 下の欄の注意書き。2 行まで折り返す。
    private def note(canvas : Canvas, y : Float64, text : String, color : Color) : Nil
      wrap(canvas, text, RIGHT_W - 16, SMALL_SIZE).first(2).each_with_index do |line, index|
        canvas.text(RIGHT_X + 8, y + index * 22, line, SMALL_SIZE, color)
      end
    end

    # 幅に収まるよう字を小さくして描く。小さくしても収まらなければ、末尾を「…」で切る。
    #
    # 訳した言語では、日本語に合わせて決めた枠を文字列が超えやすい（ドイツ語の項目名など）。
    # 枠をはみ出すと隣の部品に重なり、押せる場所と見た目がずれる。
    private def fit_text(canvas : Canvas, x : Float64, y : Float64, text : String, size : Float64, color : Color,
                         width : Float64, bold : Bool = false, align : Align = Align::Left) : Nil
      fitted = size
      natural = canvas.text_width(text, size, bold)
      fitted = Math.max(size * width / natural, size * MIN_FIT_RATIO) if natural > width
      canvas.text(x, y, truncate(canvas, text, fitted, width, bold), fitted, color, bold: bold, align: align)
    end

    private def truncate(canvas : Canvas, text : String, size : Float64, width : Float64, bold : Bool) : String
      return text if canvas.text_width(text, size, bold) <= width
      chars = text.chars
      while chars.size > 1
        chars.pop
        candidate = chars.join.rstrip + "…"
        return candidate if canvas.text_width(candidate, size, bold) <= width
      end
      text
    end

    # 設定の値を、比べるための文字列にする。
    private def value_of(root : Config::Root, key : String) : String
      case key
      when "power_off.enabled"              then root.power_off.enabled.to_s
      when "feedback.haptics"               then root.feedback.haptics.to_s
      when "power_save.enabled"             then root.power_save.enabled.to_s
      when "power_save.brightness"          then root.power_save.brightness.to_s
      when "power_save.performance_profile" then root.power_save.performance_profile.to_s
      when "update.auto_update"             then root.update.auto_update.to_s
      else                                       ""
      end
    end

    # 設定の値を、画面に出す文字列にする。
    private def display(root : Config::Root, snapshot : Snapshot?, key : String) : String
      case key
      when "input.left_button"       then t("dashboard.button.#{root.input.left_button}")
      when "input.right_button"      then t("dashboard.button.#{root.input.right_button}")
      when "power_off.hold_ms"       then t("dashboard.milliseconds", {"value" => root.power_off.hold_ms.to_s})
      when "power_off.warn_ms"       then t("dashboard.milliseconds", {"value" => root.power_off.warn_ms.to_s})
      when "power_off.cooldown_ms"   then t("dashboard.milliseconds", {"value" => root.power_off.cooldown_ms.to_s})
      when "power_off.target"        then t("dashboard.target.#{root.power_off.target.to_s.underscore}")
      when "input.priority"          then t("dashboard.priority.#{root.input.priority.to_s.underscore}")
      when "feedback.amplitude"      then "%.2f" % root.feedback.amplitude
      when "power_save.delay_s"      then t("dashboard.seconds", {"value" => root.power_save.delay_s.to_s})
      when "update.check_interval_h" then t("dashboard.hours", {"value" => root.update.check_interval_h.to_s})
      when "language"
        # 自動のときは、今そう決まった言語の名前を添える。今の言語の辞書は、その言語自身の名前を持つ。
        root.language == "auto" ? t("dashboard.language.auto", {"name" => t("meta.name")}) : @language_names[root.language]? || root.language
      when "power_save.brightness_gain"
        gain = root.power_save.brightness_gain
        gain ? "%.2f" % gain : t("dashboard.gain_auto")
      else
        ""
      end
    end

    # 更新のタブの下半分。版と最後の確認、今の段階か最後の結末、2 つのボタン、知らせを並べる。
    private def update_panel(canvas : Canvas, state : ViewState, root : Config::Root, hits : Array(Hit)) : Nil
      top = FIELDS_TOP + UPDATE_FIELDS.size * ROW_H + 12
      canvas.fill_rect(RIGHT_X, top, RIGHT_W, 300.0, PANEL, 14.0)
      update = state.snapshot.try(&.update)
      return canvas.text(RIGHT_X + 20, top + 32, t("dashboard.loading"), BODY_SIZE, MUTED) unless update

      last_checked = [update.last_checked_at, state.checked_at].compact.max?
      checked = last_checked.try { |time| format_time(time) } || t("dashboard.update.never")
      info = [
        {t("dashboard.update.version"), update.version, TEXT},
        {t("dashboard.update.last_checked"), checked, TEXT},
      ]
      phase = update.phase
      if phase
        info << {t("dashboard.update.state"), t("dashboard.update.phase.#{phase}"), ACCENT}
      elsif outcome = update.last_outcome
        vars = {"version" => update.version, "tag" => update.last_tag || "", "path" => update.executable}
        info << {t("dashboard.update.state"), t("update.#{outcome}", vars), outcome_color(outcome)}
      end

      y = top + 30
      info.each do |(label, value, color)|
        fit_text(canvas, RIGHT_X + 20, y, label, BODY_SIZE, MUTED, 152.0)
        lines = wrap(canvas, value, RIGHT_W - 200, SMALL_SIZE).first(2)
        if lines.size == 1 && canvas.text_width(value, BODY_SIZE) <= RIGHT_W - 200
          canvas.text(RIGHT_X + 180, y, value, BODY_SIZE, color)
          y += 40
        else
          lines.each_with_index { |line, index| canvas.text(RIGHT_X + 180, y + index * 22, line, SMALL_SIZE, color) }
          y += 22 * lines.size + 18
        end
      end

      busy = !phase.nil? || state.checking?
      buttons_top = top + 176
      width = (RIGHT_W - 40 - 12) / 2
      check_x = RIGHT_X + 20
      run_x = check_x + width + 12
      can_run = !busy && update.service_installed
      canvas.fill_rect(check_x, buttons_top, width, 56.0, BUTTON, 10.0)
      canvas.stroke_rect(check_x, buttons_top, width, 56.0, busy ? LINE : ACCENT, 10.0, 2.0)
      fit_text(canvas, check_x + width / 2, buttons_top + 28, t(state.checking? ? "dashboard.update.checking" : "dashboard.update.check"), BODY_SIZE, busy ? MUTED : TEXT, width - 16, align: Align::Center)
      hits << Hit.new(check_x, buttons_top, width, 56.0, "update:check") unless busy

      armed = state.armed == "update"
      canvas.fill_rect(run_x, buttons_top, width, 56.0, armed ? ACCENT : BUTTON, 10.0)
      canvas.stroke_rect(run_x, buttons_top, width, 56.0, can_run ? ACCENT : LINE, 10.0, 2.0)
      label = armed ? t("dashboard.update.confirm") : t("dashboard.update.run")
      fit_text(canvas, run_x + width / 2, buttons_top + 28, label, armed ? SMALL_SIZE : BODY_SIZE, armed ? BACKGROUND : (can_run ? TEXT : MUTED), width - 16, bold: armed, align: Align::Center)
      hits << Hit.new(run_x, buttons_top, width, 56.0, "update:run") if can_run

      message = state.update_message || (update.service_installed ? nil : t("dashboard.update.not_installed"))
      color = state.update_message ? tone_color(state.update_tone) : WARN
      if message
        wrap(canvas, message, RIGHT_W - 40, SMALL_SIZE).first(2).each_with_index do |line, index|
          canvas.text(RIGHT_X + 20, buttons_top + 82 + index * 22, line, SMALL_SIZE, color)
        end
      end
    end

    private def outcome_color(outcome : String) : Color
      case outcome
      when "restarted", "applied", "up_to_date"                     then OK
      when "rolled_back", "rejected", "unknown", "busy"             then WARN
      when "failed", "rollback_failed", "unreachable", "incomplete" then NG
      else                                                               MUTED
      end
    end

    # 時刻は利用者の地域の時刻で、年月日と時分だけを出す。
    private def format_time(time : Time) : String
      time.to_local.to_s("%Y-%m-%d %H:%M")
    end

    private def tone_color(tone : Tone) : Color
      case tone
      in .info?  then TEXT
      in .ok?    then OK
      in .warn?  then WARN
      in .error? then NG
      end
    end

    # 行頭に置かない約物。
    NO_BREAK_BEFORE = "、。，．）」』！？：；,.!?:;)"

    # 折り返しの単位。空白で区切る文字（ラテン文字、キリル文字、ハングル）は語ごと、
    # 語の切れ目を持たない文字（かな、漢字）は 1 字ずつにする。語の前の空白は語に含める。
    # 日本語や中国語の中の英数字（版やパス）も切らずに 1 つとして扱う。「1.2.」と「3」に分かれると読み違える。
    WRAP_UNIT = /\s*[^\s\p{Han}\p{Hiragana}\p{Katakana}、。，．）」』（「『！？：；]+|\s*./

    # 幅に収まるよう折り返す。約物だけは行頭に出さない。
    # 1 語が幅を超えるときはそのまま置く。描くときにはみ出すが、字を欠かして意味を変えるよりよい。
    private def wrap(canvas : Canvas, text : String, width : Float64, size : Float64) : Array(String)
      lines = [] of String
      text.split('\n').each do |paragraph|
        units = paragraph.scan(WRAP_UNIT).map(&.[0])
        current = ""
        units.each do |unit|
          candidate = current + unit
          if !current.empty? && canvas.text_width(candidate, size) > width && !NO_BREAK_BEFORE.includes?(unit.strip)
            lines << current
            current = unit.lstrip
          else
            current = candidate
          end
        end
        lines << current
      end
      lines
    end
  end
end

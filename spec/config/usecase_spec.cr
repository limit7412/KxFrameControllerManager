require "../spec_helper"

private def usecase_with(json : String? = nil) : {Config::Usecase, Fakes::ConfigRepository}
  repository = Fakes::ConfigRepository.new(json)
  {Config::Usecase.new(repository), repository}
end

# 誤りを日本語の文にして比べる。文言は辞書（locales/ja.json）が持つ。
private def describe(error : Config::ValidationError) : String
  error.localize(->(key : String, vars : Hash(String, String)) { Runtime::I18n.log_text(key, vars) })
end

private def messages(usecase : Config::Usecase, json : String) : Array(String)
  usecase.validate(Config::Root.from_json(json)).map { |error| describe(error) }
end

describe Config::Usecase do
  describe "#load" do
    it "設定ファイルが無ければ初期設定を書き出して反映する" do
      usecase, repository = usecase_with
      applied = [] of Config::Root
      usecase.on_apply = ->(root : Config::Root) { applied << root; nil }

      usecase.load.should be_empty

      repository.save_count.should eq 1
      applied.size.should eq 1
    end

    it "有効な設定を読んで反映する" do
      usecase, _ = usecase_with(%({"power_off": {"hold_ms": 3000}}))
      applied = [] of Config::Root
      usecase.on_apply = ->(root : Config::Root) { applied << root; nil }

      usecase.load.should be_empty

      usecase.current.power_off.hold_ms.should eq 3000
      applied.size.should eq 1
    end

    # 壊れたファイルを書き戻すと、利用者が直すための元を失う。
    it "検証を通らない設定は反映せず、ファイルも書き戻さない" do
      usecase, repository = usecase_with(%({"power_off": {"hold_ms": 100}}))
      applied = 0
      usecase.on_apply = ->(_root : Config::Root) { applied += 1; nil }

      usecase.load.should_not be_empty

      usecase.current.power_off.hold_ms.should eq 2000
      applied.should eq 0
      repository.save_count.should eq 0
    end

    it "読めない設定ファイルは初期設定で起動する" do
      usecase, repository = usecase_with("{}")
      repository.unreadable = true

      errors = usecase.load

      errors.size.should eq 1
      errors.first.section.should eq Config::ValidationError::GENERAL
      usecase.current.power_off.hold_ms.should eq 2000
    end
  end

  describe "#reload" do
    it "有効な設定へ差し替える" do
      usecase, repository = usecase_with("{}")
      usecase.load
      repository.stored = %({"log_level": "debug"})

      usecase.reload.should be_empty
      usecase.current.log_level.should eq "debug"
    end

    # 不正な内容を読んだ場合は直前の有効な設定で動作を続ける（仕様書 6.1 節）。
    it "不正な設定を読んだら直前の設定を保つ" do
      usecase, repository = usecase_with(%({"log_level": "debug"}))
      usecase.load
      repository.stored = %({"log_level": "loud"})

      usecase.reload.should_not be_empty
      usecase.current.log_level.should eq "debug"
    end

    it "壊れた JSON を読んだら直前の設定を保つ" do
      usecase, repository = usecase_with(%({"log_level": "debug"}))
      usecase.load
      repository.stored = "{ 壊れている"

      usecase.reload.should_not be_empty
      usecase.current.log_level.should eq "debug"
    end
  end

  describe "#save" do
    it "検証を通れば書き出して反映する" do
      usecase, repository = usecase_with("{}")
      root = Config::Root.default
      root.power_off.hold_ms = 4000

      usecase.save(root).should be_empty

      repository.save_count.should eq 1
      usecase.current.power_off.hold_ms.should eq 4000
    end

    it "検証を通らなければ書き出さず、現在の設定も変えない" do
      usecase, repository = usecase_with("{}")
      root = Config::Root.default
      root.feedback.amplitude = 2.0

      usecase.save(root).should_not be_empty

      repository.save_count.should eq 0
      usecase.current.feedback.amplitude.should eq 0.5
    end
  end

  describe "#validate" do
    it "既定値は検証を通る" do
      usecase, _ = usecase_with
      usecase.validate(Config::Root.default).should be_empty
    end

    describe "power_off" do
      it "hold_ms は 500 から 10000 の範囲に収める" do
        usecase, _ = usecase_with
        messages(usecase, %({"power_off": {"hold_ms": 10001, "warn_ms": 1000}}))
          .should contain "power_off: hold_ms は 500 から 10000 の範囲で指定してください"
        messages(usecase, %({"power_off": {"hold_ms": 10000, "warn_ms": 1000}})).should be_empty
      end

      it "warn_ms は hold_ms 未満にする" do
        usecase, _ = usecase_with
        messages(usecase, %({"power_off": {"hold_ms": 2000, "warn_ms": 2000}}))
          .should contain "power_off: warn_ms は hold_ms 未満で指定してください"
      end

      # 予告の振動から切断までに少なくとも 500 ミリ秒を空ける（仕様書 7.1 節）。
      # 予告を感じてから離すまでの猶予が無いと、中止が間に合わない。
      it "予告から切断までに 500 ミリ秒を空ける" do
        usecase, _ = usecase_with
        messages(usecase, %({"power_off": {"hold_ms": 2000, "warn_ms": 1600}}))
          .should contain "power_off: hold_ms と warn_ms の差は 500 以上にしてください"
        messages(usecase, %({"power_off": {"hold_ms": 2000, "warn_ms": 1500}})).should be_empty
      end

      it "warn_ms は負にできない" do
        usecase, _ = usecase_with
        messages(usecase, %({"power_off": {"warn_ms": -1}}))
          .should contain "power_off: warn_ms は 0 以上で指定してください"
      end
    end

    describe "power_save" do
      it "delay_s は 0 から 600 の範囲に収める" do
        usecase, _ = usecase_with
        messages(usecase, %({"power_save": {"delay_s": 601}}))
          .should contain "power_save: delay_s は 0 から 600 の範囲で指定してください"
        messages(usecase, %({"power_save": {"delay_s": 0}})).should be_empty
      end

      it "brightness_gain は null か正の値にする" do
        usecase, _ = usecase_with
        messages(usecase, %({"power_save": {"brightness_gain": null}})).should be_empty
        messages(usecase, %({"power_save": {"brightness_gain": 0.5}})).should be_empty
        messages(usecase, %({"power_save": {"brightness_gain": 0}}))
          .should contain "power_save: brightness_gain は null か、0 より大きい有限の値で指定してください"
      end
    end

    describe "feedback" do
      it "amplitude は 0.0 から 1.0 の範囲に収める" do
        usecase, _ = usecase_with
        messages(usecase, %({"feedback": {"amplitude": 0.0}})).should be_empty
        messages(usecase, %({"feedback": {"amplitude": 1.0}})).should be_empty
        messages(usecase, %({"feedback": {"amplitude": 1.5}}))
          .should contain "feedback: amplitude は 0.0 から 1.0 の範囲で指定してください"
      end

      # NaN はどの比較でも偽になり、範囲の比較だけでは弾けない。
      it "amplitude の NaN を弾く" do
        usecase, _ = usecase_with
        root = Config::Root.default
        root.feedback.amplitude = Float64::NAN

        usecase.validate(root).map { |error| describe(error) }.should contain "feedback: amplitude は 0.0 から 1.0 の範囲で指定してください"
      end
    end

    it "steamvr.retry_interval_s と frame_link.port と input.poll_interval_ms の範囲を見る" do
      usecase, _ = usecase_with
      errors = messages(usecase, %({"steamvr": {"retry_interval_s": 0}, "frame_link": {"port": 0}, "input": {"poll_interval_ms": 0}}))

      errors.should contain "steamvr: retry_interval_s は 1 から 600 の範囲で指定してください"
      errors.should contain "frame_link: port は 1 から 65535 の範囲で指定してください"
      errors.should contain "input: poll_interval_ms は 1 から 100 の範囲で指定してください"
    end

    # language の値の一覧は辞書の側が持つため、composition root が検証を登録する。ここでは見ない。
    it "log_level と update.channel は決まった値だけを受け付ける" do
      usecase, _ = usecase_with
      errors = messages(usecase, %({"log_level": "loud", "language": "xx", "update": {"channel": "beta"}}))

      errors.should eq [
        "全般: log_level は trace / debug / info / notice / warn / error / fatal / none のいずれかで指定してください",
        "update: channel は stable / test のいずれかで指定してください",
      ]
    end

    it "登録した追加の検証を呼ぶ" do
      usecase, _ = usecase_with
      usecase.register_validator("power_off") do |root|
        root.power_off.target.both? ? [Config::Usecase.choice_problem("target", ["pressed"])] : [] of Config::Problem
      end

      messages(usecase, %({"power_off": {"target": "both"}})).should eq ["power_off: target は pressed のいずれかで指定してください"]
      messages(usecase, %({"power_off": {"target": "pressed"}})).should be_empty
    end
  end
end

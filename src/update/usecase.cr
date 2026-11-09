require "log"

require "./models"
require "./repository"

module Update
  # 確認の結末。
  #
  # 「新しい版が無い」と「確かめられなかった」を呼び出し側が書き分けられるよう、
  # nil ではなく結末そのものを返す。
  # `update` コマンドがどちらも黙ると、利用者には無反応と区別が付かない。
  enum Outcome
    # 新しい版が出ている。
    Available
    # 実行中の版が最新である。
    UpToDate
    # 一覧を取れなかった。回線が無いか、API が応えなかった。
    Unreachable
    # 候補を集めきれず、最新かどうかを言い切れない。
    # 取得の上限に掛かり、押し出された範囲に新しい版が残っている場合がこれにあたる。
    Incomplete
    # 実行中の版を比べられない。手元ビルドの 0.1.0-dev がこれにあたる。
    Unknown
  end

  struct CheckResult
    getter outcome : Outcome
    getter release : Release?

    def initialize(@outcome, @release = nil)
    end

    def available? : Bool
      @outcome.available?
    end
  end

  # 新しい版を探し、見つけたかどうかを覚える。
  class Usecase
    Log = ::Log.for("update")

    # 直近の確認に使ったチャンネル。まだ確認できていなければ nil。
    #
    # 結果と一緒に覚えておかないと、設定を test から stable へ変えたときに、
    # 直前に見つけたプレリリースが次の確認まで表示に残る。
    # 逆向きでは、プレリリースを一度も調べていないのに「最新である」と出る。
    getter checked_channel : String? = nil

    def initialize(@repository : Repository)
      @available = nil.as(Release?)
      # 直近の確認で候補を集めきれたか。
      @complete = true
    end

    # 今のチャンネルで見つけている新しい版。
    # 別のチャンネルで確認した結果は、設定と食い違うため返さない。
    def available(channel : String) : Release?
      return nil unless @checked_channel == channel
      @available
    end

    # 今のチャンネルで確認が成り立ったか。
    # 「新しい版は無い」と「まだ確かめていない」を書き分けるために使う。
    def checked?(channel : String) : Bool
      @checked_channel == channel
    end

    # 直近の確認で候補を集めきれたか。
    # 集めきれていない場合は「最新である」と言い切らない。
    def complete? : Bool
      @complete
    end

    # 新しい版を探す。
    #
    # 手元ビルドの版（0.1.0-dev）は運用しているタグの綴りから外れており、
    # 何と比べても順序が決まらない。確認そのものを行わず Unknown を返す。
    def check(current : String, channel : String) : CheckResult
      running = Version.parse?(current)
      if running.nil?
        Log.debug { "実行中の版を比べられないため確認しない: #{current}" }
        return CheckResult.new(Outcome::Unknown)
      end

      catalog = fetch(channel)
      return CheckResult.new(Outcome::Unreachable) unless catalog

      @checked_channel = channel
      @complete = catalog.complete?
      newest = newest_in(catalog.releases, channel)
      if newest.nil? || newest.version <= running
        @available = nil

        # 候補を集めきれていないなら、最新だとは言い切れない。
        # 押し出された範囲に、版番号がより大きい安定版が残っている可能性がある。
        # 確かめていないことを「最新である」と伝えるわけにはいかない。
        return CheckResult.new(Outcome::Incomplete) unless catalog.complete?

        return CheckResult.new(Outcome::UpToDate)
      end

      Log.info { "新しい版が出ている: #{newest.tag}（実行中は #{current}）" }
      @available = newest
      CheckResult.new(Outcome::Available, newest)
    end

    # 回線が無い環境では確認のたびに失敗する。
    # 例外にはせず警告ログに留め、結末は Unreachable として返す。
    private def fetch(channel : String) : Catalog?
      @repository.fetch_releases(channel)
    rescue exception
      Log.warn(exception: exception) { "更新の確認に失敗した" }
      nil
    end

    # 応答の並び順に頼らず、対象のうち最も新しいものを選ぶ。
    #
    # stable では repository が安定版だけを返すが、ここでも絞る。
    # 絞りをどちらか一方に任せると、片方を直したときにもう片方が黙って通してしまう。
    private def newest_in(releases : Array(Release), channel : String) : Release?
      candidates = channel == "test" ? releases : releases.select(&.stable?)
      candidates.max_by?(&.version)
    end
  end
end

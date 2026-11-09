require "../spec_helper"
require "../../src/update/usecase"

private class FakeRepository < Update::Repository
  property releases : Array(Update::Release)
  property error : Exception?
  getter calls = 0

  def initialize(@releases = [] of Update::Release, @error = nil)
  end

  # 直近に渡されたチャンネル。stable と test でエンドポイントが分かれることの確認に使う。
  getter last_channel : String? = nil

  # 候補を集めきれたか。取得の上限に掛かった場合を真似る。
  property complete : Bool = true

  def fetch_releases(channel : String) : Update::Catalog
    @calls += 1
    @last_channel = channel
    if error = @error
      raise error
    end
    Update::Catalog.new(@releases, @complete)
  end

  # 取得した内容。呼ばれたかどうかの確認に使う。
  property downloaded : Array({Update::Asset, String}) = [] of {Update::Asset, String}
  property download_error : Exception? = nil

  def download(asset : Update::Asset, path : String) : Nil
    if error = @download_error
      raise error
    end
    @downloaded << {asset, path}
  end
end

private def release(tag : String, prerelease : Bool = false) : Update::Release
  version = Update::Version.parse?(tag).not_nil!
  Update::Release.new(version, tag, "https://example.test/#{tag}", prerelease)
end

describe Update::Usecase do
  describe "#check" do
    it "新しい安定版を見つける" do
      usecase = Update::Usecase.new(FakeRepository.new([release("0.0.1"), release("1.0.0")]))

      result = usecase.check("0.0.1", "stable")

      result.outcome.should eq Update::Outcome::Available
      result.release.try(&.tag).should eq "1.0.0"
      usecase.available("stable").try(&.tag).should eq "1.0.0"
    end

    it "実行中が最新なら UpToDate を返す" do
      usecase = Update::Usecase.new(FakeRepository.new([release("1.0.0")]))

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::UpToDate
      usecase.available("stable").should be_nil
    end

    # GitHub が latest とするのは作成順で最も新しい安定版であり、版番号の最大ではない。
    # 2.0.0 の後に保守版の 1.5.1 を出した場合がこれにあたる。
    it "作成順が新しいだけの安定版に引きずられない" do
      usecase = Update::Usecase.new(
        FakeRepository.new([release("2.0.0"), release("1.5.1")]))

      result = usecase.check("1.6.0", "stable")

      result.outcome.should eq Update::Outcome::Available
      result.release.try(&.tag).should eq "2.0.0"
    end

    # 応答の並び順に頼らない。GitHub は作成順に返すが、タグの新しさとは限らない。
    it "並び順ではなく版の新しさで選ぶ" do
      usecase = Update::Usecase.new(
        FakeRepository.new([release("1.0.0"), release("2.0.0"), release("1.5.0")]))

      usecase.check("1.0.0", "stable").release.try(&.tag).should eq "2.0.0"
    end

    describe "チャンネル" do
      it "stable はプレリリースを拾わない" do
        usecase = Update::Usecase.new(
          FakeRepository.new([release("1.0.0"), release("1.0.1-test1", prerelease: true)]))

        usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::UpToDate
      end

      it "test はプレリリースも拾う" do
        usecase = Update::Usecase.new(
          FakeRepository.new([release("1.0.0"), release("1.0.1-test1", prerelease: true)]))

        result = usecase.check("1.0.0", "test")
        result.outcome.should eq Update::Outcome::Available
        result.release.try(&.tag).should eq "1.0.1-test1"
      end
    end

    # 手元ビルドは運用しているタグの綴りから外れており、比べる相手が決まらない。
    it "版を読めない実行中の版では一覧すら取りに行かない" do
      repository = FakeRepository.new([release("1.0.0")])
      usecase = Update::Usecase.new(repository)

      usecase.check("0.1.0-dev", "stable").outcome.should eq Update::Outcome::Unknown
      repository.calls.should eq 0
    end

    # 回線が無い環境では確認のたびに失敗する。例外にせず結末で返す。
    it "一覧を取れなければ Unreachable を返し、確認済みにしない" do
      usecase = Update::Usecase.new(
        FakeRepository.new(error: Exception.new("つながらない")))

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::Unreachable
      usecase.checked?("stable").should be_false
    end

    # 集めきれていないのに「最新である」と言うと、押し出された範囲に残っている
    # 版を見落としたまま利用者へ伝えることになる。
    it "候補を集めきれていなければ最新だと言い切らない" do
      repository = FakeRepository.new([release("1.0.0")])
      repository.complete = false
      usecase = Update::Usecase.new(repository)

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::Incomplete
      usecase.complete?.should be_false
    end

    # 見つかったものは確かに存在する。集めきれていなくても知らせてよい。
    it "集めきれていなくても新しい版が見つかれば知らせる" do
      repository = FakeRepository.new([release("2.0.0")])
      repository.complete = false
      usecase = Update::Usecase.new(repository)

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::Available
    end

    it "集めきれていれば complete? は真である" do
      usecase = Update::Usecase.new(FakeRepository.new([release("1.0.0")]))

      usecase.check("1.0.0", "stable")

      usecase.complete?.should be_true
    end

    it "一覧が空なら UpToDate を返す" do
      usecase = Update::Usecase.new(FakeRepository.new)

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::UpToDate
      usecase.checked?("stable").should be_true
    end

    # 新しい版を見つけた後で取り下げられることがある。表示に残し続けない。
    it "新しい版が消えたら available も下ろす" do
      repository = FakeRepository.new([release("2.0.0")])
      usecase = Update::Usecase.new(repository)
      usecase.check("1.0.0", "stable")
      usecase.available("stable").should_not be_nil

      repository.releases = [release("1.0.0")]
      usecase.check("1.0.0", "stable")

      usecase.available("stable").should be_nil
    end
  end

  # 設定を変えた直後に、別のチャンネルで確かめた結果が残っていてはならない。
  describe "チャンネルをまたいだ結果" do
    it "確認したチャンネルでしか結果を返さない" do
      usecase = Update::Usecase.new(
        FakeRepository.new([release("1.0.0"), release("1.0.1-test1", prerelease: true)]))
      usecase.check("1.0.0", "test")

      usecase.available("test").try(&.tag).should eq "1.0.1-test1"
      usecase.available("stable").should be_nil
    end

    # test で確かめただけの状態を stable の「最新である」と読ませない。
    it "確認していないチャンネルは未確認として扱う" do
      usecase = Update::Usecase.new(FakeRepository.new([release("1.0.0")]))
      usecase.check("1.0.0", "stable")

      usecase.checked?("stable").should be_true
      usecase.checked?("test").should be_false
    end

    it "チャンネルを渡し直せば結果も入れ替わる" do
      usecase = Update::Usecase.new(
        FakeRepository.new([release("1.0.0"), release("1.0.1-test1", prerelease: true)]))
      usecase.check("1.0.0", "test")
      usecase.check("1.0.0", "stable")

      usecase.available("test").should be_nil
      usecase.checked?("stable").should be_true
    end

    # 確認が終わると checked_channel はそのチャンネルへ移る。
    # 応答を待つ間に設定が元へ戻っていると、戻した側が未確認の扱いに変わる。
    # 呼び出し側はこれを見て取り直しを判断できる。
    it "確認が終わると前のチャンネルは未確認へ戻る" do
      usecase = Update::Usecase.new(FakeRepository.new([release("1.0.0")]))
      usecase.check("1.0.0", "stable")
      usecase.checked?("stable").should be_true

      usecase.check("1.0.0", "test")

      usecase.checked?("stable").should be_false
      usecase.checked?("test").should be_true
    end

    # 安定版と test でエンドポイントが分かれるため、repository へそのまま渡す。
    it "チャンネルを repository へ渡す" do
      repository = FakeRepository.new([release("1.0.0")])
      usecase = Update::Usecase.new(repository)

      usecase.check("0.9.0", "test")

      repository.last_channel.should eq "test"
    end
  end
end

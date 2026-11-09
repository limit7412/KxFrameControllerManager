require "../spec_helper"
require "../../src/update/installer"

# 実ファイルの入れ替えを確かめる。
# 走っている実行ファイルの上へリネームで重ねられることは Linux の rename(2) の性質であり、
# spec でも実ファイルで確かめられる。

private class FakeRepository < Update::Repository
  property body : String = "新しい実行ファイル"
  property error : Exception? = nil
  getter downloads = 0

  def fetch_releases(channel : String) : Update::Catalog
    Update::Catalog.new([] of Update::Release)
  end

  def download(asset : Update::Asset, path : String) : Nil
    @downloads += 1
    if error = @error
      raise error
    end
    File.write(path, @body)
  end
end

# 正規のパスへの移動が失敗する Installer。
# 実ファイルでは、置き場所が別のファイルシステムに分かれた場合や、書き込めない場合がこれにあたる。
private class BrokenInstaller < Update::Installer
  protected def move(from : String, to : String) : Nil
    raise File::Error.new("動かせない", file: from) if to == @executable_path
    super
  end
end

private record Fixture,
  installer : Update::Installer,
  repository : FakeRepository,
  executable : String

private def with_installer(running : String = "0.0.1", broken : Bool = false, & : Fixture -> Nil) : Nil
  directory = File.join(Dir.tempdir, "kxfcm-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(directory)
  begin
    executable = File.join(directory, "kx-frame-controller-manager")
    File.write(executable, "実行中の実行ファイル")
    repository = FakeRepository.new
    staged = "#{executable}.new"
    installer =
      if broken
        BrokenInstaller.new(repository, running, executable, staged)
      else
        Update::Installer.new(repository, running, executable, staged)
      end
    yield Fixture.new(installer.as(Update::Installer), repository, executable)
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def release(tag : String, body : String, prerelease : Bool = false) : Update::Release
  Update::Release.new(
    Update::Version.parse?(tag).not_nil!,
    tag,
    "https://example.test/#{tag}",
    prerelease,
    Update::Asset.new(
      Digest::SHA256.hexdigest(body),
      "https://example.test/#{tag}/kx-frame-controller-manager-linux-aarch64",
      body.bytesize.to_i64,
    ),
  )
end

describe Update::Installer do
  describe "#download" do
    it "取得して記録を添える" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body)).should be_true

        staged = fixture.installer.staged("test").not_nil!
        staged.tag.should eq "1.0.0"
        File.read(fixture.installer.staged_path).should eq fixture.repository.body
      end
    end

    # 手で作った安定版に実行ファイルを添え忘れた場合がこれにあたる。
    # 取りに行く先が無いので、リリースページを開いてもらうところで止める。
    it "アセットの無いリリースは取りに行かない" do
      with_installer do |fixture|
        without_asset = Update::Release.new(
          Update::Version.new(1, 0, 0), "1.0.0", "https://example.test/1.0.0")

        fixture.installer.download(without_asset).should be_false
        fixture.repository.downloads.should eq 0
      end
    end
  end

  describe "#staged" do
    it "取得していなければ nil を返す" do
      with_installer do |fixture|
        fixture.installer.staged("test").should be_nil
      end
    end

    # 取得から置き換えまでの間に壊れることはある。
    # 壊れたものを実行ファイルとして置くわけにはいかない。
    it "記録と中身が食い違えば捨てる" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))
        File.write(fixture.installer.staged_path, "書き換えられた中身")

        fixture.installer.staged("test").should be_nil
        File.exists?(fixture.installer.staged_path).should be_false
        File.exists?(fixture.installer.metadata_path).should be_false
      end
    end

    it "記録を読めなければ捨てる" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))
        File.write(fixture.installer.metadata_path, "{ 壊れている")

        fixture.installer.staged("test").should be_nil
        File.exists?(fixture.installer.staged_path).should be_false
      end
    end

    # 片方だけ残っていても置き換えには使えない。
    it "記録だけが残っていても使わない" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))
        File.delete(fixture.installer.staged_path)

        fixture.installer.staged("test").should be_nil
      end
    end

    # 取得と置き換えの間には、設定を変えて再起動するだけの間がある。
    # test で取ったプレリリースを取得済みのまま stable へ変えられると、
    # 選び直した設定に反してプレリリースが入る。
    it "今のチャンネルの対象でなければ捨てる" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.1-test1", fixture.repository.body))

        fixture.installer.staged("stable").should be_nil
        File.exists?(fixture.installer.staged_path).should be_false
        File.exists?(fixture.installer.metadata_path).should be_false
      end
    end

    it "test は安定版も対象にする" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))

        fixture.installer.staged("test").should_not be_nil
      end
    end

    # 綴りだけでは足りない。手で作ったリリースに GitHub のプレリリースの印だけが
    # 付くことがあり、確認の側は綴りと印の両方を見ている。
    it "綴りが安定版でもプレリリースの印が付いていれば stable では捨てる" do
      with_installer do |fixture|
        fixture.installer.download(
          release("1.0.0", fixture.repository.body, prerelease: true))

        fixture.installer.staged("test").should_not be_nil
        fixture.installer.staged("stable").should be_nil
      end
    end
  end

  describe "#apply" do
    it "取得したもので置き換え、実行の権限を付ける" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))
        staged = fixture.installer.staged("test").not_nil!

        fixture.installer.apply(staged).should be_true

        File.read(fixture.executable).should eq fixture.repository.body
        File.info(fixture.executable).permissions.should eq Update::Installer::EXECUTABLE_PERMISSIONS
        # 置き換えた後は取得済みとして残さない。次の確認でまた同じものを置かないためである。
        fixture.installer.staged("test").should be_nil
      end
    end

    # 走っているプロセスは、開いたままのファイルを読み続けられる。
    # 置き換えで消えるのは名前だけであり、古い中身は閉じるまで残る。
    it "開いたままの古い実行ファイルは置き換えの後も読める" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))
        staged = fixture.installer.staged("test").not_nil!

        File.open(fixture.executable) do |running|
          fixture.installer.apply(staged).should be_true
          running.gets_to_end.should eq "実行中の実行ファイル"
        end
      end
    end

    # 置き換えに失敗しても、元の実行ファイルと取得したものの両方が残る。
    # 取得したものを捨てると、やり直すには取り直すしかなくなる。
    it "置き換えに失敗したら元の実行ファイルと取得したものを残す" do
      with_installer(broken: true) do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))
        staged = fixture.installer.staged("test").not_nil!

        expect_raises(File::Error) do
          fixture.installer.apply(staged)
        end

        File.read(fixture.executable).should eq "実行中の実行ファイル"
        File.exists?(fixture.installer.staged_path).should be_true
        File.exists?(fixture.installer.metadata_path).should be_true
      end
    end

    # 置き換えは済んでいる。記録の掃除は後始末であり、失敗しても成否は変わらない。
    # 投げると、成功した置き換えが失敗として扱われ、再起動しないまま終わる。
    it "置き換えた後の記録を消せなくても成功として返す" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))
        staged = fixture.installer.staged("test").not_nil!

        # 記録をディレクトリに差し替えて、消せない状態を作る。
        File.delete(fixture.installer.metadata_path)
        Dir.mkdir(fixture.installer.metadata_path)

        fixture.installer.apply(staged).should be_true

        File.read(fixture.executable).should eq fixture.repository.body
      end
    end
  end

  describe "#discard" do
    # まとめて 1 つの rescue で括ると、先の 1 つが消せなかったときに
    # もう片方を試さないまま抜ける。両方が残ると staged の照合をまた通ってしまう。
    it "片方を消せなくてももう片方は消す" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))

        # 実体をディレクトリに差し替えて、消せない状態を作る。
        File.delete(fixture.installer.staged_path)
        Dir.mkdir(fixture.installer.staged_path)

        fixture.installer.discard

        File.exists?(fixture.installer.metadata_path).should be_false
      end
    end
  end

  describe "#discard_incomplete" do
    # 取得の最中に終了すると、記録を書く前に書きかけだけが残る。
    it "記録の無い書きかけを片付ける" do
      with_installer do |fixture|
        File.write(fixture.installer.staged_path, "書きかけ")

        fixture.installer.discard_incomplete

        File.exists?(fixture.installer.staged_path).should be_false
      end
    end

    it "実体の無い記録も片付ける" do
      with_installer do |fixture|
        File.write(fixture.installer.metadata_path, "{}")

        fixture.installer.discard_incomplete

        File.exists?(fixture.installer.metadata_path).should be_false
      end
    end

    # 揃っているものは取得済みであり、置き換える対象である。
    it "揃っているものは残す" do
      with_installer do |fixture|
        fixture.installer.download(release("1.0.0", fixture.repository.body))

        fixture.installer.discard_incomplete

        fixture.installer.staged("test").should_not be_nil
      end
    end

    it "どちらも無ければ何もしない" do
      with_installer do |fixture|
        fixture.installer.discard_incomplete
      end
    end
  end
end

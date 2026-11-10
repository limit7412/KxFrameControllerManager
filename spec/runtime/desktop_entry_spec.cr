require "../spec_helper"
require "../../src/runtime/desktop_entry"

describe Runtime::DesktopEntry do
  it "Steam の一覧に出る形で書き、選んだら start を実行させる" do
    content = Runtime::DesktopEntry.content("/home/deck/.local/bin/kx-frame-controller-manager")
    content.should start_with "[Desktop Entry]\n"
    content.should contain "Type=Application\n"
    content.should contain "Name=KxFrameControllerManager\n"
    content.should contain %(Exec="/home/deck/.local/bin/kx-frame-controller-manager" start\n)
    content.should contain "TryExec=/home/deck/.local/bin/kx-frame-controller-manager\n"
    # Steam は NoDisplay=true と、gamescope を外す OnlyShowIn・NotShowIn の項目を一覧から除く。
    content.should_not contain "NoDisplay"
    content.should_not contain "OnlyShowIn"
    content.should_not contain "NotShowIn"
  end

  it "説明文を全言語ぶん並べ、既定は英語にする" do
    content = Runtime::DesktopEntry.content("/x")
    content.should contain "Comment=#{Runtime::I18n.t_in("en", "desktop_entry.comment")}\n"
    content.should contain "Comment[ja]=#{Runtime::I18n.t_in("ja", "desktop_entry.comment")}\n"
    content.should contain "Comment[zh_CN]="
    content.should contain "Comment[zh_TW]="
    content.should_not contain "Comment[en]="
    Runtime::I18n::CODES.size.should eq content.lines.count(&.starts_with?("Comment"))
  end

  it "Exec の % を %% にし、TryExec はそのまま書く" do
    content = Runtime::DesktopEntry.content("/home/deck/my apps/kx%fcm")
    content.should contain %(Exec="/home/deck/my apps/kx%%fcm" start\n)
    content.should contain "TryExec=/home/deck/my apps/kx%fcm\n"
  end

  it "引用符の中で逃がしが要る文字を含むパスは受け付けない" do
    ["/a\"b", "/a`b", "/a$b", "/a\\b", "/a\nb"].each do |path|
      expect_raises(ArgumentError) { Runtime::DesktopEntry.content(path) }
    end
  end

  it "同時に書いても、どちらも失敗せず、書き終えた中身が残る" do
    directory = File.tempname("kxfcm-desktop")
    path = File.join(directory, Runtime::DesktopEntry::FILE_NAME)
    begin
      done = Channel(Exception?).new
      20.times do |index|
        spawn do
          Runtime::DesktopEntry.write("/#{index % 2}", path)
          done.send(nil)
        rescue exception
          done.send(exception)
        end
      end
      20.times { done.receive.should be_nil }
      ["/0", "/1"].map { |exe| Runtime::DesktopEntry.content(exe) }.should contain File.read(path)
      Dir.children(directory).should eq [Runtime::DesktopEntry::FILE_NAME]
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "中身が変わったときだけ書き、消せば無くなる" do
    directory = File.tempname("kxfcm-desktop")
    path = File.join(directory, "applications", Runtime::DesktopEntry::FILE_NAME)
    begin
      Runtime::DesktopEntry.write("/a", path).should be_true
      File.read(path).should eq Runtime::DesktopEntry.content("/a")
      Runtime::DesktopEntry.write("/a", path).should be_false
      Runtime::DesktopEntry.write("/b", path).should be_true
      File.read(path).should contain "TryExec=/b\n"
      # 隣に書いたファイルは残さない。
      Dir.children(File.dirname(path)).should eq [Runtime::DesktopEntry::FILE_NAME]

      Runtime::DesktopEntry.delete(path)
      File.exists?(path).should be_false
      # 無いものを消しても何も起きない。
      Runtime::DesktopEntry.delete(path)
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

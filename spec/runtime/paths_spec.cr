require "../spec_helper"
require "../../src/runtime/paths"

describe Runtime::Paths do
  describe ".xdg" do
    it "環境変数が絶対パスならそれを使う" do
      Runtime::Paths.xdg("XDG_CONFIG_HOME", ".config", {"XDG_CONFIG_HOME" => "/data/config", "HOME" => "/home/deck"})
        .should eq "/data/config"
    end

    it "無ければホームの下の既定を使う" do
      Runtime::Paths.xdg("XDG_STATE_HOME", ".local/state", {"HOME" => "/home/deck"})
        .should eq "/home/deck/.local/state"
    end

    # 仕様では相対パスは無効として扱う。そのまま使うと起動した場所で置き場所が変わる。
    it "相対パスと空は無視する" do
      Runtime::Paths.xdg("XDG_DATA_HOME", ".local/share", {"XDG_DATA_HOME" => "share", "HOME" => "/home/deck"})
        .should eq "/home/deck/.local/share"
      Runtime::Paths.xdg("XDG_DATA_HOME", ".local/share", {"XDG_DATA_HOME" => "", "HOME" => "/home/deck"})
        .should eq "/home/deck/.local/share"
    end
  end

  it "置き場所はどれもアプリ名のディレクトリの下にある" do
    {Runtime::Paths.config_path, Runtime::Paths.log_directory, Runtime::Paths.manifest_path}.each do |path|
      path.should contain "/KxFrameControllerManager/"
    end
  end
end

require "../spec_helper"

describe Config::FileRepository do
  describe "#save" do
    it "ディレクトリを作って書き出し、読み戻せる" do
      directory = File.tempname("kxfcm-spec")
      path = File.join(directory, "nested", "config.json")
      repository = Config::FileRepository.new(path)

      repository.exists?.should be_false
      root = Config::Root.default
      root.power_off.hold_ms = 2500
      repository.save(root)

      repository.exists?.should be_true
      repository.load.power_off.hold_ms.should eq 2500
      # 一時ファイルは置き換えに使った後に残らない。
      File.exists?("#{path}.tmp").should be_false
    ensure
      FileUtils.rm_rf(directory) if directory
    end
  end
end

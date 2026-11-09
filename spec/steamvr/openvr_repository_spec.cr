require "../spec_helper"
require "../../src/steamvr/openvr_repository"

describe SteamVR::OpenVRRepository do
  describe ".library_candidates" do
    # 指定したのに見つからないとき、黙って別の場所のものを使うと、何を読んだのかが分からなくなる。
    it "設定で場所を指定したらそこだけを見る" do
      SteamVR::OpenVRRepository.library_candidates("/tmp/libopenvr_api.so", {"HOME" => "/nonexistent"})
        .should eq ["/tmp/libopenvr_api.so"]
    end

    it "指定が無ければ Steam Frame の既定の場所を先に見る" do
      candidates = SteamVR::OpenVRRepository.library_candidates("", {"HOME" => "/nonexistent"})

      candidates.first.should eq File.join(
        "/opt/steamvr", "bin", SteamVR::OpenVRRepository::PLATFORM_DIRECTORY, "libopenvr_api.so")
    end

    it "openvrpaths.vrpath の runtime を続けて見る" do
      home = File.tempname("kxfcm-spec")
      Dir.mkdir_p(File.join(home, ".config", "openvr"))
      File.write(
        File.join(home, ".config", "openvr", "openvrpaths.vrpath"),
        %({"runtime": ["/games/SteamVR", "/opt/steamvr"]}),
      )

      candidates = SteamVR::OpenVRRepository.library_candidates("", {"HOME" => home})

      platform = SteamVR::OpenVRRepository::PLATFORM_DIRECTORY
      # 既定の場所と重なる runtime は 1 回だけ見る。
      candidates.should eq [
        "/opt/steamvr/bin/#{platform}/libopenvr_api.so",
        "/games/SteamVR/bin/#{platform}/libopenvr_api.so",
      ]
    ensure
      FileUtils.rm_rf(home) if home
    end

    it "openvrpaths.vrpath が壊れていても既定の場所は見る" do
      home = File.tempname("kxfcm-spec")
      Dir.mkdir_p(File.join(home, ".config", "openvr"))
      File.write(File.join(home, ".config", "openvr", "openvrpaths.vrpath"), "{ 壊れている")

      SteamVR::OpenVRRepository.library_candidates("", {"HOME" => home}).size.should eq 1
    ensure
      FileUtils.rm_rf(home) if home
    end
  end

  describe ".kind_of" do
    it "本ツールが読み分けるイベントの番号を対応づける" do
      SteamVR::OpenVRRepository.kind_of(100_u32).should eq SteamVR::EventKind::TrackedDeviceActivated
      SteamVR::OpenVRRepository.kind_of(101_u32).should eq SteamVR::EventKind::TrackedDeviceDeactivated
      SteamVR::OpenVRRepository.kind_of(700_u32).should eq SteamVR::EventKind::Quit
      SteamVR::OpenVRRepository.kind_of(1_u32).should eq SteamVR::EventKind::Other
    end
  end

  # openvr_capi.h は Windows 以外で 4 バイト境界に詰める。大きさが食い違うと
  # PollNextEvent はイベントを返さないか、隣のメモリを書き潰す。
  it "VREvent_t の大きさを Linux の openvr_capi.h に合わせる" do
    sizeof(SteamVR::LibOpenVR::VREvent).should eq 60
  end

  # ライブラリが見つからない環境では、開けないことを返すだけで落ちない。
  it "ライブラリが無ければ open は偽を返す" do
    repository = SteamVR::OpenVRRepository.new({"HOME" => "/nonexistent"})
    repository.library_path = "/nonexistent/libopenvr_api.so"

    repository.open.should be_false
    repository.opened?.should be_false
    repository.poll_events.should be_empty
  end
end

require "../spec_helper"

MANIFEST_PATH = "/home/deck/.local/share/KxFrameControllerManager/kx-frame-controller-manager.vrmanifest"
EXE_PATH      = "/home/deck/.local/bin/kx-frame-controller-manager"

private def build(action_manifest_path : String? = nil)
  repository = Fakes::SteamVRRepository.new
  store = Fakes::ManifestStore.new
  usecase = SteamVR::Usecase.new(repository, store, MANIFEST_PATH, EXE_PATH, action_manifest_path)
  {usecase, repository, store}
end

describe SteamVR::Usecase do
  describe ".build_manifest" do
    it "起動時に解決した実行ファイルの絶対パスを Linux のキーで埋める" do
      json = JSON.parse(SteamVR::Usecase.build_manifest(EXE_PATH))
      application = json["applications"][0]

      json["source"].as_s.should eq "builtin"
      application["app_key"].as_s.should eq "kairo.kxframecontrollermanager"
      application["launch_type"].as_s.should eq "binary"
      application["binary_path_linux"].as_s.should eq EXE_PATH
      application.as_h.has_key?("binary_path_windows").should be_false
      application["strings"]["ja_jp"]["name"].as_s.should eq "KxFrameControllerManager"
    end

    it "アクションマニフェストは渡したときだけ書く" do
      without = JSON.parse(SteamVR::Usecase.build_manifest(EXE_PATH))
      without["applications"][0].as_h.has_key?("action_manifest_path").should be_false

      given = JSON.parse(SteamVR::Usecase.build_manifest(EXE_PATH, "/home/deck/actions.json"))
      given["applications"][0]["action_manifest_path"].as_s.should eq "/home/deck/actions.json"
    end
  end

  describe "#connect" do
    it "つながったら vrmanifest を書き出して登録する" do
      usecase, repository, store = build("/home/deck/actions.json")

      usecase.connect.should be_true

      usecase.connected?.should be_true
      repository.added_manifests.should eq [MANIFEST_PATH]
      JSON.parse(store.files[MANIFEST_PATH])["applications"][0]["action_manifest_path"].as_s
        .should eq "/home/deck/actions.json"
    end

    # SteamVR が動いていないことは Background の初期化の失敗として表れる。
    # 異常ではないので、偽を返すだけで何も書かない。
    it "SteamVR が動いていなければ何もせず偽を返す" do
      usecase, repository, store = build
      repository.unavailable = true

      usecase.connect.should be_false

      usecase.connected?.should be_false
      store.files.should be_empty
    end

    # 入力と切断の確認に登録は要らない。登録の失敗で接続まで捨てると、
    # 長押しの機能ごと使えなくなる。
    it "登録に失敗しても接続は保つ" do
      usecase, repository, _ = build
      repository.fail_add = true

      usecase.connect.should be_true
      usecase.connected?.should be_true
    end

    it "つながっている間は開き直さない" do
      usecase, repository, _ = build
      usecase.connect
      usecase.connect

      repository.open_count.should eq 1
    end
  end

  describe "#unregister" do
    it "登録を外し、生成した vrmanifest も消す" do
      usecase, repository, store = build
      usecase.connect

      usecase.unregister.should be_true

      repository.removed_manifests.should eq [MANIFEST_PATH]
      store.files.should be_empty
    end

    it "登録の解除に失敗したら vrmanifest を残す" do
      usecase, repository, store = build
      usecase.connect
      repository.fail_remove = true

      usecase.unregister.should be_false
      store.files.should_not be_empty
    end

    it "vrmanifest を消せなくても解除できたことを返す" do
      usecase, _, store = build
      usecase.connect
      store.fail_delete = true

      usecase.unregister.should be_true
    end

    it "つながっていなければ解除しない" do
      usecase, repository, _ = build

      usecase.unregister.should be_false
      repository.removed_manifests.should be_empty
    end
  end

  describe "#poll" do
    it "溜まっているイベントを返す" do
      usecase, repository, _ = build
      usecase.connect
      repository.push(SteamVR::EventKind::TrackedDeviceDeactivated, 3_u32)

      events = usecase.poll

      events.map(&.kind).should eq [SteamVR::EventKind::TrackedDeviceDeactivated]
      events.first.device_index.should eq 3
      usecase.connected?.should be_true
    end

    # KxNotifyUtils と違い、SteamVR の終了でプロセスは終わらない（仕様書 3.6 節）。
    # 応答してから OpenVR を閉じ、再試行へ戻れる状態にする。
    it "終了要求を受けたら応答してから閉じる" do
      usecase, repository, _ = build
      usecase.connect
      repository.push(SteamVR::EventKind::Quit)

      usecase.poll

      repository.acknowledged.should be_true
      usecase.connected?.should be_false
    end

    it "つながっていなければ空を返す" do
      usecase, _, _ = build
      usecase.poll.should be_empty
    end
  end
end

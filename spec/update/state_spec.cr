require "../spec_helper"
require "../../src/update/state"

private def with_store(& : Update::FileStateStore, String -> Nil) : Nil
  directory = File.join(Dir.tempdir, "kxfcm-state-#{Random::Secure.hex(8)}")
  begin
    store = Update::FileStateStore.new(
      File.join(directory, "update.json"),
      File.join(directory, "running.json"),
      File.join(directory, "update.lock"),
    )
    yield store, directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe Update::State do
  it "戻した版は重ねず、上限を超えたら古いものから捨てる" do
    state = Update::State.new
    state.reject("1.0.0")
    state.reject("1.0.0")
    state.rejected.should eq ["1.0.0"]

    (1..Update::State::MAX_REJECTED + 2).each { |i| state.reject("2.0.#{i}") }
    state.rejected.size.should eq Update::State::MAX_REJECTED
    state.rejected?("1.0.0").should be_false
    state.rejected?("2.0.#{Update::State::MAX_REJECTED + 2}").should be_true
  end
end

describe Update::FileStateStore do
  it "書いた状態を読み戻す。ファイルが無ければ空の状態を返す" do
    with_store do |store, _|
      store.load.last_checked_at.should be_nil

      state = Update::State.new
      state.last_checked_at = Time.utc(2026, 11, 9, 12, 0, 0)
      state.reject("1.1.0")
      store.save(state)

      loaded = store.load
      loaded.last_checked_at.should eq Time.utc(2026, 11, 9, 12, 0, 0)
      loaded.rejected.should eq ["1.1.0"]
    end
  end

  it "壊れた状態は空として扱う" do
    with_store do |store, directory|
      Dir.mkdir_p(directory)
      File.write(File.join(directory, "update.json"), "{")
      store.load.rejected.should be_empty
    end
  end

  it "起動の印を書いて読む" do
    with_store do |store, directory|
      store.running.should be_nil
      Update::FileStateStore.write_marker(File.join(directory, "running.json"), "1.1.0", 1234_i64)
      marker = store.running.not_nil!
      marker.version.should eq "1.1.0"
      marker.pid.should eq 1234
    end
  end

  it "排他は 1 つだけが取れ、外せば次が取れる" do
    with_store do |store, directory|
      other = Update::FileStateStore.new(
        File.join(directory, "update.json"),
        File.join(directory, "running.json"),
        File.join(directory, "update.lock"),
      )
      store.try_lock.should be_true
      other.try_lock.should be_false
      store.unlock
      other.try_lock.should be_true
      other.unlock
    end
  end
end

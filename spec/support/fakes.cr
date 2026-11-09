require "json"
require "../../src/config/repository"
require "../../src/steamvr/repository"

# 外部境界のテスト用実装。
# usecase をファイルにも OpenVR にも触れずに確かめるために差し替える。
module Fakes
  # ファイルを持たない Config::Repository 実装。
  class ConfigRepository < Config::Repository
    property stored : String?
    property save_count : Int32 = 0
    # load が失敗する状況を真似る。
    property unreadable : Bool = false

    def initialize(@stored : String? = nil)
    end

    def path : String
      "(memory)"
    end

    def exists? : Bool
      !@stored.nil?
    end

    def load : Config::Root
      raise JSON::ParseException.new("壊れている", 1, 1) if @unreadable
      Config::Root.from_json(@stored || "{}")
    end

    def save(root : Config::Root) : Nil
      @stored = root.to_json
      @save_count += 1
    end
  end

  class SteamVRRepository < SteamVR::Repository
    property opened : Bool = false
    # 真にすると open が失敗する。SteamVR が動いていない状況を真似る。
    property unavailable : Bool = false
    property open_count : Int32 = 0
    property added_manifests : Array(String) = [] of String
    property removed_manifests : Array(String) = [] of String
    property acknowledged : Bool = false
    property fail_add : Bool = false
    property fail_remove : Bool = false
    # 次の poll_events で返すイベント。返したら空にする。
    property pending_events : Array(SteamVR::Event) = [] of SteamVR::Event

    def open : Bool
      @open_count += 1
      return false if @unavailable
      @opened = true
    end

    def close : Nil
      @opened = false
    end

    def opened? : Bool
      @opened
    end

    def add_application_manifest(manifest_path : String) : Bool
      return false if @fail_add
      @added_manifests << manifest_path
      true
    end

    def remove_application_manifest(manifest_path : String) : Bool
      return false if @fail_remove
      @removed_manifests << manifest_path
      true
    end

    def poll_events : Array(SteamVR::Event)
      events = @pending_events
      @pending_events = [] of SteamVR::Event
      events
    end

    def acknowledge_quit : Nil
      @acknowledged = true
    end

    # イベントを 1 件積む。
    def push(kind : SteamVR::EventKind, device_index : UInt32 = 0_u32) : Nil
      @pending_events << SteamVR::Event.new(kind, 0_u32, device_index)
    end
  end

  class ManifestStore < SteamVR::ManifestStore
    property files : Hash(String, String) = {} of String => String
    # 真にすると delete が例外を上げる。ファイルを消せない状況を作る。
    property fail_delete : Bool = false

    def write(path : String, content : String) : Nil
      @files[path] = content
    end

    def delete(path : String) : Nil
      raise File::Error.new("消せなかった", file: path) if @fail_delete
      @files.delete(path)
    end

    def exists?(path : String) : Bool
      @files.has_key?(path)
    end
  end
end

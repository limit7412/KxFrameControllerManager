require "json"
require "log"

module Update
  # 自動更新が次の確認まで覚えておくこと。
  #
  # 常駐とは別のプロセス（systemd のタイマーから起動する `update --auto`）が読み書きするため、
  # メモリではなくファイルに置く。
  class State
    include JSON::Serializable

    # 巻き戻した版を覚えておく数の上限。古いものから捨てる。
    MAX_REJECTED = 20

    # 最後に確認した時刻。確認の間隔はここから数える。
    property last_checked_at : Time? = nil
    # 置き換えた後に正しく起動しなかったため、巻き戻した版のタグ。
    #
    # 覚えておかないと、次の確認でまた同じ版を見つけ、置き換えては戻すことを繰り返す。
    # 手動の `update` はこの記録を見ない。利用者が明示的に入れようとしているためである。
    property rejected : Array(String) = [] of String

    def initialize
    end

    def reject(tag : String) : Nil
      @rejected.delete(tag)
      @rejected << tag
      @rejected.shift(@rejected.size - MAX_REJECTED) if @rejected.size > MAX_REJECTED
    end

    def rejected?(tag : String) : Bool
      @rejected.includes?(tag)
    end
  end

  # 常駐が起動したときに残す印。
  #
  # 自動更新は、ユニットを再起動した後にこの印を読み、新しい版が起動して主ループへ入れたかを確かめる。
  # 版だけでなくプロセス番号も持つのは、起動直後に落ちて systemd が起動し直した場合を見分けるためである。
  # その場合は版が合っていてもプロセス番号が変わる。
  struct RunningMarker
    include JSON::Serializable

    getter version : String
    getter pid : Int64

    def initialize(@version, @pid)
    end
  end

  # 状態、起動の印、排他の境界。spec では差し替える。
  abstract class StateStore
    abstract def load : State
    abstract def save(state : State) : Nil
    abstract def running : RunningMarker?

    # 排他を取る。取れなければ偽を返す。取れたら、終わったときに unlock を呼ぶ。
    # タイマーからの確認と、利用者が手で打った `update` が重なったときに、片方だけを走らせる。
    abstract def try_lock : Bool
    abstract def unlock : Nil
  end

  # 状態をファイルへ置く実装。どれも状態のディレクトリ（~/.local/state/KxFrameControllerManager/）に置く。
  class FileStateStore < StateStore
    Log = ::Log.for("update")

    @lock : File? = nil

    def initialize(@state_path : String, @marker_path : String, @lock_path : String)
    end

    # 読めなければ空の状態として扱う。壊れた記録のせいで更新が止まるよりよい。
    def load : State
      return State.new unless File.exists?(@state_path)
      State.from_json(File.read(@state_path))
    rescue exception : JSON::Error | IO::Error
      Log.warn(exception: exception) { "更新の状態を読めないため空として扱う: #{@state_path}" }
      State.new
    end

    # 書きかけを残さないよう、隣へ書いてからリネームする。
    def save(state : State) : Nil
      FileStateStore.write_atomically(@state_path, state.to_json)
    end

    def running : RunningMarker?
      return nil unless File.exists?(@marker_path)
      RunningMarker.from_json(File.read(@marker_path))
    rescue exception : JSON::Error | IO::Error
      Log.debug(exception: exception) { "起動の印を読めない: #{@marker_path}" }
      nil
    end

    # 印を書く。常駐が起動したときに呼ぶ。
    def self.write_marker(path : String, version : String, pid : Int64) : Nil
      write_atomically(path, RunningMarker.new(version, pid).to_json)
    end

    # 排他は flock で取る。プロセスが落ちれば OS が外すため、取ったまま残ることが無い。
    def try_lock : Bool
      Dir.mkdir_p(File.dirname(@lock_path))
      file = File.open(@lock_path, "a")
      begin
        file.flock_exclusive(blocking: false)
      rescue IO::Error
        file.close
        Log.info { "別の更新が走っているため何もしない" }
        return false
      end
      @lock = file
      true
    end

    def unlock : Nil
      if file = @lock
        file.flock_unlock
        file.close
        @lock = nil
      end
    end

    protected def self.write_atomically(path : String, content : String) : Nil
      Dir.mkdir_p(File.dirname(path))
      temporary = "#{path}.tmp"
      File.write(temporary, content)
      File.rename(temporary, path)
    end
  end
end

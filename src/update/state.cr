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

    # 走っている更新の段階。終われば nil に戻す。
    # 常駐の設定画面が読み、進み具合として見せる。
    property progress : Progress? = nil
    # 最後に走った更新の結末。設定と間隔のために何もしなかった回は残さない。
    property last_run : LastRun? = nil

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

  # 更新の段階。
  enum Phase
    # GitHub Releases を見ている。
    Checking
    # 新しい版を取っている。
    Downloading
    # 取ったものを試しに起動している。
    Verifying
    # 置き換えてユニットを再起動し、新しい版の起動を待っている。
    Restarting
    # 新しい版が起動しなかったため、元へ戻している。
    RollingBack
  end

  # 走っている更新の段階と、走らせているプロセス。
  #
  # 更新のプロセスが途中で落ちると、ファイルには段階が残ったままになる。
  # 読む側はプロセス番号を見て、もう走っていない更新の段階を捨てる。
  struct Progress
    include JSON::Serializable

    getter phase : Phase
    getter pid : Int64
    getter started_at : Time

    # 更新はユニットの TimeoutStartSec（15 分）で止められる。それより古い段階は、落ちた更新の残りである。
    MAX_AGE = 30.minutes

    def initialize(@phase, @pid, @started_at)
    end

    # この段階を、走っている更新のものとして信じてよいか。
    #
    # cmdline は pid のプロセスの /proc/<pid>/cmdline（NUL 区切り）で、プロセスがいなければ nil を渡す。
    # プロセスがいるだけでは足りない。落ちた更新の番号が、再起動の後などに別のプロセスへ使い回されることがある。
    # そのため、本ツールの実行ファイルが update として動いていることまで見る。
    def current?(now : Time, cmdline : String?) : Bool
      return false if now - @started_at > MAX_AGE
      return false unless cmdline
      arguments = cmdline.split('\0', remove_empty: true)
      program = arguments.first?
      return false unless program
      File.basename(program).starts_with?("kx-frame-controller-manager") && arguments[1]? == "update"
    end
  end

  # 走り終えた更新の結末。outcome は RunOutcome の名前を小文字とアンダースコアにしたものである。
  struct LastRun
    include JSON::Serializable

    getter outcome : String
    getter tag : String?
    getter finished_at : Time

    def initialize(@outcome, @tag, @finished_at)
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

    # 排他が外れるまで待って取る。`uninstall` が、走っている自動更新の終わりを待つのに使う。
    def lock : Nil
      Dir.mkdir_p(File.dirname(@lock_path))
      file = File.open(@lock_path, "a")
      file.flock_exclusive
      @lock = file
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

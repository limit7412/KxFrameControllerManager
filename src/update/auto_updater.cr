require "log"

require "../config/models"
require "./installer"
require "./models"
require "./repository"
require "./state"
require "./usecase"

module Update
  # 置き換えたユニットの操作。実装は systemctl --user を呼ぶ（runtime/systemd.cr）。
  abstract class ServiceControl
    # ユニットが動いているか。動いていなければ置き換えるだけで再起動しない。
    abstract def active? : Bool
    # ユニットを起動し直す。呼び出しが通れば真を返す。
    abstract def restart : Bool
    # ユニットの主プロセスの番号。動いていなければ nil を返す。
    abstract def main_pid : Int64?
    # 失敗の状態と起動回数の制限を解く。
    # 新しい版が起動直後に落ち続けると、systemd は StartLimitBurst に達したユニットの起動を断る。
    # 解かないまま戻しても、元の版を起動できない。
    abstract def reset_failed : Nil
  end

  # 取得した実行ファイルを、置き換える前に試しに起動して確かめる。
  #
  # 照合（digest）が確かめるのは、取ったものがリリースの添付と同じかどうかまでである。
  # 添付そのものがこのヘッドセットで起動できるか（glibc の版、アーキテクチャ）は、起動してみないと分からない。
  abstract class Preflight
    # path を起動して、tag の版を名乗るかを見る。
    abstract def verify(path : String, tag : String) : Bool
  end

  # 時刻と待ち。spec では進め方を差し替える。
  abstract class Clock
    abstract def now : Time
    abstract def sleep(span : Time::Span) : Nil
  end

  class SystemClock < Clock
    def now : Time
      Time.utc
    end

    def sleep(span : Time::Span) : Nil
      ::sleep span
    end
  end

  # 実行ファイルを `version` で起動し、出力を見る実装。
  class ProcessPreflight < Preflight
    Log = ::Log.for("update")

    # `version` は設定も SteamVR も読まずに版を出して終わる。これより長く掛かるなら起動に問題がある。
    TIMEOUT = 10.seconds

    def verify(path : String, tag : String) : Bool
      output = IO::Memory.new
      process = Process.new(path, ["version"], output: output, error: Process::Redirect::Close)
      done = Channel(Process::Status).new(1)
      spawn(name: "preflight") { done.send(process.wait) }

      status = select
      when received = done.receive
        received
      when timeout(TIMEOUT)
        process.terminate(graceful: false)
        Log.warn { "試しに起動した #{path} が #{TIMEOUT.total_seconds.to_i} 秒で終わらなかった" }
        return false
      end

      ProcessPreflight.matches?(status.success?, output.to_s, tag).tap do |ok|
        Log.warn { "試しに起動した #{path} が #{tag} を名乗らなかった（終了コード #{status.exit_code}）: #{output.to_s.strip}" } unless ok
      end
    rescue exception : IO::Error | File::Error
      Log.warn(exception: exception) { "取得した実行ファイルを試しに起動できなかった: #{path}" }
      false
    end

    # 出力が tag と同じ版を表しているか。
    # 手動の安定版のタグは v が付くことがあり、実行ファイルが名乗る版には付かない。版として比べる。
    def self.matches?(success : Bool, output : String, tag : String) : Bool
      return false unless success

      printed = Version.parse?(output.strip)
      expected = Version.parse?(tag)
      return printed == expected if printed && expected

      output.strip == tag
    end
  end

  # 自動更新の 1 回ぶんの結末。
  enum RunOutcome
    # 設定で自動更新を切っている。
    Disabled
    # 前回の確認から設定の間隔が経っていない。
    NotDue
    # 別の更新が走っている。
    Busy
    # 以下の 4 つは Usecase#check の結末をそのまま返したもの。
    UpToDate
    Unreachable
    Incomplete
    Unknown
    # 新しい版は、前に置き換えて正しく起動しなかったものだった。
    Rejected
    # 取得、照合、試しの起動、置き換えのどれかに失敗した。今の実行ファイルはそのまま残っている。
    Failed
    # 置き換えた。ユニットが動いていなかったため再起動はしていない。
    Applied
    # 置き換えてユニットを再起動し、新しい版が起動したことを確かめた。
    Restarted
    # 置き換えて再起動したが新しい版が起動しなかったため、元へ戻した。
    RolledBack
    # 元へ戻そうとして失敗した。実行ファイルを手で直す必要がある。
    RollbackFailed

    # タイマーから呼んだときに、ユニットを失敗として残すべき結末か。
    def failure? : Bool
      unreachable? || failed? || rolled_back? || rollback_failed?
    end
  end

  struct RunResult
    getter outcome : RunOutcome
    getter tag : String?

    def initialize(@outcome, @tag = nil)
    end
  end

  # 新しい版を探し、見つけたら置き換え、ユニットを再起動して起動を確かめる。
  # 起動しなかったら元へ戻す。
  #
  # systemd のタイマーから `update --auto` として起動する。
  # 常駐の中で行わないのは、再起動させる側と再起動される側を分けるためである。
  # 常駐の中から自分のユニットを再起動すると、新しい版が起動したかを確かめる前に自分が止まり、
  # 起動しなかったときに戻す者がいなくなる。タイマーのユニットは常駐とは別に動くので、
  # 常駐を再起動した後も残って起動を確かめられる。
  class AutoUpdater
    Log = ::Log.for("update")

    # 再起動から、新しい版が起動の印を残すまでを待つ上限。
    # SteamVR が動いていなくても、常駐は設定を読んだ直後に印を残す。数秒で足りるところを広めに取る。
    START_TIMEOUT = 60.seconds
    # 印を確かめた後、落ちずに動き続けているかを見る時間。
    # 起動直後の主ループで落ちるものは、systemd の RestartSec（10 秒）より前に落ちる。
    STABLE_FOR = 20.seconds
    # 印を見に行く間隔。
    POLL_INTERVAL = 1.second

    def initialize(
      @repository : Repository,
      @installer : Installer,
      @state : StateStore,
      @service : ServiceControl,
      @preflight : Preflight,
      @running_version : String,
      @clock : Clock = SystemClock.new,
    )
    end

    # manual が真なら、利用者が `update` を手で打った場合として扱う。
    # 設定の無効と間隔、巻き戻した版の記録を見ない。
    def run(settings : Config::UpdateSection, manual : Bool = false) : RunResult
      return RunResult.new(RunOutcome::Busy) unless @state.try_lock
      begin
        run_exclusively(settings, manual)
      ensure
        @state.unlock
      end
    end

    private def run_exclusively(settings : Config::UpdateSection, manual : Bool) : RunResult
      unless manual || (settings.check_enabled && settings.auto_update)
        return RunResult.new(RunOutcome::Disabled)
      end

      state = @state.load
      now = @clock.now
      return RunResult.new(RunOutcome::NotDue) if !manual && !due?(state, settings, now)

      # 確認に失敗しても時刻を残す。回線が無い間に、タイマーのたびに API を叩き直さないためである。
      result = Usecase.new(@repository).check(@running_version, settings.channel)
      state.last_checked_at = now
      @state.save(state)

      release = result.release
      return RunResult.new(from_check(result.outcome)) unless result.available? && release

      if !manual && state.rejected?(release.tag)
        Log.info { "#{release.tag} は前に戻した版のため入れない" }
        return RunResult.new(RunOutcome::Rejected, release.tag)
      end

      install(release, settings.channel)
    end

    # 前回の確認から間隔が経ったか。
    # 前回が未来にある（時計を戻した）なら、経ったものとして扱う。待ち続けて確認が止まるよりよい。
    private def due?(state : State, settings : Config::UpdateSection, now : Time) : Bool
      last = state.last_checked_at
      return true unless last
      return true if last > now

      now - last >= settings.check_interval_h.hours
    end

    private def install(release : Release, channel : String) : RunResult
      tag = release.tag
      record = @installer.download(release) ? @installer.staged(channel) : nil
      return RunResult.new(RunOutcome::Failed, tag) unless record

      @installer.make_executable
      unless @preflight.verify(@installer.staged_path, tag)
        # このヘッドセットで起動できないものは、取り直しても起動できない。
        # 覚えておかないと、間隔のたびに取り直しては捨てることになる。
        @installer.discard
        reject(tag)
        return RunResult.new(RunOutcome::Failed, tag)
      end

      @installer.apply(record)
      return RunResult.new(RunOutcome::Applied, tag) unless @service.active?

      if @service.restart && started?(tag)
        Log.info { "#{tag} で起動したことを確かめた" }
        return RunResult.new(RunOutcome::Restarted, tag)
      end

      roll_back(tag)
    rescue exception
      # 取得の失敗は repository が文言だけの例外で伝える。どの失敗でも今の実行ファイルは残っている。
      Log.error(exception: exception) { "#{tag} への置き換えに失敗した" }
      RunResult.new(RunOutcome::Failed, tag)
    end

    # 新しい版が起動の印を残し、そのまま動き続けているか。
    private def started?(tag : String) : Bool
      deadline = @clock.now + START_TIMEOUT
      pid = nil.as(Int64?)
      loop do
        pid = started_pid(tag)
        break if pid
        if @clock.now >= deadline
          Log.error { "#{tag} が #{START_TIMEOUT.total_seconds.to_i} 秒以内に起動しなかった" }
          return false
        end
        @clock.sleep POLL_INTERVAL
      end

      @clock.sleep STABLE_FOR
      return true if @service.active? && @service.main_pid == pid

      Log.error { "#{tag} は起動した後 #{STABLE_FOR.total_seconds.to_i} 秒以内に止まった" }
      false
    end

    # ユニットの主プロセスが tag の版として印を残していれば、そのプロセス番号を返す。
    private def started_pid(tag : String) : Int64?
      return nil unless @service.active?
      pid = @service.main_pid
      marker = @state.running
      return nil unless pid && marker && marker.pid == pid
      return nil unless ProcessPreflight.matches?(true, marker.version, tag)
      pid
    end

    private def roll_back(tag : String) : RunResult
      reject(tag)
      unless @installer.rollback
        Log.error { "#{tag} から戻せなかった。実行ファイルを入れ直す必要がある" }
        return RunResult.new(RunOutcome::RollbackFailed, tag)
      end

      @service.reset_failed
      unless @service.restart
        Log.error { "元の版へ戻したが、ユニットを起動し直せなかった" }
      end
      Log.warn { "#{tag} が起動しなかったため #{@running_version} へ戻した" }
      RunResult.new(RunOutcome::RolledBack, tag)
    rescue exception : IO::Error | File::Error
      Log.error(exception: exception) { "#{tag} から戻せなかった" }
      RunResult.new(RunOutcome::RollbackFailed, tag)
    end

    # 覚えられなくても投げない。
    # 巻き戻しの手前で呼ぶため、ここで投げると起動しない版が置かれたまま残る。
    # 覚え損ねた版は次の確認でまた入れようとするが、そのときも同じく戻せる。
    private def reject(tag : String) : Nil
      state = @state.load
      state.reject(tag)
      @state.save(state)
    rescue exception
      Log.error(exception: exception) { "戻した版 #{tag} を記録できなかった" }
    end

    private def from_check(outcome : Outcome) : RunOutcome
      case outcome
      in .up_to_date?  then RunOutcome::UpToDate
      in .unreachable? then RunOutcome::Unreachable
      in .incomplete?  then RunOutcome::Incomplete
      in .unknown?     then RunOutcome::Unknown
      in .available?   then RunOutcome::Failed
      end
    end
  end

  # update セクションの範囲（仕様書 6.1 節）。Config::Usecase#register_validator で登録する。
  CHECK_INTERVAL_H_RANGE = 1..168

  def self.validate(section : Config::UpdateSection) : Array(String)
    errors = [] of String
    unless CHECK_INTERVAL_H_RANGE.includes?(section.check_interval_h)
      errors << "check_interval_h は #{CHECK_INTERVAL_H_RANGE.begin} から #{CHECK_INTERVAL_H_RANGE.end} の範囲で指定する"
    end
    errors
  end
end

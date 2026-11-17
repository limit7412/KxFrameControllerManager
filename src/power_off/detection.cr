require "json"
require "./models"

module PowerOff
  # 常駐が長押しを検出できる状態かを、`status` コマンドへ知らせる記録。
  #
  # `status` は常駐とは別のプロセスで動き、自分で SteamVR へつないで調べる。
  # 常駐の接続でアクションを読ませられたかどうかは、`status` の接続からは分からない。
  # そのため常駐が状態の変わり目でファイルへ書き、`status` はそれを読む。
  struct DetectionReport
    include JSON::Serializable

    getter state : Detection
    # 書いた常駐のプロセス番号。
    getter pid : Int64
    # この状態になった時刻。
    getter since : Time

    def initialize(@state, @pid, @since)
    end

    # この記録を、動いている常駐のものとして信じてよいか。
    #
    # cmdline は pid のプロセスの /proc/<pid>/cmdline（NUL 区切り）で、プロセスがいなければ nil を渡す。
    # 常駐は終わるときに記録を消すが、落ちたときは残る。
    # 残った番号は再起動の後などに別のプロセスへ使い回されることがあるため、
    # 本ツールの実行ファイルが run として動いていることまで見る。
    def current?(cmdline : String?) : Bool
      return false unless cmdline
      arguments = cmdline.split('\0', remove_empty: true)
      program = arguments.first?
      return false unless program
      File.basename(program).starts_with?("kx-frame-controller-manager") && arguments[1]? == "run"
    end
  end

  # 記録のファイル。
  class DetectionFile
    getter path : String

    def initialize(@path : String)
    end

    # 記録を読む。ファイルが無いときと読めないときは nil を返す。
    # 読めない記録には、別の版の常駐が書いた知らない状態も含む。
    def load : DetectionReport?
      DetectionReport.from_json(File.read(@path))
    rescue File::Error | JSON::ParseException
      nil
    end

    # 書き込み中に `status` が読んでも途中の内容を見せないよう、一時ファイルを経由して置き換える。
    def save(report : DetectionReport) : Nil
      Dir.mkdir_p(File.dirname(@path))
      temporary = "#{@path}.tmp"
      File.write(temporary, report.to_json)
      File.rename(temporary, @path)
    end

    def delete : Nil
      File.delete?(@path)
    end
  end

  # 状態が変わったときだけ記録を書く。常駐の主ループから 1 拍ごとに呼ぶ。
  class DetectionRecorder
    def initialize(@file : DetectionFile, @pid : Int64)
      @last = nil.as(Detection?)
    end

    # 書けなかったときは例外を上げる。同じ状態では書き直さないため、失敗を拍ごとに繰り返さない。
    def record(state : Detection, now : Time = Time.utc) : Nil
      return if state == @last
      @last = state
      @file.save(DetectionReport.new(state, @pid, now))
    end

    # 記録を消す。常駐が終わるときに呼ぶ。
    def clear : Nil
      @last = nil
      @file.delete
    end
  end
end

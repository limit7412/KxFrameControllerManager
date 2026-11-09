require "digest/sha256"
require "json"
require "log"

require "./models"
require "./repository"

module Update
  # 取得した実行ファイルで、今の実行ファイルを置き換える（仕様書 5.2 節）。
  #
  # Linux では、走っている実行ファイルの上へ別のファイルをリネームで重ねられる。
  # 走っているプロセスは古い中身を掴んだまま動き続け、次に起動したものから新しい中身になる。
  # rename(2) は同じファイルシステムの中なら原子的であり、途中で失敗しても元のファイルが残る。
  #
  # 置き換える前に、今の実行ファイルを .old へハードリンクで残す。
  # 置き換え自体はリネームで済むが、新しい版が起動できなかったときに戻す先が要る（自動更新の巻き戻し）。
  # 複写ではなくハードリンクにするのは、同じ中身を二重に書かずに済み、途中で切れた複写が残らないためである。
  #
  # 実行ファイルのパスが変わらないため、SteamVR へ登録したマニフェストの
  # binary_path_linux は書き換えなくてよい。
  # 置き換えた後の再起動（systemctl --user restart）は呼び出し側が行う。
  #
  # 取得と置き換えを分けてあるのは、置き換える前に取得したものをもう一度確かめるためである。
  class Installer
    Log = ::Log.for("update")

    # 読み出しの単位。
    BUFFER_SIZE = 64 * 1024

    # 取得しておいた実行ファイルに添える記録。
    #
    # 取得したときに一度照合しているが、置き換える前にもう一度照合する。
    # 取得から置き換えまでの間に壊れたものを、そのまま実行ファイルとして置くわけにはいかない。
    struct Staged
      include JSON::Serializable

      getter tag : String
      getter digest : String
      getter size : Int64
      # 安定版のチャンネルで拾う対象か。取得したときの Release#stable? を残す。
      #
      # タグの綴りだけでは足りない。手で作ったリリースに GitHub のプレリリースの印だけが
      # 付くことがあり、確認の側（Release#stable?）は綴りと印の両方を見ている。
      # 印は API の応答にしか無いので、取得した時点で残しておかないと後から引けない。
      #
      # 記録に無いときは偽とする。分からないものを stable へ入れない。
      getter stable : Bool = false

      def initialize(@tag, @digest, @size, @stable = false)
      end
    end

    # 置き換えた実行ファイルに付ける権限。所有者だけが書け、誰でも実行できる。
    EXECUTABLE_PERMISSIONS = File::Permissions.new(0o755)

    getter staged_path : String

    def initialize(
      @repository : Repository,
      @running_version : String,
      @executable_path : String,
      @staged_path : String,
    )
    end

    # 置き換える前の実行ファイルを残しておく場所。巻き戻しはここから戻す。
    def backup_path : String
      "#{@executable_path}.old"
    end

    # 取得したものに添える記録の置き場所。
    def metadata_path : String
      "#{@staged_path}.json"
    end

    # リリースのアセットを取り、記録と一緒に残す。
    #
    # アセットを持たないリリースでは何もせず偽を返す。
    # 手で作った安定版に実行ファイルを添え忘れた場合がこれにあたり、
    # そのときは利用者にリリースページから取ってもらう。
    def download(release : Release) : Bool
      asset = release.asset
      unless asset
        Log.info { "置き換えに使えるアセットが無い: #{release.tag}" }
        return false
      end

      @repository.download(asset, @staged_path)
      File.write(
        metadata_path,
        Staged.new(release.tag, asset.digest, asset.size, release.stable?).to_json,
      )
      Log.info { "置き換える実行ファイルを取得した: #{release.tag}" }
      true
    end

    # 取得済みで、今のチャンネルに合い、記録と照合の通る実行ファイル。無ければ nil を返す。
    #
    # 合わないものはその場で捨てる。残しておいても次の起動でまた同じ照合に落ちるだけであり、
    # 取り直しの機会を与えたほうがよい。
    def staged(channel : String) : Staged?
      return nil unless File.exists?(metadata_path) && File.exists?(@staged_path)

      record = Staged.from_json(File.read(metadata_path))

      # 今のチャンネルが拾う版かを見る。
      #
      # 取得と置き換えの間には、設定を変えて再起動するだけの間がある。
      # test で取ったプレリリースを取得済みのまま stable へ変えられると、
      # 選び直した設定に反してプレリリースが入る。
      unless covered_by?(record, channel)
        Log.info { "取得しておいた #{record.tag} は今のチャンネル（#{channel}）の対象ではないため捨てる" }
        discard
        return nil
      end

      # 実行中より新しいものだけを置く。
      # 取得してから起動しないまま日が経ち、その間に手で新しい版へ入れ替えられていると、
      # 取っておいた古いほうへ引き戻すことになる。
      unless newer_than_running?(record.tag)
        Log.info { "取得しておいた #{record.tag} は実行中の #{@running_version} より新しくないため捨てる" }
        discard
        return nil
      end

      return record if verified?(record)

      Log.warn { "取得しておいた実行ファイルが記録と合わないため捨てる: #{@staged_path}" }
      discard
      nil
    rescue exception : JSON::Error | IO::Error
      Log.warn(exception: exception) { "取得しておいた実行ファイルを確かめられないため捨てる" }
      discard
      nil
    end

    # 取得しておいたものを消す。
    #
    # 片方ずつ消す。まとめて 1 つの rescue で括ると、先の 1 つが消せなかったときに
    # もう片方を試さないまま抜ける。両方が残ると staged の照合をまた通り、
    # 取り直しを案内した直後から同じものが適用できてしまう。
    def discard : Nil
      delete_quietly(@staged_path)
      delete_quietly(metadata_path)
    end

    # 消せなくても投げない。
    # 呼ぶのは失敗した後の後始末の場面であり、ここで投げると元の失敗を伝える経路まで落ちる。
    private def delete_quietly(path : String) : Nil
      File.delete?(path)
    rescue exception : IO::Error
      Log.warn(exception: exception) { "消せなかった: #{path}" }
    end

    # 片方だけ残った取得を片付ける。
    #
    # 取得の最中に終了すると、書きかけの実行ファイルだけが残る。
    # 記録は取得が終わってから書くためである。
    # そのままでは最大で MAX_ASSET_SIZE 分の書きかけが次の取得まで居座る。
    #
    # 呼ぶのは起動時だけとする。取得の最中に呼ぶと、
    # 書いている途中のものを消すことになる。
    def discard_incomplete : Nil
      staged = File.exists?(@staged_path)
      metadata = File.exists?(metadata_path)
      return if staged == metadata

      Log.info { "途中で終わった取得を片付ける: #{@staged_path}" }
      discard
    end

    # 実行ファイルを置き換える。
    #
    # 置き換える前に実行の権限を付ける。取得したファイルは通常のファイルとして書かれており、
    # そのまま置くと次の起動で実行できない。
    #
    # 置き換えに失敗しても元の実行ファイルは残る。取得したものも残し、やり直せるようにする。
    # 元の実行ファイルを残せなかったときは置き換えない。戻す先の無い置き換えは、自動では行わない。
    def apply(record : Staged) : Bool
      make_executable
      backup
      move(@staged_path, @executable_path)

      # ここから先は後始末である。置き換えは済んでおり、成否は変わらない。
      # 消せずに残っても、次の起動で discard_incomplete が片方だけの状態として片付ける。
      delete_quietly(metadata_path)

      Log.info { "実行ファイルを #{record.tag} へ置き換えた" }
      true
    end

    # 取得したものに実行の権限を付ける。
    # 置き換える前に試しに起動して確かめる（Preflight）ため、apply とは別に呼べるようにしてある。
    def make_executable : Nil
      File.chmod(@staged_path, EXECUTABLE_PERMISSIONS)
    end

    # 残しておいた実行ファイルへ戻す。戻す先が無ければ偽を返す。
    #
    # 戻すのもリネームで行う。途中で失敗しても、置き換えた後の実行ファイルはそのまま残る。
    def rollback : Bool
      unless File.exists?(backup_path)
        Log.error { "戻す先の実行ファイルが無い: #{backup_path}" }
        return false
      end

      move(backup_path, @executable_path)
      Log.info { "実行ファイルを置き換える前のものへ戻した" }
      true
    end

    # 今の実行ファイルを backup_path へ残す。
    #
    # 前回の残りは先に消す。ハードリンクは行き先が既にあると作れない。
    # ハードリンクを作れないファイルシステムでは複写する。
    private def backup : Nil
      File.delete?(backup_path)
      begin
        File.link(@executable_path, backup_path)
      rescue exception : File::Error
        Log.debug { "ハードリンクを作れないため複写する: #{exception.message}" }
        File.copy(@executable_path, backup_path)
      end
    end

    # 実ファイルの入れ替え。
    #
    # 置き換えの成否はこの移動だけで決まる。
    # 1 か所にまとめてあるのは、spec でここを差し替えて失敗する状況を作るためである。
    protected def move(from : String, to : String) : Nil
      File.rename(from, to)
    end

    # その記録が、指定のチャンネルで拾う対象か。
    #
    # test は両方を拾う。stable は取得したときに Release#stable? だったものだけを拾う。
    # 確認の側の絞り込み（Usecase#newest_in）と同じ基準であり、
    # 「今のチャンネルならこの版を見つけたか」に答えている。
    private def covered_by?(record : Staged, channel : String) : Bool
      return true if channel == "test"

      record.stable
    end

    # 取得しておいたものが実行中より新しいか。
    #
    # どちらかが版として読めなければ新しいものとして扱う。
    # 手元ビルド（0.1.0-dev）がこれにあたるが、そこへ辿り着くのは
    # 利用者が明示的に取得を押した場合だけであり、その意図を優先する。
    private def newer_than_running?(tag : String) : Bool
      running = Version.parse?(@running_version)
      staged = Version.parse?(tag)
      return true unless running && staged

      staged > running
    end

    # 記録された大きさと digest の両方を見る。
    # 大きさを先に見るのは、違っていれば読まずに落とせるためである。
    private def verified?(record : Staged) : Bool
      return false unless File.info(@staged_path).size == record.size

      digest_of(@staged_path) == record.digest
    end

    private def digest_of(path : String) : String
      digest = Digest::SHA256.new
      File.open(path, "rb") do |file|
        buffer = Bytes.new(BUFFER_SIZE)
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end
      digest.final.hexstring
    end
  end
end

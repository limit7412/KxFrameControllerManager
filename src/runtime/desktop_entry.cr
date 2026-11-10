require "log"
require "random/secure"
require "./i18n"
require "./paths"

module Runtime
  # VR のメニューの「プログラムを起動」に本ツールを出すための .desktop ファイル。
  #
  # その一覧は Steam が作る。Steam は XDG のアプリケーションのディレクトリ（~/.local/share/applications など）にある
  # .desktop を集め、NoDisplay=true のものと、OnlyShowIn か NotShowIn で gamescope を外したものを除いて並べる。
  # 選ぶと Exec の行を実行する。vrmanifest の登録はこの一覧に関わらない。
  #
  # Steam のファイル（shortcuts.vdf など）は書き換えない。Steam の稼働中に書くと上書きされるか壊れうるためである。
  # .desktop は ~ の下に置く 1 ファイルで済み、消せば元に戻る。
  #
  # 選んだときは `start` を実行する。常駐が既に動いていれば systemd は何もしない。
  module DesktopEntry
    Log = ::Log.for("desktop_entry")

    FILE_NAME = "kx-frame-controller-manager.desktop"
    NAME      = "KxFrameControllerManager"
    # freedesktop のアイコン名の決まりにある名前。Steam が描かなくても一覧には出る。
    ICON = "input-gaming"

    # 中身を組み立てる。説明文は全言語ぶんを Comment[言語] で並べ、既定は英語にする。
    #
    # Exec の引数は二重引用符で囲む。引用符の中で逃がしが要る文字（" ` $ \）と改行を含むパスは受け付けない。
    # Exec の % は欄の指定子として読まれるため %% にする。TryExec は欄の指定子を持たないので、そのまま書く。
    # TryExec の実行ファイルが無ければ、Steam もデスクトップも一覧から外す。
    def self.content(executable : String) : String
      if executable.each_char.any? { |char| char.in?('"', '`', '$', '\\', '\n', '\r') }
        raise ArgumentError.new(".desktop に書けない文字が実行ファイルのパスに含まれている: #{executable}")
      end

      String.build do |io|
        io << "[Desktop Entry]\n"
        io << "Type=Application\n"
        io << "Version=1.5\n"
        io << "Name=" << NAME << '\n'
        io << "Comment=" << I18n.t_in("en", "desktop_entry.comment") << '\n'
        I18n::CODES.each do |code|
          next if code == "en"
          io << "Comment[" << tag(code) << "]=" << I18n.t_in(code, "desktop_entry.comment") << '\n'
        end
        io << %(Exec="#{executable.gsub("%", "%%")}" start\n)
        io << "TryExec=" << executable << '\n'
        io << "Icon=" << ICON << '\n'
        io << "Terminal=false\n"
        io << "Categories=Utility;\n"
      end
    end

    # .desktop の言語の札。中国語は簡体と繁体を地域で分け、それ以外は言語だけにする。
    def self.tag(code : String) : String
      steamvr = I18n.steamvr_tag(code)
      steamvr.starts_with?("zh") ? steamvr : steamvr.split('_').first
    end

    # 書き出す。中身が同じなら書かない。変えたら true を返す。
    #
    # 隣へ書いてからリネームで置き換える。Steam が一覧を作る最中に、書きかけのファイルを読ませないためである。
    # 隣のファイルの名前は書き込みごとに変える。`install` と、それが起動した常駐は同時に書きうる。
    # 名前が同じだと、先にリネームした側が相手の書きかけを公開し、後の側のリネームは失敗する。
    # 名前の末尾は .desktop にしないので、Steam は隣のファイルを一覧に入れない。
    def self.write(executable : String, path : String = Paths.desktop_entry_path) : Bool
      expected = content(executable)
      return false if File.exists?(path) && File.read(path) == expected

      Dir.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.#{Random::Secure.hex(4)}.new"
      begin
        File.write(temporary, expected)
        File.rename(temporary, path)
      ensure
        File.delete?(temporary)
      end
      Log.info { ".desktop を書き出した: #{path}" }
      true
    end

    # 消す。無ければ何もしない。消せなければログに残すだけにする。
    def self.delete(path : String = Paths.desktop_entry_path) : Nil
      Log.info { ".desktop を消した: #{path}" } if File.delete?(path)
    rescue exception : File::Error
      Log.warn(exception: exception) { ".desktop を消せなかった: #{path}" }
    end
  end
end

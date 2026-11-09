module Runtime
  # Steam クライアントが残した設定の読み取り。
  #
  # 使うのは表示言語だけである。SteamVR とダッシュボードは Steam の表示言語に従うため、
  # 本ツールの文字列もそれに合わせる。
  module SteamClient
    # Steam は Linux で、Windows のレジストリに当たる値をこのファイルへ書く。
    # 表示言語は Registry / HKCU / Software / Valve / Steam / language にある。
    REGISTRY_PATH = File.join(".steam", "registry.vdf")

    LANGUAGE_PATH = %w[registry hkcu software valve steam language]

    # Steam の表示言語の名前（english、japanese、schinese など）。読めなければ nil。
    def self.language(env = ENV) : String?
      home = env["HOME"]?.presence || return nil
      text = File.read(File.join(home, REGISTRY_PATH))
      language_in(text)
    rescue File::Error | IO::Error
      nil
    end

    # registry.vdf の中身から表示言語を取り出す。
    #
    # VDF は、引用符で囲んだ名前と値、または名前と { } で囲んだ入れ子を並べる形式である。
    # キーの大文字と小文字は区別しない（Steam の書くファイルでも綴りが揺れる）。
    # ここでは入れ子の道筋を数えながら字句を読むだけにし、全体の構造は組み立てない。
    def self.language_in(text : String) : String?
      path = [] of String
      pending = nil.as(String?)
      tokens(text).each do |token|
        case token
        when :open
          path << (pending || "").downcase
          pending = nil
        when :close
          path.pop?
          pending = nil
        when String
          if key = pending
            return token.presence if (path + [key.downcase]) == LANGUAGE_PATH
            pending = nil
          else
            pending = token
          end
        end
      end
      nil
    end

    # 字句の並び。引用符の中の文字列か、:open か :close を返す。
    # 引用符の中では \" と \\ を戻す。// から行末まではコメントとして読み飛ばす。
    private def self.tokens(text : String) : Array(String | Symbol)
      result = [] of String | Symbol
      reader = Char::Reader.new(text)
      while reader.has_next?
        char = reader.current_char
        case char
        when '{'
          result << :open
          reader.next_char
        when '}'
          result << :close
          reader.next_char
        when '"'
          value = String.build do |io|
            reader.next_char
            while reader.has_next? && reader.current_char != '"'
              if reader.current_char == '\\' && reader.has_next?
                reader.next_char
              end
              io << reader.current_char
              reader.next_char
            end
          end
          reader.next_char
          result << value
        when '/'
          reader.next_char
          if reader.current_char == '/'
            while reader.has_next? && reader.current_char != '\n'
              reader.next_char
            end
          end
        else
          reader.next_char
        end
      end
      result
    end
  end
end

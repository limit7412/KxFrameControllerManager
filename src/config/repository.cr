require "json"
require "./models"

module Config
  # 設定ファイルの読み書きを担う境界。
  # 検証と反映は usecase 側にあり、ここはファイルとの往復だけを行う。
  abstract class Repository
    abstract def path : String
    abstract def exists? : Bool
    abstract def load : Root
    abstract def save(root : Root) : Nil
  end

  # 実ファイルに対する Repository 実装。
  class FileRepository < Repository
    getter path : String

    def initialize(@path : String)
    end

    def exists? : Bool
      File.exists?(@path)
    end

    def load : Root
      Root.from_json(File.read(@path))
    end

    def save(root : Root) : Nil
      Dir.mkdir_p(File.dirname(@path))
      # 書き込み中に落ちても設定を失わないよう、一時ファイルへ書いてから置き換える。
      # 同じディレクトリに置くため、置き換えは同じファイルシステム内のリネームで済む。
      temporary = "#{@path}.tmp"
      File.write(temporary, root.to_pretty_json)
      File.rename(temporary, @path)
    end
  end
end

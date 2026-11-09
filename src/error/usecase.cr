require "log"

# 例外の記録。
module Error
  # 例外をログへ落とし、常駐を止めずに先へ進める。
  #
  # ヘッドセットにはトレイも通知先も無いため、知らせる先はログだけである（仕様書 3.5 節）。
  # systemd 下ではログが標準エラーにも出るため、journalctl からも読める。
  class Usecase
    Log = ::Log.for("error")

    # 例外の文脈は辞書のキーで受け取る。
    # ログは開発者が読むものなので言語を固定する。辞書は runtime 側にあり、
    # ここから参照すると層が逆さになるため、解決そのものは composition root から差し込む。
    # 既定はキーを素通しする。差し込む前に例外が出ても、何の文脈かは残る。
    property log_text : Proc(String, String) = ->(key : String) { key }

    def handle(key : String, exception : Exception) : Nil
      Log.error(exception: exception) { @log_text.call(key) }
    end

    # 中断させたくない処理を包む。例外はログに変えて握りつぶす。
    def guard(key : String, & : -> Nil) : Nil
      yield
    rescue exception
      handle(key, exception)
    end
  end
end

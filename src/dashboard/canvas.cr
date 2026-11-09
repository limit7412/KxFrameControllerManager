# 設定画面のコンテキスト。
#
# SteamVR のダッシュボードにタブを 1 つ出し、常駐の状態、手動の切断、設定の変更を扱う。
# 画面は CPU で描いた画素を IVROverlay へ渡す。ブラウザエンジンも GUI ツールキットも持たない。
# 描画は canvas.cr の抽象を通し、実装（cairo.cr）は libcairo を実行時に dlopen して使う。
module Dashboard
  # 色。各成分は 0.0 から 1.0 で表す。
  record Color, r : Float64, g : Float64, b : Float64, a : Float64 = 1.0 do
    def self.hex(value : Int32, a : Float64 = 1.0) : Color
      new(((value >> 16) & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, (value & 0xFF) / 255.0, a)
    end
  end

  # 文字の揃え。x をどこに合わせるか。
  enum Align
    Left
    Center
    Right
  end

  # 描画先の抽象。座標は左上を原点とした画素で、y は下へ増える。
  #
  # 画面の組み立て（view.cr）はこの抽象だけを使う。spec では描いた内容を記録する実装へ差し替える。
  abstract class Canvas
    # 文字に使う書体の名前。同じ漢字でも、言語によって字形の違う書体（JP、SC、TC、KR）を選ぶ。
    property font_family : String = "Noto Sans CJK JP"

    abstract def width : Int32
    abstract def height : Int32

    # 全体を塗る。
    abstract def clear(color : Color) : Nil

    # 角を丸めた四角を塗る。
    abstract def fill_rect(x : Float64, y : Float64, w : Float64, h : Float64, color : Color, radius : Float64 = 0.0) : Nil

    # 角を丸めた四角の枠を描く。
    abstract def stroke_rect(x : Float64, y : Float64, w : Float64, h : Float64, color : Color, radius : Float64 = 0.0, line : Float64 = 2.0) : Nil

    # 線を描く。
    abstract def line(x1 : Float64, y1 : Float64, x2 : Float64, y2 : Float64, color : Color, width : Float64 = 2.0) : Nil

    # 円弧を描く。角度はラジアンで、0 が右、時計回りに増える。
    abstract def arc(cx : Float64, cy : Float64, radius : Float64, from : Float64, to : Float64, color : Color, width : Float64 = 2.0) : Nil

    # 文字を描く。y は文字の縦の中心である。
    abstract def text(x : Float64, y : Float64, text : String, size : Float64, color : Color, bold : Bool = false, align : Align = Align::Left) : Nil

    # 文字を描いたときの幅。折り返しに使う。
    abstract def text_width(text : String, size : Float64, bold : Bool = false) : Float64

    # 描いた内容を、上の行から順に RGBA（1 画素 4 バイト、乗算済みでない値）で返す。IVROverlay が受け取る形である。
    abstract def rgba : Bytes
  end
end

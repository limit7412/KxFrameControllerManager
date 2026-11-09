require "log"
require "./canvas"

module Dashboard
  # libcairo の型。関数は dlsym で解決するため、ここには構造体だけを置く。
  lib LibCairo
    # cairo_text_extents_t
    struct TextExtents
      x_bearing : Float64
      y_bearing : Float64
      width : Float64
      height : Float64
      x_advance : Float64
      y_advance : Float64
    end
  end

  # libcairo を実行時に dlopen して呼ぶ Canvas 実装。
  #
  # 実行ファイルへはリンクしない。動的な依存を glibc だけに保つためである（scripts/verify.sh が検査する）。
  # SteamOS には libcairo と、日本語を含む Noto Sans CJK が入っている
  # （frameeyeosc のパネルと FrameMover が同じものを使っている）。
  # 見つからなければ設定画面を出さないだけで、長押しの切断は続ける。
  class CairoCanvas < Canvas
    Log = ::Log.for("dashboard")

    LIBRARY_NAMES = %w[libcairo.so.2 libcairo.so]

    # 文字に使うフォントの既定。fontconfig が名前から探す。
    # cairo の簡易な文字の API は、1 つのフォントに無い字を別のフォントで補わない。
    # Noto Sans CJK はかな、漢字、ハングル、ラテン文字、キリル文字をすべて持つ。
    # 言語ごとの書体（簡体字なら SC）は、画面が font_family で切り替える。
    FONT_FAMILY = "Noto Sans CJK JP"

    FORMAT_ARGB32      = 0
    FONT_SLANT_NORMAL  = 0
    FONT_WEIGHT_NORMAL = 0
    FONT_WEIGHT_BOLD   = 1

    # libcairo から解決した関数。プロセスで 1 回だけ解決する。
    class Functions
      getter image_surface_create : Proc(Int32, Int32, Int32, Void*)
      getter create : Proc(Void*, Void*)
      getter destroy : Proc(Void*, Nil)
      getter surface_destroy : Proc(Void*, Nil)
      getter surface_flush : Proc(Void*, Nil)
      getter surface_write_to_png : Proc(Void*, UInt8*, Int32)
      getter image_surface_get_data : Proc(Void*, UInt8*)
      getter image_surface_get_stride : Proc(Void*, Int32)
      getter set_source_rgba : Proc(Void*, Float64, Float64, Float64, Float64, Nil)
      getter paint : Proc(Void*, Nil)
      getter new_path : Proc(Void*, Nil)
      getter new_sub_path : Proc(Void*, Nil)
      getter close_path : Proc(Void*, Nil)
      getter move_to : Proc(Void*, Float64, Float64, Nil)
      getter line_to : Proc(Void*, Float64, Float64, Nil)
      getter arc : Proc(Void*, Float64, Float64, Float64, Float64, Float64, Nil)
      getter rectangle : Proc(Void*, Float64, Float64, Float64, Float64, Nil)
      getter fill : Proc(Void*, Nil)
      getter stroke : Proc(Void*, Nil)
      getter set_line_width : Proc(Void*, Float64, Nil)
      getter select_font_face : Proc(Void*, UInt8*, Int32, Int32, Nil)
      getter set_font_size : Proc(Void*, Float64, Nil)
      getter text_extents : Proc(Void*, UInt8*, LibCairo::TextExtents*, Nil)
      getter show_text : Proc(Void*, UInt8*, Nil)

      def initialize(library : Void*)
        @image_surface_create = Proc(Int32, Int32, Int32, Void*).new(Functions.symbol(library, "cairo_image_surface_create"), Pointer(Void).null)
        @create = Proc(Void*, Void*).new(Functions.symbol(library, "cairo_create"), Pointer(Void).null)
        @destroy = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_destroy"), Pointer(Void).null)
        @surface_destroy = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_surface_destroy"), Pointer(Void).null)
        @surface_flush = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_surface_flush"), Pointer(Void).null)
        @surface_write_to_png = Proc(Void*, UInt8*, Int32).new(Functions.symbol(library, "cairo_surface_write_to_png"), Pointer(Void).null)
        @image_surface_get_data = Proc(Void*, UInt8*).new(Functions.symbol(library, "cairo_image_surface_get_data"), Pointer(Void).null)
        @image_surface_get_stride = Proc(Void*, Int32).new(Functions.symbol(library, "cairo_image_surface_get_stride"), Pointer(Void).null)
        @set_source_rgba = Proc(Void*, Float64, Float64, Float64, Float64, Nil).new(Functions.symbol(library, "cairo_set_source_rgba"), Pointer(Void).null)
        @paint = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_paint"), Pointer(Void).null)
        @new_path = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_new_path"), Pointer(Void).null)
        @new_sub_path = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_new_sub_path"), Pointer(Void).null)
        @close_path = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_close_path"), Pointer(Void).null)
        @move_to = Proc(Void*, Float64, Float64, Nil).new(Functions.symbol(library, "cairo_move_to"), Pointer(Void).null)
        @line_to = Proc(Void*, Float64, Float64, Nil).new(Functions.symbol(library, "cairo_line_to"), Pointer(Void).null)
        @arc = Proc(Void*, Float64, Float64, Float64, Float64, Float64, Nil).new(Functions.symbol(library, "cairo_arc"), Pointer(Void).null)
        @rectangle = Proc(Void*, Float64, Float64, Float64, Float64, Nil).new(Functions.symbol(library, "cairo_rectangle"), Pointer(Void).null)
        @fill = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_fill"), Pointer(Void).null)
        @stroke = Proc(Void*, Nil).new(Functions.symbol(library, "cairo_stroke"), Pointer(Void).null)
        @set_line_width = Proc(Void*, Float64, Nil).new(Functions.symbol(library, "cairo_set_line_width"), Pointer(Void).null)
        @select_font_face = Proc(Void*, UInt8*, Int32, Int32, Nil).new(Functions.symbol(library, "cairo_select_font_face"), Pointer(Void).null)
        @set_font_size = Proc(Void*, Float64, Nil).new(Functions.symbol(library, "cairo_set_font_size"), Pointer(Void).null)
        @text_extents = Proc(Void*, UInt8*, LibCairo::TextExtents*, Nil).new(Functions.symbol(library, "cairo_text_extents"), Pointer(Void).null)
        @show_text = Proc(Void*, UInt8*, Nil).new(Functions.symbol(library, "cairo_show_text"), Pointer(Void).null)
      end

      class MissingSymbol < Exception
      end

      def self.symbol(library : Void*, name : String) : Void*
        pointer = LibC.dlsym(library, name)
        raise MissingSymbol.new(name) if pointer.null?
        pointer
      end
    end

    @@functions : Functions? = nil
    @@load_failed = false

    # libcairo を読み込む。読めなければ nil を返し、理由は 1 回だけログに残す。
    def self.functions : Functions?
      return @@functions if @@functions
      return nil if @@load_failed

      LIBRARY_NAMES.each do |name|
        library = LibC.dlopen(name, LibC::RTLD_NOW | LibC::RTLD_LOCAL)
        next if library.null?
        begin
          functions = Functions.new(library)
          @@functions = functions
          Log.info { "#{name} を読み込んだ" }
          return functions
        rescue exception : Functions::MissingSymbol
          Log.error { "#{name} に #{exception.message} が無い" }
          LibC.dlclose(library)
        end
      end
      @@load_failed = true
      Log.error { "libcairo を読み込めなかったため、設定画面を出さない" }
      nil
    end

    # 描画先を作る。libcairo が無ければ nil を返す。
    def self.create(width : Int32, height : Int32) : CairoCanvas?
      functions = self.functions
      return nil unless functions
      new(functions, width, height)
    end

    getter width : Int32
    getter height : Int32

    def initialize(@functions : Functions, @width : Int32, @height : Int32)
      @surface = @functions.image_surface_create.call(FORMAT_ARGB32, @width, @height)
      @context = @functions.create.call(@surface)
    end

    def finalize
      @functions.destroy.call(@context)
      @functions.surface_destroy.call(@surface)
    end

    def clear(color : Color) : Nil
      source(color)
      @functions.paint.call(@context)
    end

    def fill_rect(x : Float64, y : Float64, w : Float64, h : Float64, color : Color, radius : Float64 = 0.0) : Nil
      path(x, y, w, h, radius)
      source(color)
      @functions.fill.call(@context)
    end

    def stroke_rect(x : Float64, y : Float64, w : Float64, h : Float64, color : Color, radius : Float64 = 0.0, line : Float64 = 2.0) : Nil
      # 線の中心を枠の内側へ半分ずらし、塗った四角と同じ外形に収める。
      inset = line / 2
      path(x + inset, y + inset, w - line, h - line, Math.max(radius - inset, 0.0))
      source(color)
      @functions.set_line_width.call(@context, line)
      @functions.stroke.call(@context)
    end

    def line(x1 : Float64, y1 : Float64, x2 : Float64, y2 : Float64, color : Color, width : Float64 = 2.0) : Nil
      @functions.new_path.call(@context)
      @functions.move_to.call(@context, x1, y1)
      @functions.line_to.call(@context, x2, y2)
      source(color)
      @functions.set_line_width.call(@context, width)
      @functions.stroke.call(@context)
    end

    def arc(cx : Float64, cy : Float64, radius : Float64, from : Float64, to : Float64, color : Color, width : Float64 = 2.0) : Nil
      @functions.new_path.call(@context)
      @functions.arc.call(@context, cx, cy, radius, from, to)
      source(color)
      @functions.set_line_width.call(@context, width)
      @functions.stroke.call(@context)
    end

    def text(x : Float64, y : Float64, text : String, size : Float64, color : Color, bold : Bool = false, align : Align = Align::Left) : Nil
      return if text.empty?
      font(size, bold)
      extents = uninitialized LibCairo::TextExtents
      @functions.text_extents.call(@context, text.to_unsafe, pointerof(extents))
      left = case align
             in .left?   then x
             in .center? then x - extents.x_advance / 2
             in .right?  then x - extents.x_advance
             end
      # 縦は字の大きさから中心を決める。字ごとの高さで合わせると、行ごとに位置がずれる。
      baseline = y + size * 0.36
      @functions.new_path.call(@context)
      @functions.move_to.call(@context, left, baseline)
      source(color)
      @functions.show_text.call(@context, text.to_unsafe)
    end

    def text_width(text : String, size : Float64, bold : Bool = false) : Float64
      return 0.0 if text.empty?
      font(size, bold)
      extents = uninitialized LibCairo::TextExtents
      @functions.text_extents.call(@context, text.to_unsafe, pointerof(extents))
      extents.x_advance
    end

    def rgba : Bytes
      @functions.surface_flush.call(@surface)
      data = @functions.image_surface_get_data.call(@surface)
      stride = @functions.image_surface_get_stride.call(@surface)
      pixels = Bytes.new(@width * @height * 4)
      @height.times do |row|
        line_start = data + row * stride
        target = pixels.to_unsafe + row * @width * 4
        @width.times do |column|
          # cairo の ARGB32 は、リトルエンディアンのメモリ上では B、G、R、A の順で、色は乗算済みである。
          b = line_start[column * 4]
          g = line_start[column * 4 + 1]
          r = line_start[column * 4 + 2]
          a = line_start[column * 4 + 3]
          if a != 0 && a != 255
            r = (r.to_u32 * 255 // a).clamp(0, 255).to_u8
            g = (g.to_u32 * 255 // a).clamp(0, 255).to_u8
            b = (b.to_u32 * 255 // a).clamp(0, 255).to_u8
          end
          offset = column * 4
          target[offset] = r
          target[offset + 1] = g
          target[offset + 2] = b
          target[offset + 3] = a
        end
      end
      pixels
    end

    # PNG へ書き出す。実機なしで画面を確かめるために使う。
    def write_png(path : String) : Bool
      @functions.surface_flush.call(@surface)
      @functions.surface_write_to_png.call(@surface, path.to_unsafe) == 0
    end

    private def source(color : Color) : Nil
      @functions.set_source_rgba.call(@context, color.r, color.g, color.b, color.a)
    end

    private def font(size : Float64, bold : Bool) : Nil
      weight = bold ? FONT_WEIGHT_BOLD : FONT_WEIGHT_NORMAL
      @functions.select_font_face.call(@context, font_family.to_unsafe, FONT_SLANT_NORMAL, weight)
      @functions.set_font_size.call(@context, size)
    end

    private def path(x : Float64, y : Float64, w : Float64, h : Float64, radius : Float64) : Nil
      @functions.new_path.call(@context)
      if radius <= 0
        @functions.rectangle.call(@context, x, y, w, h)
        return
      end
      r = Math.min(radius, Math.min(w, h) / 2)
      @functions.new_sub_path.call(@context)
      @functions.arc.call(@context, x + w - r, y + r, r, -Math::PI / 2, 0.0)
      @functions.arc.call(@context, x + w - r, y + h - r, r, 0.0, Math::PI / 2)
      @functions.arc.call(@context, x + r, y + h - r, r, Math::PI / 2, Math::PI)
      @functions.arc.call(@context, x + r, y + r, r, Math::PI, Math::PI * 1.5)
      @functions.close_path.call(@context)
    end
  end
end

# 設定画面（ダッシュボードのタブ）を、全言語、全タブぶん PNG へ描き出す。
#
# 実機なしで、訳した文字列が枠に収まるか、書体に字が揃っているかを確かめるために使う。
# 手元の libcairo と fontconfig を使うため、ヘッドセットと同じ書体（Noto Sans CJK）を入れておく。
# Ubuntu なら fonts-noto-cjk で入る。
#
# 使い方:
#   crystal run scripts/preview_dashboard.cr -- [出力先のディレクトリ]
#
# 出力先を省くと tmp/dashboard-preview に書く。ファイル名は <言語>-<タブ>.png である。
require "file_utils"
require "../src/config/usecase"
require "../src/runtime/i18n"
require "../src/dashboard/cairo"
require "../src/dashboard/view"

output = ARGV.first? || File.join("tmp", "dashboard-preview")
FileUtils.mkdir_p(output)

update = Dashboard::UpdateStatus.new(
  version: "0.2.0",
  last_checked_at: Time.utc(2026, 11, 9, 12, 0, 0),
  last_outcome: "rolled_back",
  last_tag: "0.2.1",
  last_finished_at: Time.utc(2026, 11, 9, 12, 1, 0),
  phase: nil,
  service_installed: true,
  executable: "/home/steamos/.local/bin/kx-frame-controller-manager",
)
snapshot = Dashboard::Snapshot.new(
  steamvr_connected: true,
  left: Dashboard::HandStatus.new(true, "cv.91481bedcdfa", "view"),
  right: Dashboard::HandStatus.new(false, nil, "menu"),
  link_reachable: true,
  power_save_state: "waiting",
  power_save_pending: false,
  gain_range: {0.5, 1.6},
  config_errors: [] of String,
  update: update,
  autostart: true,
)

translate = ->(key : String, vars : Hash(String, String)) { Runtime::I18n.t(key, vars) }
names = Runtime::I18n::CODES.to_h { |code| {code, Runtime::I18n.native_name(code)} }
view = Dashboard::View.new(translate, "0.2.0", names)
root = Config::Root.default
root.input.left_button = "dpad_right"

Runtime::I18n::CODES.each do |code|
  Runtime::I18n.locale = code
  Dashboard::Tab.each do |tab|
    canvas = Dashboard::CairoCanvas.create(Dashboard::View::WIDTH, Dashboard::View::HEIGHT)
    abort "libcairo を読み込めなかった" unless canvas
    state = Dashboard::ViewState.new
    state.tab = tab
    state.snapshot = snapshot
    state.message = Runtime::I18n.t("dashboard.disconnect.no_target")
    state.tone = Dashboard::Tone::Error
    view.render(canvas, state, root)
    path = File.join(output, "#{code}-#{tab.to_s.underscore}.png")
    abort "書き出せなかった: #{path}" unless canvas.write_png(path)
  end
end
puts "#{output} に書き出した"

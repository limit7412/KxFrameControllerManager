#!/usr/bin/env bash
# KxFrameControllerManager の実行ファイルをビルドする（仕様書 6.3 節）。
#
# 手元でも CI でもこのスクリプトを使う。
# 複合アクション（.github/actions/build-linux-aarch64）が持つのは、Crystal と依存ライブラリを
# 用意すること、このスクリプトを呼ぶこと、出来た実行ファイルを検査することだけである。
# 手順を 2 か所に書くと、片方だけ直したときに配布物と手元ビルドが食い違う（KxNotifyUtils の issue #20）。
#
# 前提:
#   - Crystal（PATH に crystal があること）
#   - 静的ライブラリ: libz.a、libssl.a、libcrypto.a、libpcre2-8.a
#     Ubuntu なら zlib1g-dev、libssl-dev、libpcre2-dev で入る
#
# 使い方:
#   scripts/build.sh                        リリースビルド
#   scripts/build.sh --debug                デバッグビルド
#   scripts/build.sh --version 1.2.3        版を埋めてビルドする
#   scripts/build.sh --output path/to/bin   出力先を変える
#
# 版は環境変数 KXFCM_VERSION でも渡せる。--version はそれより優先する。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

output="kx-frame-controller-manager"
debug=false
version="${KXFCM_VERSION:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) debug=true ;;
    --output) output="$2"; shift ;;
    --version) version="$2"; shift ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
  shift
done

# 静的ライブラリだけを置いたディレクトリを作り、リンカの探索の先頭に置く。
#
# 実行ファイルは glibc へ動的にリンクし、それ以外の依存は静的に取り込む（仕様書 6.3 節）。
# libopenvr_api.so を dlopen するため、musl での完全な静的リンクは使えない。
#
# Crystal の --static は glibc ごと静的にしようとするので使えない。
# 代わりにリンカの性質を使う。-l は -L のディレクトリを順に探し、同じディレクトリに .so と .a が
# あれば .so を選ぶが、先のディレクトリに .a しか無ければそこで決まる。
# そのため .a へのリンクだけを集めたディレクトリを先頭に置けば、そのライブラリだけが静的になる。
#
# libgc は Crystal の配布物が .a で持っており、もともと静的に入る。
static_dir="$root/build/static-libs"
rm -rf "$static_dir"
mkdir -p "$static_dir"
for name in z ssl crypto pcre2-8; do
  archive="$(${CC:-cc} -print-file-name="lib${name}.a")"
  # 見つからないとき、-print-file-name は名前をそのまま返す。
  if [ "$archive" = "lib${name}.a" ] || [ ! -f "$archive" ]; then
    echo "lib${name}.a が見つからない。静的ライブラリを入れる必要がある" >&2
    exit 1
  fi
  ln -s "$archive" "$static_dir/lib${name}.a"
done

# -static-libgcc は、例外の巻き戻しに使う libgcc_s.so への依存を外す。
# 外さなくても SteamOS には入っているが、動的な依存を glibc だけに絞ると決めてある。
link_flags="-L$static_dir -static-libgcc"

arguments=(build src/main.cr -o "$output" --link-flags "$link_flags")
if [ "$debug" = false ]; then
  arguments+=(--release --no-debug)
fi

echo "==> 本体をビルドする"
echo "link flags: $link_flags"
if [ -n "$version" ]; then
  echo "版: $version"
fi
KXFCM_VERSION="$version" crystal "${arguments[@]}"

echo "==> 完成: $output"

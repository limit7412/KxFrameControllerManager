#!/usr/bin/env bash
# KxFrameControllerManager をヘッドセットへ入れる（仕様書 6.3 節）。
#
# 実行ファイルを ~/.local/bin へ置き、systemd のユーザーユニットを書き出して起動する。
# sudo は使わず、ホームの外へは何も書かない。
#
# 使い方: 展開したディレクトリで ./install.sh を実行する。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
target="$bin_dir/kx-frame-controller-manager"

mkdir -p "$bin_dir"

# 動いている実行ファイルの上へ直接書くと、Text file busy で失敗する。
# 隣へ置いてからリネームで置き換える。動いているプロセスは古い中身のまま走り、
# 続く install がユニットを起動し直したときに新しい中身へ替わる。
install -m 0755 "$here/kx-frame-controller-manager" "$target.new"
mv -f "$target.new" "$target"

echo "==> $target へ置いた"
exec "$target" install

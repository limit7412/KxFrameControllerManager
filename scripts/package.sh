#!/usr/bin/env bash
# ビルド済みの実行ファイルを配布用の tar.gz にまとめる（仕様書 6.3 節）。
#
# BOOTH ではファイルを 1 つ添えて頒布するため、実行ファイルとライセンス表記をまとめた tar.gz を作る。
# GitHub Releases には実行ファイル単体も引き続き添付する。
# 更新は実行ファイル単体を名前で探すため（src/update/models.cr の ASSET_NAME）、
# tar.gz は別名で並べるだけにして、単体の添付は外さない。
#
# systemd のユーザーユニットは入れない。実行ファイルへ埋め込んであり、install.sh が呼ぶ
# `kx-frame-controller-manager install` が実行ファイルの場所を埋めて書き出す。
# 雛形をそのまま置くと、利用者が手で置いたときに実行ファイルのパスが合わない。
#
# 使い方:
#   scripts/package.sh                                KxFrameControllerManager-dev-linux-aarch64.tar.gz を作る
#   scripts/package.sh --version 1.2.3                KxFrameControllerManager-1.2.3-linux-aarch64.tar.gz を作る
#   scripts/package.sh --executable path/to/binary    中へ入れる実行ファイルを指定する
#
# GitHub Actions の中で動かした場合は、作った tar.gz のパスを出力 path に書く。
# 名前をワークフロー側でも組み立てると、片方だけ直したときに添付が空振りする。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version=""
executable="kx-frame-controller-manager-linux-aarch64"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift ;;
    --executable) executable="$2"; shift ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
  shift
done

# ファイル名に使えない文字が版に入っていると、作成が分かりにくい形で落ちる。
# 版は workflow_dispatch の自由入力からも流れてくるため、ここで弾く。
if [ -n "$version" ] && ! [[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]]; then
  echo "版 '$version' に名前へ使えない文字が含まれている" >&2
  exit 1
fi
label="${version:-dev}"
archive="KxFrameControllerManager-${label}-linux-aarch64.tar.gz"

# 展開先に中身が散らばらないよう、1 つのディレクトリへまとめて入れる。
folder="KxFrameControllerManager"

# 左が tar.gz の中での名前、右がリポジトリ内のパスである。
#
# MIT License は複製にライセンス表記を含めることを求めるため、LICENSE は必ず入れる。
# README.md は入れない。docs/ への相対リンクが展開した先では切れるためである。
entries=(
  "kx-frame-controller-manager=$executable"
  "install.sh=packaging/install.sh"
  "LICENSE.txt=LICENSE"
  "THIRD-PARTY-NOTICES.md=THIRD-PARTY-NOTICES.md"
)

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/$folder"

for entry in "${entries[@]}"; do
  name="${entry%%=*}"
  source="${entry#*=}"
  if [ ! -f "$source" ]; then
    echo "tar.gz に入れる $source が見つからない" >&2
    exit 1
  fi
  cp "$source" "$staging/$folder/$name"
done
chmod 0755 "$staging/$folder/kx-frame-controller-manager" "$staging/$folder/install.sh"
chmod 0644 "$staging/$folder/LICENSE.txt" "$staging/$folder/THIRD-PARTY-NOTICES.md"

echo "==> $archive を作る"
rm -f "$archive"
# 所有者は展開する側の利用者になるよう、数値の 0 で固定して入れる。
tar -C "$staging" --owner=0 --group=0 --numeric-owner -czf "$archive" "$folder"

# 読み直して、入れたつもりのものが入っているかを確かめる。
# 作成に失敗したまま添付すると、BOOTH で購入した人が壊れたものを受け取る。
expected="$(for entry in "${entries[@]}"; do echo "$folder/${entry%%=*}"; done | sort)"
actual="$(tar -tzf "$archive" | grep -v '/$' | sort)"
echo "tar.gz の中身:"
tar -tvzf "$archive" | sed 's/^/  /'
if [ "$expected" != "$actual" ]; then
  echo "tar.gz の中身が想定と一致しない" >&2
  exit 1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "path=$archive" >> "$GITHUB_OUTPUT"
fi

echo "==> 完成: $archive"

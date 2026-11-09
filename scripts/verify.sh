#!/usr/bin/env bash
# ビルドした実行ファイルがヘッドセットで動く形になっているかを確かめる（仕様書 6.3 節）。
#
# どれもビルドは通ってしまう類の誤りであり、手元で動かしても気付けるとは限らない。
# KxNotifyUtils の CI が dumpbin でやっていた検査を、こちらでは readelf と objdump で行う。
#
# 使い方:
#   scripts/verify.sh <実行ファイル> [--arch aarch64] [--glibc 2.39] [--version 1.2.3]
#
# --version を渡すと、実行ファイルが表示する版と突き合わせる。
# 渡さなければ、起動して版を表示できることだけを見る。
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "使い方: $0 <実行ファイル> [--arch aarch64] [--glibc 2.39] [--version 1.2.3]" >&2
  exit 2
fi

binary="$1"
shift
# 名前だけを渡されると、起動の確認で PATH から探してしまう。
case "$binary" in
  */*) ;;
  *) binary="./$binary" ;;
esac
arch=""
# ヘッドセットの glibc（SteamOS 0.4.5 で 2.39）。これより新しい版のシンボルを要求すると起動しない。
glibc_max="2.39"
version=""

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch="$2"; shift ;;
    --glibc) glibc_max="$2"; shift ;;
    --version) version="$2"; shift ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
  shift
done

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

echo "==> CPU を確かめる"
machine="$(readelf -h "$binary" | sed -n 's/^ *Machine: *//p')"
echo "Machine: $machine"
if [ "$arch" = "aarch64" ] && [ "$machine" != "AArch64" ]; then
  echo "aarch64 向けになっていない（$machine）" >&2
  exit 1
fi

echo "==> 動的な依存を確かめる"
# 依存を 1 つも読み取れていないなら、確認そのものが成り立っていない。
# 何も出ていないのを「依存が無い」と読むと、この確認は素通りするだけになる。
needed="$(readelf -d "$binary" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p')"
if [ -z "$needed" ]; then
  readelf -d "$binary"
  echo "readelf の出力から依存ライブラリを読み取れなかった" >&2
  exit 1
fi

# glibc が持つものだけを許す。libopenvr_api.so は dlopen するため、ここには出ない。
# Crystal の依存（libgc、libpcre2、libssl、libcrypto、libz）や libgcc_s が残っていれば、
# scripts/build.sh の静的リンクが効いていない。
allowed='^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|ld-linux-(aarch64|x86-64)\.so\.[12])$'
echo "依存しているライブラリ:"
summary "### 実行ファイルが依存しているライブラリ"
summary ""
unexpected=""
while read -r library; do
  echo "  $library"
  summary "- \`$library\`"
  if ! [[ "$library" =~ $allowed ]]; then
    unexpected="$unexpected $library"
  fi
done <<< "$needed"
if [ -n "$unexpected" ]; then
  echo "glibc 以外のライブラリに依存している:$unexpected" >&2
  exit 1
fi

echo "==> 要求する glibc の版を確かめる"
newest="$(objdump -T "$binary" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)"
if [ -z "$newest" ]; then
  echo "objdump の出力から glibc の版を読み取れなかった" >&2
  exit 1
fi
echo "要求する最も新しい版: GLIBC_$newest（上限 GLIBC_$glibc_max）"
summary ""
summary "要求する glibc: \`GLIBC_$newest\`（上限 \`GLIBC_$glibc_max\`）"
if [ "$(printf '%s\n%s\n' "$newest" "$glibc_max" | sort -V | tail -n 1)" != "$glibc_max" ]; then
  echo "ヘッドセットの glibc（$glibc_max）より新しい版を要求している" >&2
  exit 1
fi

echo "==> 起動して版を表示できることを確かめる"
# CPU が違う環境では動かせないので飛ばす。CI は arm のランナーで動かす。
if [ -z "$arch" ] || [ "$(uname -m)" = "$arch" ]; then
  actual="$("$binary" version)"
  echo "表示した版: $actual"
  if [ -n "$version" ] && [ "$actual" != "$version" ]; then
    echo "表示した版が $version と一致しない" >&2
    exit 1
  fi
else
  echo "この環境（$(uname -m)）では $arch の実行ファイルを動かせないため飛ばす"
fi

echo "==> 検査を通った: $binary"

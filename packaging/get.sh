#!/usr/bin/env bash
# KxFrameControllerManager を 1 行で入れるためのスクリプト。
#
# ヘッドセット（Steam Frame）の端末で、次のように curl から bash へ流して使う。
#
#   curl -fsSL https://raw.githubusercontent.com/limit7412/KxFrameControllerManager/master/packaging/get.sh | bash
#
# GitHub Releases から配布用の tar.gz を取り、展開して中の install.sh を呼ぶ。
# 実行ファイルの配置と systemd のユーザーユニットの登録は install.sh と
# `kx-frame-controller-manager install` が行う。ここでは版を選んで取ってくるところまでを受け持つ。
# 既に入っていれば、置き換えて常駐を起動し直す。更新にもそのまま使える。
#
# sudo は使わず、ホームの外へは何も書かない。
# 作業用のディレクトリも /tmp ではなく ~/.cache の下に作り、終わったら消す。
#
# オプションは bash の後ろへ `-s --` を挟んで渡す。
#
#   ... | bash -s -- --prerelease        プレリリースも含めて最も新しい版を入れる
#   ... | bash -s -- --version 0.1.0     版を指定して入れる
#   ... | bash -s -- --channel test      開発者向け。プレリリースも含めて最も新しい版を入れ、
#                                        以後の自動更新と update でもプレリリースを取る
#
# 途中までしか届かなかったスクリプトが半端に動かないよう、処理は関数に閉じ込め、
# 最後の行で呼ぶ。最後の行が届かなければ何も起きない。
set -euo pipefail

REPOSITORY="limit7412/KxFrameControllerManager"
# 試験のときだけ差し替える。普段は GitHub をそのまま使う。
GITHUB_URL="${KXFCM_GET_GITHUB_URL:-https://github.com}"
API_URL="${KXFCM_GET_API_URL:-https://api.github.com}"

say() { printf '==> %s\n' "$*"; }
fail() { printf 'エラー: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
使い方: get.sh [--prerelease] [--version <版>] [--channel <stable|test>]

  --prerelease          プレリリースも含めて最も新しい版を入れる（入れるのは今回だけ）
  --version <版>        指定した版（タグ名）を入れる
  --channel <stable|test>
                        更新で追うチャンネル（設定 update.channel）を切り替える。
                        test は開発者向けで、--version が無ければプレリリースも含めて最も新しい版を入れ、
                        以後の自動更新と update でもプレリリースを取る
  -h, --help            この説明を出す

何も付けなければ、最も新しい正式リリースを入れる。チャンネルは今の設定のまま変えない。
EOF
}

# 最も新しい正式リリースのタグを返す。
#
# /releases/latest は最新のリリースのページへリダイレクトするため、その行き先からタグを読む。
# API を使わないので、未認証の API の回数制限（1 時間に 60 回）に掛からない。
latest_stable_tag() {
  local location
  location="$(curl -fsSI "$GITHUB_URL/$REPOSITORY/releases/latest" | tr -d '\r' | sed -n 's/^[Ll]ocation: *//p' | tail -n 1)" ||
    fail "最新のリリースを調べられなかった。ネットワークにつながっているか確かめてほしい"
  case "$location" in
    */releases/tag/*) printf '%s\n' "${location##*/releases/tag/}" ;;
    *) fail "正式リリースがまだ出ていない。--prerelease を付けるとプレリリースを入れられる" ;;
  esac
}

# プレリリースを含めて、最も新しいリリースのタグを返す。
#
# 一覧は新しい順に並ぶため、先頭の tag_name を取る。jq は入っているとは限らないため sed で読む。
latest_any_tag() {
  local tag
  tag="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API_URL/repos/$REPOSITORY/releases?per_page=1" |
    sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)" ||
    fail "リリースの一覧を取れなかった。API の回数制限に掛かった場合は、しばらく待つか --version で版を指定してほしい"
  [ -n "$tag" ] || fail "リリースがまだ 1 つも出ていない"
  printf '%s\n' "$tag"
}

main() {
  local version="" prerelease=0 channel=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prerelease) prerelease=1 ;;
      --version)
        [ $# -ge 2 ] || fail "--version には版を続けてほしい"
        version="$2"
        shift
        ;;
      --channel)
        [ $# -ge 2 ] || fail "--channel には stable か test を続けてほしい"
        case "$2" in
          stable | test) channel="$2" ;;
          *) fail "--channel には stable か test を指定してほしい: $2" ;;
        esac
        shift
        ;;
      -h | --help) usage; return 0 ;;
      *) usage >&2; fail "不明な引数: $1" ;;
    esac
    shift
  done

  # 配布しているのは aarch64 の Linux 向けだけである。PC で誤って流したときに、ここで止める。
  [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "aarch64" ] ||
    fail "Steam Frame（aarch64 の Linux）の上で実行してほしい。この端末は $(uname -s) $(uname -m) である"
  # root で入れると、ユニットが root のユーザーマネージャーへ登録され、ログインしている利用者の側で動かない。
  [ "$(id -u)" -ne 0 ] || fail "sudo を付けずに、普段の利用者のまま実行してほしい"
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || fail "HOME が設定されていない"
  local command
  for command in curl tar; do
    command -v "$command" > /dev/null || fail "$command が見つからない"
  done

  if [ -z "$version" ]; then
    # test を追うと決めたなら、入れる版もその基準で選ぶ。正式リリースを入れた直後に
    # プレリリースへ置き換わる二度手間を避ける。
    if [ "$prerelease" -eq 1 ] || [ "$channel" = "test" ]; then
      version="$(latest_any_tag)"
    else
      version="$(latest_stable_tag)"
    fi
  fi
  # 版はタグ名としてそのまま URL とファイル名へ入る。scripts/package.sh と同じ文字だけを通す。
  [[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]] || fail "版 '$version' に使えない文字が含まれている"

  # tar.gz の名前は scripts/package.sh が決めている。タグの先頭の v はリリースのワークフローが落とす。
  local archive="KxFrameControllerManager-${version#v}-linux-aarch64.tar.gz"
  local url="$GITHUB_URL/$REPOSITORY/releases/download/$version/$archive"

  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/KxFrameControllerManager"
  mkdir -p "$cache"
  work="$(mktemp -d "$cache/get.XXXXXX")"
  trap 'rm -rf "$work"' EXIT

  say "$version を取ってくる: $url"
  curl -fL --retry 3 --progress-bar -o "$work/$archive" "$url" ||
    fail "$archive を取れなかった。版 $version に配布用の tar.gz が添付されているか確かめてほしい"

  # 中身の名前を先に確かめる。絶対パスや .. を含むものを展開すると、作業用のディレクトリの外へ書かれる。
  local entries
  entries="$(tar -tzf "$work/$archive")" || fail "$archive を読めなかった。壊れている可能性がある"
  if printf '%s\n' "$entries" | grep -Eq '^/|(^|/)\.\.(/|$)'; then
    fail "$archive に作業用のディレクトリの外を指す名前が含まれている"
  fi
  tar -xzf "$work/$archive" -C "$work"

  local folder="$work/KxFrameControllerManager"
  [ -f "$folder/install.sh" ] && [ -f "$folder/kx-frame-controller-manager" ] ||
    fail "$archive に install.sh か実行ファイルが入っていない。古い版の可能性がある"

  say "install.sh を実行する"
  # 失敗したときは install.sh と systemctl が理由を先に出している。ここでは次の手だけを添える。
  bash "$folder/install.sh" ||
    fail "install.sh が失敗した。systemctl --user が使えない端末では、ヘッドセットのデスクトップの Konsole か ssh で入り直して実行してほしい"

  if [ -n "$channel" ]; then
    say "更新チャンネルを $channel にする"
    # channel コマンドは後から足したものであり、--version で古い版を入れると無い。
    # 版は入っているので失敗にはせず、手で切り替える方法を添える。
    "$HOME/.local/bin/kx-frame-controller-manager" channel "$channel" ||
      printf '警告: チャンネルを切り替えられなかった。この版に channel コマンドが無い場合は、設定ファイル（~/.config/KxFrameControllerManager/config.json）の update.channel を "%s" に書き換えてほしい\n' "$channel" >&2
  fi

  say "入れ終わった。疎通は次で確かめられる"
  printf '    ~/.local/bin/kx-frame-controller-manager status\n'
}

main "$@"

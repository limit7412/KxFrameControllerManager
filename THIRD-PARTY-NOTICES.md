# THIRD-PARTY NOTICES

KxFrameControllerManager は次のソフトウェアを静的リンクまたはコード同梱の形で利用している。
各ライセンスの全文は、それぞれのリポジトリに収録されているものを参照する。

配布用の tar.gz にはこのファイルを同梱する。

## Crystal

- ライセンス: Apache License 2.0
- https://github.com/crystal-lang/crystal

Crystal のランタイムと標準ライブラリを含む。
Crystal 自体が同梱する Boehm GC（MIT 系のライセンス）を併せて含む。

## PCRE2

- ライセンス: BSD License（PCRE2 LICENCE）
- https://github.com/PCRE2Project/pcre2

Crystal の正規表現の実装として静的リンクする。

## OpenSSL

- ライセンス: Apache License 2.0
- https://github.com/openssl/openssl

更新の確認で GitHub と HTTPS で通信するために静的リンクする。

## zlib

- ライセンス: zlib License
- https://github.com/madler/zlib

Crystal の標準ライブラリが圧縮の扱いに用いる。静的リンクする。

## GCC ランタイムライブラリ（libgcc）

- ライセンス: GNU General Public License v3 with GCC Runtime Library Exception
- https://gcc.gnu.org/

例外の巻き戻しに用いる部分を `-static-libgcc` で静的リンクする。
GCC Runtime Library Exception により、本ツールのライセンスはこれに拘束されない。

## OpenVR SDK

- ライセンス: BSD 3-Clause License
- https://github.com/ValveSoftware/openvr

libopenvr_api.so 自体は同梱しない。
SteamVR がインストールしたものを実行時にロードして呼び出す。
本ツールは OpenVR のヘッダに記述された関数テーブルの構造と定数を写したコードを含むため、
その部分について BSD 3-Clause License の表記を掲げる。

## KxNotifyUtils

- ライセンス: MIT License
- https://github.com/limit7412/KxNotifyUtils

設定、ログ、OpenVR 連携、更新、CI とリリースの基盤を流用している。

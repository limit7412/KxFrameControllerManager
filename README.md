# KxFrameControllerManager

KxFrameControllerManager は、Steam Frame のヘッドセット上で常駐し、割り当てたボタンを一定時間押し続けたときにそのコントローラーを切断（電源 OFF 相当）にするツールである。
両方のコントローラーが切れている間は、画面の明るさと描画の質を下げて電池と発熱を抑える。

仕様は [issue #1](https://github.com/limit7412/KxFrameControllerManager/issues/1) にある。
言語、レイヤ構成、設定とログ、OpenVR 連携、更新、CI とリリースは [KxNotifyUtils](https://github.com/limit7412/KxNotifyUtils) の基盤を流用し、Windows 固有の部分を SteamOS（aarch64 Linux）向けに置き換えている。

## 状態

いま入っているのは基盤だけである。
常駐して SteamVR へつなぎ、SteamVR の起動と終了に追従するところまでが動く。
長押しの検出、ヘッドセット内の SteamVR ウェブサーバー（`127.0.0.1:27062`）への切断要求、省電力、CLI の残りのコマンド、systemd のユニットは、これから足す。

## 動作要件

- Steam Frame（SteamOS、aarch64）。Developer Mode を有効にし、ssh で入れること
- SteamVR（動いていない間は何もせずに待つ）

## 置き場所

どれもホームの下に置き、`~` の外には書かない。

| ファイル | 場所 |
| --- | --- |
| 実行ファイル | `~/.local/bin/kx-frame-controller-manager` |
| 設定 | `~/.config/KxFrameControllerManager/config.json` |
| vrmanifest | `~/.local/share/KxFrameControllerManager/` |
| ログ | `~/.local/state/KxFrameControllerManager/logs/` |

## ドキュメント

- [セットアップガイド](docs/setup.md)
- [設定リファレンス](docs/configuration.md)
- [設計](docs/architecture.md)
- [開発ガイド](docs/development.md)

## ライセンス

MIT License。依存するソフトウェアの表記は [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) にある。

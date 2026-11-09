# KxFrameControllerManager

KxFrameControllerManager は、Steam Frame のヘッドセット上で常駐し、割り当てたボタンを一定時間押し続けたときにそのコントローラーを切断（電源 OFF 相当）にするツールである。
両方のコントローラーが切れている間は、画面の明るさと描画の質を下げて電池と発熱を抑える。

仕様は [issue #1](https://github.com/limit7412/KxFrameControllerManager/issues/1) にある。
言語、レイヤ構成、設定とログ、OpenVR 連携、更新、CI とリリースは [KxNotifyUtils](https://github.com/limit7412/KxNotifyUtils) の基盤を流用し、Windows 固有の部分を SteamOS（aarch64 Linux）向けに置き換えている。

## 状態

仕様書 v1 の機能はひととおり入っている。

- SteamVR Input のアクションとして長押しを読み、ヘッドセット内の SteamVR ウェブサーバー（`127.0.0.1:27062`）へ切断要求を送る。既定の割り当ては、左が View、右が Menu の長押しである
- `status`、`list`、`disconnect` で疎通と照合を確かめ、長押しを経ずに切断できる
- systemd のユーザーユニットで常駐する
- 両方が切れている間の省電力は入っているが、実機での確認（仕様書 7.2 節）が済むまで既定で無効にしてある

実機で確かめたのは、27062 への切断要求でコントローラーが切れることまでである（2026-11-09）。
Background アプリから SteamVR Input が読めるか、振動が出るかは、まだ確かめていない。

## 動作要件

- Steam Frame（SteamOS、aarch64）。Developer Mode を有効にし、ssh で入れること
- SteamVR（動いていない間は何もせずに待つ）

## 置き場所

どれもホームの下に置き、`~` の外には書かない。

| ファイル | 場所 |
| --- | --- |
| 実行ファイル | `~/.local/bin/kx-frame-controller-manager` |
| 設定 | `~/.config/KxFrameControllerManager/config.json` |
| vrmanifest とアクションマニフェスト | `~/.local/share/KxFrameControllerManager/` |
| ログ | `~/.local/state/KxFrameControllerManager/logs/` |
| 省電力で変える前の値 | `~/.local/state/KxFrameControllerManager/power_save.json` |
| systemd のユニット | `~/.config/systemd/user/kx-frame-controller-manager.service` |

## ドキュメント

- [セットアップガイド](docs/setup.md)
- [設定リファレンス](docs/configuration.md)
- [設計](docs/architecture.md)
- [開発ガイド](docs/development.md)
- [27062 のメッセージ](docs/protocol-27062.md)

## ライセンス

MIT License。依存するソフトウェアの表記は [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) にある。

# KxFrameControllerManager

日本語 | [English](README.en.md)

KxFrameControllerManager は、Steam Frame のコントローラーをボタンの長押しで切断（電源 OFF 相当）にするツールである。
ヘッドセットの上で常駐し、VR の中から操作できる。
両方のコントローラーが切れている間は、画面の明るさと描画の質を下げて電池と発熱を抑えることもできる（既定では無効）。

## できること

- 左コントローラーの View ボタン、または右コントローラーの Menu ボタンを 2 秒押し続けると、そのコントローラーが切れる
- 切れたコントローラーは、ボタンを押せば再びつながる
- SteamVR のダッシュボードに出る「KxFCM」のタブで、状態の確認、今すぐの切断、ボタンと時間と省電力の設定、更新、表示言語の切り替えができる
- 新しい版を自動で確かめて入れ替える。入れ替えた版が起動しなければ元の版へ戻す

## 動作要件

- Steam Frame（SteamOS）。ヘッドセットの端末でコマンドを打てること
- SteamVR

SteamVR が動いていない間、本ツールは何もせずに待つ。

## 導入

ヘッドセットの端末で次の 1 行を実行する。
端末は、デスクトップモードの Konsole か、Developer Mode を有効にしたうえで PC からの ssh で開ける。

```sh
curl -fsSL https://raw.githubusercontent.com/limit7412/KxFrameControllerManager/master/packaging/get.sh | bash
```

最新の正式リリースを入れて、ログイン中は常に動くように登録し、起動する。
sudo は要らず、ホームの外には何も書かない。

入れ終わったら、SteamVR を動かして左右のコントローラーをつなぎ、次のコマンドで確かめる。

```sh
~/.local/bin/kx-frame-controller-manager status
```

`SteamVR: つながりました`、`27062: 届きました`、左右それぞれの `シリアルが一致しました` が出れば使える。
版を指定して入れる方法や、tar.gz を手で入れる方法は[セットアップガイド](docs/setup.md)にある。

## 使い方

### コントローラーを切る

切りたいコントローラーのボタンを押し続ける。
既定では、左は View ボタン、右は Menu ボタンである。

1. 1 秒で短く 1 回振動する。これは予告であり、ここで離せば切らない
2. 2 秒で短く 2 回振動し、押した側のコントローラーが切れる

切れたコントローラーは、どれかのボタンを押すと再びつながる。

### 設定画面

本ツールが動いていて SteamVR へつながっている間は、SteamVR のダッシュボードの下の並びに「KxFCM」のタブが出る。
タブを開き、コントローラーのポインタで操作する。
変えた設定はその場で保存され、すぐに反映される。

画面の上には状態が出る。

| 項目 | 意味 |
| --- | --- |
| SteamVR | 本ツールが SteamVR へつながっているか |
| 左、右 | 各コントローラーがつながっているか |
| 切断機能 | コントローラーを切る仕組み（SteamVR の中のウェブサーバー）が応えるか。応えなければ、長押しでも画面のボタンでも切れない |
| 省電力 | 省電力を使っているか、省電力中か |

「今すぐ切断」の左、右、両方のボタンでは、長押しをせずに切れる。
誤って触れても切れないよう、2 回押したときだけ動く。1 回目から 4 秒たつと取り消される。

画面には次のタブがある。値は左右の矢印か − と ＋ で 1 段ずつ変える。

| タブ | 変えられること |
| --- | --- |
| 長押し | 長押しで切るかどうか、左右それぞれに使うボタン、切断までの時間、予告の振動までの時間、切断の後に長押しを受け付けない時間、切る範囲（押した側か左右の両方か）、入力の優先度 |
| 振動と省電力 | 予告と切断の前の振動の有無と強さ、省電力の設定 |
| 更新 | 自動更新の有無と確認の間隔。今の版と最後に確認した時刻も見られる |
| 全般 | 表示言語（既定の「自動」は Steam の表示言語に従う）、Frame の起動時に自動で起動するか。本ツールの終了もここから行う |

長押しに使うボタンを変えたときは、ダッシュボードを閉じた後で反映される。
SteamVR のコントローラーバインド画面で KxFrameControllerManager を選んでボタンを割り当てた場合は、そちらが優先される。

### 省電力を使う

省電力は、両方のコントローラーが切れたまま 10 秒たつと、描画の質を下げる機能である。
どちらかのコントローラーがつながれば元に戻る。

既定では無効にしてある。
使うときは「振動と省電力」のタブで「両方が切れたら省電力にする」を ON にする。
画面の明るさも下げたいときは、同じタブの「明るさを下げる」も ON にする。こちらも既定では OFF である。

## 更新

既定では 6 時間ごとに新しい版を確かめ、あれば入れ替えて起動し直す。
入れ替えた版が起動しなければ、元の版へ戻す。

待たずに更新するときは、設定画面の「更新」のタブで「今すぐ更新」を 2 回押す。
新しい版が入ると本ツールが起動し直すため、タブは一度消えてから出直す。
端末からは次のコマンドでも更新できる。導入の 1 行をもう一度実行しても同じである。

```sh
~/.local/bin/kx-frame-controller-manager update
```

自動更新を止めるときは、「更新」のタブで「自動で更新する」を OFF にする。

## 終了と自動起動

本ツールを止めるときは、設定画面の「全般」のタブで「KxFCM を終了」を 2 回押す。
終了するとタブも消える。
次に Frame を起動したときに、本ツールも起動し直す。
すぐに戻すときは、VR のメニューの「プログラムを起動」から「KxFrameControllerManager」を選ぶ。
端末から次のコマンドを実行しても同じである。

```sh
~/.local/bin/kx-frame-controller-manager start
```

Frame の起動時に本ツールを起動させたくないときは、同じタブで「Frame の起動時に自動で起動」を OFF にする。
OFF にしても、動いている本ツールはそのまま動き続ける。
以後は「プログラムを起動」から選んだときか、上の `start` を実行したときだけ動く。
端末からは `autostart on` と `autostart off` で切り替えられ、`autostart` だけなら今の状態を表示する。

## アンインストール

次のコマンドで、常駐と自動更新を止めて登録を消す。

```sh
~/.local/bin/kx-frame-controller-manager uninstall
```

これだけでは実行ファイルと設定は残る。
すべて消すときは、続けて次を実行する。

```sh
rm -f ~/.local/bin/kx-frame-controller-manager ~/.local/bin/kx-frame-controller-manager.old
rm -rf ~/.config/KxFrameControllerManager ~/.local/share/KxFrameControllerManager ~/.local/state/KxFrameControllerManager
```

省電力を使っていた場合は、消す前に `~/.local/state/KxFrameControllerManager/power_save.json` が無いことを確かめる。
このファイルが残っていれば、省電力で変えた明るさと描画の設定がまだ戻っていない。
SteamVR を動かした状態で本ツールを一度起動すると戻る。

## 困ったとき

まず `status` を実行し、どこで止まっているかを見る。

```sh
~/.local/bin/kx-frame-controller-manager status
```

- **`SteamVR: つながりません` と出る**：SteamVR が動いているかを確かめる。動いていれば、[セットアップガイドの「うまく動かないとき」](docs/setup.md#うまく動かないとき)を見る
- **`27062: 届きません`（設定画面では「切断機能: 使えません」）と出る**：SteamVR の中のコントローラーを切る仕組みが応えていない。SteamVR を起動し直して、もう一度試す。SteamVR の更新で使えなくなった可能性もある
- **シリアルが一致しない**：その手は安全のため長押ししても切らない。コントローラーをつなぎ直してから、もう一度 `status` を見る
- **ゲーム中だけ長押しが効かない**：ゲームが入力を取っている可能性がある。「長押し」のタブで「入力の優先度」を「最優先」にし、SteamVR の「Experimental overlay input overrides」を有効にする。この場合、割り当てたボタンはゲームの中では効かなくなる
- **「KxFCM」のタブが出ない**：本ツールが動いているかを `systemctl --user status kx-frame-controller-manager` で確かめる。動いていなければ `~/.local/bin/kx-frame-controller-manager start` で起動する

ログは `journalctl --user -u kx-frame-controller-manager` で見られる。
`~/.local/state/KxFrameControllerManager/logs/` にも日ごとに残る。
解決しないときは、ログを添えて [GitHub の issue](https://github.com/limit7412/KxFrameControllerManager/issues) で知らせてほしい。

## ドキュメント

- [セットアップガイド](docs/setup.md)：導入の詳細、ファイルの置き場所、常駐の管理
- [設定リファレンス](docs/configuration.md)：設定ファイルの全項目
- [開発状況](docs/status.md)：実装済みの機能と、実機で確かめたこと・まだ確かめていないこと
- [設計](docs/architecture.md)
- [開発ガイド](docs/development.md)
- [27062 のメッセージ](docs/protocol-27062.md)

## ライセンス

MIT License。依存するソフトウェアの表記は [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) にある。

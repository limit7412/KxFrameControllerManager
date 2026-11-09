# セットアップガイド

ヘッドセット（Steam Frame）へ入れて、長押しでコントローラーを切断できるようにするまでの手順である。
sudo は使わず、ホームの外へは何も書かない。

## 1. ヘッドセットへ入る

Steam Frame の設定で Developer Mode を有効にし、PC から ssh で入る。

## 2. 入れる

[Releases](https://github.com/limit7412/KxFrameControllerManager/releases) から `KxFrameControllerManager-<版>-linux-aarch64.tar.gz` を取り、ヘッドセットへ送って展開する。

```sh
tar -xzf KxFrameControllerManager-<版>-linux-aarch64.tar.gz
cd KxFrameControllerManager
./install.sh
```

`install.sh` は実行ファイルを `~/.local/bin/kx-frame-controller-manager` へ置き、`kx-frame-controller-manager install` を呼ぶ。
`install` は systemd のユーザーユニットを `~/.config/systemd/user/` へ書き出し、有効にして起動する。
ログインしている間は常駐し、SteamVR が動いていなければ何もせずに待つ。

## 3. 疎通を確かめる

SteamVR を動かし、左右のコントローラーをつないだ状態で `status` を実行する。

```sh
~/.local/bin/kx-frame-controller-manager status
```

`SteamVR: つながりました`、`27062: 届きました`、左右それぞれの `シリアルが一致しました` が出れば、長押しで切断できる。
一致しない手は、安全のため長押ししても切らない。

長押しを経ずに切断して確かめることもできる。

```sh
~/.local/bin/kx-frame-controller-manager disconnect left
```

切れたコントローラーは、ボタンを押すと再びつながる。

## 4. 使う

左コントローラーの View ボタン、または右コントローラーの Menu ボタンを押し続ける。

1. 1 秒で短く 1 回振動する（予告）。ここで離せば中止できる
2. 2 秒で短く 2 回振動し、押した側のコントローラーが切れる

時間と切る範囲は設定（[設定リファレンス](configuration.md)の `power_off`）で変えられる。
割り当てるボタンは、SteamVR のコントローラーバインド画面で KxFrameControllerManager を選んで変える。

## 常駐の管理

```sh
systemctl --user status kx-frame-controller-manager   # 状態
systemctl --user reload kx-frame-controller-manager   # 設定を読み直す（SIGHUP）
systemctl --user restart kx-frame-controller-manager  # 起動し直す
journalctl --user -u kx-frame-controller-manager      # ログ
```

ログは `~/.local/state/KxFrameControllerManager/logs/` にも日ごとに残る。

## 更新と削除

```sh
~/.local/bin/kx-frame-controller-manager update     # 新しい版があれば置き換えて起動し直す
~/.local/bin/kx-frame-controller-manager uninstall  # ユニットを止めて消す
```

`uninstall` は実行ファイルと設定を消さない。
すべて消すときは、続けて次を消す。

```sh
rm -f ~/.local/bin/kx-frame-controller-manager
rm -rf ~/.config/KxFrameControllerManager ~/.local/share/KxFrameControllerManager ~/.local/state/KxFrameControllerManager
```

省電力を使っていた場合は、`~/.local/state/KxFrameControllerManager/power_save.json` が残っていないことを先に確かめる。
残っていれば、省電力で変えた明るさと描画のプロファイルがまだ戻っていない。
SteamVR を動かした状態で常駐を一度起動すると戻る。

## うまく動かないとき

`status` で `SteamVR: つながりません` と出るときは、SteamVR が動いていないか、SteamVR のライブラリが既定の場所（`/opt/steamvr/bin/linuxarm64/libopenvr_api.so`）に無い。
後者なら設定の `steamvr.openvr_library_path` に実際の場所を書く。

`27062: 届きません` と出るときは、SteamVR のウェブサーバーが応えていない。
SteamVR の更新でプロトコルが変わった可能性もある。`log_level` を `debug` にすると、送受信したバイト列がログに出る。

```json
{ "log_level": "debug" }
```

ゲーム中に長押しが効かないときは、ゲームが入力を取っている可能性がある。
設定の `input.priority` を `overlay_global` にし、SteamVR の「Experimental overlay input overrides」を有効にする。
この場合、割り当てたボタンはゲーム側で効かなくなる。

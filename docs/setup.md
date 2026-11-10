# セットアップガイド

ヘッドセット（Steam Frame）へ入れて、長押しでコントローラーを切断できるようにするまでの手順である。
sudo は使わず、ホームの外へは何も書かない。

## 1. ヘッドセットの端末を開く

以降のコマンドは、どれもヘッドセットの上で実行する。
端末は次のどちらかで開ける。

- ヘッドセットでデスクトップモードへ切り替え、Konsole を起動する
- Steam Frame の設定で Developer Mode を有効にし、PC から ssh で入る

[sdev](https://github.com/neguse/sdev) の `sdev shell <IP> '<コマンド>'` でも同じコマンドを流せる。
ただし、この経路で `systemctl --user` が使えるかはまだ確かめていない。
導入の最後で systemd への登録が失敗したときは、上のどちらかで入り直して実行する。

## 2. 入れる

次の 1 行で入れる。

```sh
curl -fsSL https://raw.githubusercontent.com/limit7412/KxFrameControllerManager/master/packaging/get.sh | bash
```

このスクリプト（`packaging/get.sh`）は、次の順に進む。

1. この端末が aarch64 の Linux で、root でないことを確かめる
2. [Releases](https://github.com/limit7412/KxFrameControllerManager/releases) から最新の正式リリースを選び、`KxFrameControllerManager-<版>-linux-aarch64.tar.gz` を `~/.cache/KxFrameControllerManager/` の下へ取ってくる
3. 展開して中の `install.sh` を実行し、終わったら作業用のディレクトリを消す

`install.sh` は実行ファイルを `~/.local/bin/kx-frame-controller-manager` へ置き、`kx-frame-controller-manager install` を呼ぶ。
`install` は systemd のユーザーユニットと自動更新のタイマーを `~/.config/systemd/user/` へ書き出し、有効にして起動する。
ログインしている間は常駐し、SteamVR が動いていなければ何もせずに待つ。

最新の正式リリースが選ばれるのは、GitHub の `/releases/latest` が正式リリースだけを指すためである。
プレリリースを入れるときと、版を指定するときは、オプションを `bash -s --` の後ろに書く。

```sh
curl -fsSL https://raw.githubusercontent.com/limit7412/KxFrameControllerManager/master/packaging/get.sh | bash -s -- --prerelease
curl -fsSL https://raw.githubusercontent.com/limit7412/KxFrameControllerManager/master/packaging/get.sh | bash -s -- --version 0.1.0
```

`--prerelease` が選ぶのは今回入れる版だけであり、以後の自動更新と `update` は設定の `update.channel` に従う。
既定の `stable` のままなら、入れたプレリリースは次の正式リリースで置き換わる。

開発者として以後もプレリリースを追うときは、`--channel test` を付ける。
プレリリースを含めて最も新しい版を入れたうえで、`update.channel` を `test` に切り替える。
`--channel stable` を付ければ `stable` へ戻せる。
何も付けなければ、チャンネルは今の設定のまま変えない。

```sh
curl -fsSL https://raw.githubusercontent.com/limit7412/KxFrameControllerManager/master/packaging/get.sh | bash -s -- --channel test
```

入れた後に切り替えるときは `kx-frame-controller-manager channel test` を使う（[設定リファレンス](configuration.md#リリースチャンネル)）。

### tar.gz を手で入れる

スクリプトを流したくないときは、tar.gz を Releases から取り、ヘッドセットへ送って展開する。

```sh
tar -xzf KxFrameControllerManager-<版>-linux-aarch64.tar.gz
cd KxFrameControllerManager
./install.sh
```

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
割り当てるボタンは、設定画面で変えるか、SteamVR のコントローラーバインド画面で KxFrameControllerManager を選んで変える。

## 設定画面

常駐が SteamVR へつながっている間は、SteamVR のダッシュボードの下の並びに「KxFCM」のタブが出る。
タブを開くと設定画面が出て、コントローラーのポインタで操作する。

画面では次のことができる。

- 常駐の状態を見る（SteamVR、左右のコントローラー、切断機能、省電力）
- 左右のコントローラーを今すぐ切断する。誤って触れないよう、ボタンは 2 回押しで動く。1 回目から 4 秒たつと取り消される
- 長押しに使うボタン、時間、切る範囲、振動、省電力を、左右の矢印か − と ＋ で 1 段ずつ変える
- 「更新」のタブで、自動更新の有無と確認の間隔を変え、今の版、最後に確認した時刻、更新の進み具合と最後の結末（元の版へ戻したことを含む）を見る
- 「更新を確認」で新しい版があるかだけを見る。「今すぐ更新」（2 回押し）で、間隔を待たずに更新する

状態の「切断機能」は、ヘッドセット内の SteamVR ウェブサーバー（`127.0.0.1:27062`）へ届くかを表す。
本ツールはこのサーバーへ切断要求を送ってコントローラーを切るため、届かない間は長押しでも画面のボタンでも切断できない。
確かめるのは SteamVR へつながるたびに 1 回で、表示はそのときの結果である。「使えません」と出ていても、切断の直前にはもう一度試す。まだ確かめていなければ「未確認」と出る。
CLI の `status` では、同じ結果が `27062: 届きました` または `27062: 届きません` と出る。

「今すぐ更新」は、手で `update` を打ったときと同じ流れで置き換え、起動を確かめ、起動しなければ戻す。
新しい版を入れると常駐が再起動するため、タブは一度消えて、新しい版で出直す。
常駐を `install` で systemd のユニットとして入れていなければ、このボタンは押せない。

変えるたびに設定ファイルへ書き、すぐに反映する。
誤りがあれば保存せず、何が誤りかを画面に出す。

長押しのボタンを変えたときは、ダッシュボードを閉じた後で本ツールが SteamVR への接続を張り直し、新しい割り当てを読ませる。
SteamVR そのものは再起動しない。

画面は libcairo で描く。SteamOS には入っているが、見つからなければタブを出さずに常駐を続ける。
タブが要らなければ設定 `dashboard.enabled` を `false` にする。

## 常駐の管理

```sh
systemctl --user status kx-frame-controller-manager   # 状態
systemctl --user reload kx-frame-controller-manager   # 設定を読み直す（SIGHUP）
systemctl --user restart kx-frame-controller-manager  # 起動し直す
journalctl --user -u kx-frame-controller-manager      # ログ
```

ログは `~/.local/state/KxFrameControllerManager/logs/` にも日ごとに残る。

## 更新と削除

新しい版は、既定では 6 時間ごとに自動で確かめて置き換える。
置き換えた版が起動しなければ、元の版へ戻す。
間隔の変え方と止め方は[設定リファレンス](configuration.md)の `update` にある。

```sh
~/.local/bin/kx-frame-controller-manager update     # 待たずに確かめ、新しい版があれば置き換えて起動し直す
~/.local/bin/kx-frame-controller-manager uninstall  # ユニットとタイマーを止めて消す
```

導入の 1 行をもう一度実行しても、最新の版へ置き換えて起動し直す。

`uninstall` は実行ファイルと設定を消さない。
すべて消すときは、続けて次を消す。

```sh
rm -f ~/.local/bin/kx-frame-controller-manager ~/.local/bin/kx-frame-controller-manager.old
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

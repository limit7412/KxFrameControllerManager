# セットアップガイド

いまの版は基盤だけであり、常駐して SteamVR へつなぐところまでを確かめるためのものである。
systemd のユニットと `install.sh` はまだ無いため、手で置いて手で起動する。

## 1. ヘッドセットへ入る

Steam Frame の設定で Developer Mode を有効にし、PC から ssh で入る。

## 2. 実行ファイルを置く

[Releases](https://github.com/limit7412/KxFrameControllerManager/releases) から `KxFrameControllerManager-<版>-linux-aarch64.tar.gz` を取り、ヘッドセットへ送って展開する。

```sh
tar -xzf KxFrameControllerManager-<版>-linux-aarch64.tar.gz
mkdir -p ~/.local/bin
cp KxFrameControllerManager/kx-frame-controller-manager ~/.local/bin/
```

sudo は使わない。ホームの外へは何も書かない。

## 3. 起動する

```sh
~/.local/bin/kx-frame-controller-manager version
~/.local/bin/kx-frame-controller-manager run
```

`run` は常駐し、ログを標準エラーと `~/.local/state/KxFrameControllerManager/logs/` へ書く。
初回は `~/.config/KxFrameControllerManager/config.json` に既定値の設定を書き出す。

SteamVR が動いていれば `OpenVR を初期化した` と `vrmanifest を登録した` が出る。
動いていなければ何も出さずに待ち、`steamvr.retry_interval_s`（既定 10 秒）ごとにつなぎ直す。
SteamVR を終了すると `SteamVR の終了を検知したため OpenVR を閉じた` が出て、再び待つ状態へ戻る。

止めるときは Ctrl+C か `kill`（SIGTERM）を送る。
設定を書き換えたときは SIGHUP を送ると読み直す。

```sh
kill -HUP "$(pgrep -f 'kx-frame-controller-manager run')"
```

## うまく動かないとき

`libopenvr_api.so をロードした` が出ないときは、SteamVR のライブラリが既定の場所（`/opt/steamvr/bin/linuxarm64/libopenvr_api.so`）に無い。
設定の `steamvr.openvr_library_path` に実際の場所を書く。

ログの水準を上げると、つながらない理由が `debug` で出る。

```json
{ "log_level": "debug" }
```

# 設定リファレンス

設定ファイルは `$XDG_CONFIG_HOME/KxFrameControllerManager/config.json`（既定は `~/.config/KxFrameControllerManager/config.json`）に置く。
形式は JSON で、書かれていないキーは既定値で埋める。
初回の起動で、全項目を既定値で書き出す。

書き換えたあとは SIGHUP を送ると読み直す。
不正な内容なら直前の設定で動作を続け、何が不正かをログに残す。
起動時に不正だったときは既定値で動き、ファイルは書き戻さない。利用者が直せるよう、そのまま残しておく。

CLI のコマンド（`status`、`disconnect` など）も同じファイルを読む。
CLI は設定ファイルを書き出さず、無いときや不正なときは既定値で動く。

## 全体の構成

```json
{
  "power_off": {
    "enabled": true,
    "target": "pressed",
    "hold_ms": 2000,
    "warn_ms": 1000,
    "cooldown_ms": 3000,
    "confirm_timeout_ms": 3000
  },
  "power_save": {
    "enabled": false,
    "delay_s": 10,
    "brightness": true,
    "brightness_gain": null,
    "performance_profile": true
  },
  "input": {
    "priority": "normal",
    "poll_interval_ms": 20
  },
  "feedback": {
    "haptics": true,
    "amplitude": 0.5
  },
  "steamvr": {
    "openvr_library_path": "",
    "retry_interval_s": 10
  },
  "frame_link": {
    "port": 27062
  },
  "update": {
    "check_enabled": true,
    "channel": "stable",
    "auto_update": true,
    "check_interval_h": 6
  },
  "log_level": "info",
  "language": "auto"
}
```

## power_off

長押しで切断する機能の設定（仕様書 3.2 節から 3.4 節）。

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `enabled` | `true` | | 長押しでの切断を使うか |
| `target` | `"pressed"` | `pressed` / `both` | 押した側だけを切るか、左右の両方を切るか |
| `hold_ms` | `2000` | 500 から 10000 | 押し始めてから切断するまでのミリ秒 |
| `warn_ms` | `1000` | 0 以上、`hold_ms` 未満 | 押し始めてから予告の振動を出すまでのミリ秒 |
| `cooldown_ms` | `3000` | 0 から 60000 | 切断の後、次の判定を始めるまでのミリ秒 |
| `confirm_timeout_ms` | `3000` | 100 から 30000 | 切断要求を送ってから、切れたことを確かめるまで待つミリ秒 |

`hold_ms` と `warn_ms` の差は 500 以上にする。
予告の振動を感じてから離すまでの猶予であり、これより短いと中止が間に合わない（仕様書 7.1 節）。

切断の前には、OpenVR のシリアルから先頭の `cv.` を外した値が 27062 の接続中の一覧にあるかを確かめる。
無いとき、または 27062 が報告する左右と食い違うときは切らない。
切れたことは、OpenVR の `VREvent_TrackedDeviceDeactivated` か、27062 の一覧から消えたことで確かめる。
`confirm_timeout_ms` のうちに確かめられなければ 1 回だけ送り直す。

## power_save

両方のコントローラーが切れている間の省電力（仕様書 3.8 節）。
実機での確認が済むまでは既定で無効にしてある。

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `enabled` | `false` | | 省電力を使うか |
| `delay_s` | `10` | 0 から 600 | 両方が切れてから省電力へ入るまでの秒数 |
| `brightness` | `true` | | 明るさ（`steamvr/analogGain`）を下げるか |
| `brightness_gain` | `null` | null か正の数 | 省電力中の明るさ。null なら HMD の最小値を使う。数値は HMD の範囲へ収めて使う |
| `performance_profile` | `true` | | 描画のプロファイル（`steamvr/performanceProfile`）を省電力のものへ切り替えるか |

省電力へ入る条件は、OpenVR で左右のどちらもつながっていない状態が `delay_s` 秒続くことである。
入る直前に 27062 の一覧を取り、接続中のものがあれば入らずに待ち直す。一覧を取れなければ OpenVR の判定だけで入る。

描画のプロファイルは、`steamvr/powersaveSteamOSManagerCustomProfile` に入っている名前へ切り替える。
明るさは、既に省電力の値より暗ければ変えない。

変える前の値は `~/.local/state/KxFrameControllerManager/power_save.json` に書いてから変える。
どちらかのコントローラーがつながったとき、省電力を無効にしたとき、常駐を止めたとき、SteamVR が終了するときに、このファイルの値へ戻して消す。
戻せずに終わったときはファイルが残り、次に常駐が SteamVR へつながったときに戻す。
元が未設定だったキーは、値を書き戻さずにキーを消す。

## input

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `priority` | `"normal"` | `normal` / `overlay_global` | SteamVR Input のアクションセットの優先度（仕様書 3.1 節） |
| `poll_interval_ms` | `20` | 1 から 100 | 主ループの周期。入力の状態を読む間隔でもある |

`overlay_global` は他のアプリがフォーカス中でも読めるが、SteamVR の「Experimental overlay input overrides」が要り、割り当てたボタンはゲーム側で効かなくなる。

ボタンの割り当ては設定ファイルでは持たない。
SteamVR のコントローラーバインド画面で KxFrameControllerManager を選び、「このコントローラーを切断（長押し）」を好きなボタンへ割り当てる。
既定は左が View、右が Menu である。

## feedback

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `haptics` | `true` | | 予告と切断の直前に振動させるか |
| `amplitude` | `0.5` | 0.0 から 1.0 | 振動の強さ |

## steamvr

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `openvr_library_path` | `""` | | `libopenvr_api.so` の場所。空なら既定の場所を探す |
| `retry_interval_s` | `10` | 1 から 600 | SteamVR が動いていない間に、つなぎ直す間隔 |

`openvr_library_path` が空のときは、次の順に探す。

1. `/opt/steamvr/bin/linuxarm64/libopenvr_api.so`（Steam Frame の SteamOS の場所）
2. `~/.config/openvr/openvrpaths.vrpath` の `runtime` に書かれた各ディレクトリの `bin/linuxarm64/libopenvr_api.so`

場所を指定したときは、そこだけを見る。
指定した場所に無いときに別の場所のものを黙って使うと、どれを読んだのかが分からなくなるためである。

## frame_link

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `port` | `27062` | 1 から 65535 | ヘッドセット内の SteamVR ウェブサーバーのポート |

## update

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `check_enabled` | `true` | | 新しい版を探すか。偽なら自動更新も止まる |
| `channel` | `"stable"` | `stable` / `test` | `stable` は安定版だけを、`test` はプレリリースも見る。自動更新と `update` コマンドの両方に効く |
| `auto_update` | `true` | | 新しい版を見つけたら、自動で置き換えて常駐を起動し直すか。偽なら、常駐の起動時に見つけた版をログに残すだけにする。自動更新のタイマーが無い環境（自動更新より前の版から `update` で上げた場合）でも同じくログに残し、`install` のやり直しを促す |
| `check_interval_h` | `6` | 1 から 168 | 自動更新が新しい版を探す間隔（時間） |

### 自動更新の流れ

自動更新は、`install` が書き出す systemd のタイマー（`kx-frame-controller-manager-update.timer`）が受け持つ。
タイマーは 30 分ごとに `update --auto` を起こし、前回の確認から `check_interval_h` が経っていれば次のとおり進める。

1. GitHub Releases から `channel` に合う最新の版を探す
2. 新しければ実行ファイルを `~/.local/bin/kx-frame-controller-manager.new` へ取り、digest と照合する
3. 取ったものを `version` で試しに起動し、その版を名乗ることを確かめる。ヘッドセットで起動できない添付（glibc の版やアーキテクチャの誤り）はここで落ちる
4. 今の実行ファイルを `kx-frame-controller-manager.old` へ残してから置き換える
5. 常駐が動いていれば再起動し、新しい版が 60 秒以内に起動の印（`~/.local/state/KxFrameControllerManager/running.json`）を残すこと、その後 20 秒落ちずに動き続けることを確かめる
6. 確かめられなければ `.old` へ戻して再起動し、その版を `~/.local/state/KxFrameControllerManager/update.json` に覚える。覚えた版は自動では二度と入れない

手で `update` を実行したときも同じ流れで置き換え、起動を確かめ、起動しなければ戻す。
手で実行したときは `auto_update` と `check_interval_h` を見ず、自動更新が覚えた版も入れる。
利用者が明示的に入れようとしているためである。

間隔の判定を実行ファイルの側に置いたのは、`check_interval_h` を変えるたびにタイマーを書き換えずに済むようにするためである。
設定を変えた後は、`systemctl --user reload` も `install` のやり直しも要らない。次にタイマーが起きたときに読まれる。

自動更新の記録は次で読める。

```sh
systemctl --user list-timers kx-frame-controller-manager-update.timer
journalctl --user -u kx-frame-controller-manager-update
```

## 全般

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `log_level` | `"info"` | `trace` / `debug` / `info` / `notice` / `warn` / `error` / `fatal` / `none` | ログの水準 |
| `language` | `"auto"` | `auto` / `ja` / `en` | CLI の表示言語。`auto` は環境変数 `LC_ALL`、`LC_MESSAGES`、`LANG` の順に見て、日本語なら `ja`、それ以外は `en` にする |

ログそのものは `language` に依らず日本語で書く。開発者が読み比べるためである。

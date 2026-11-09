# 設定リファレンス

設定ファイルは `$XDG_CONFIG_HOME/KxFrameControllerManager/config.json`（既定は `~/.config/KxFrameControllerManager/config.json`）に置く。
形式は JSON で、書かれていないキーは既定値で埋める。
初回の起動で、全項目を既定値で書き出す。

書き換えたあとは SIGHUP を送ると読み直す。
不正な内容なら直前の設定で動作を続け、何が不正かをログに残す。
起動時に不正だったときは既定値で動き、ファイルは書き戻さない。利用者が直せるよう、そのまま残しておく。

いまの版が実際に使うのは `steamvr`、`input.poll_interval_ms`、`log_level`、`language` だけである。
残りは長押し、切断、省電力、更新を足すときに使う。値の検証はいまの版でも行う。

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
    "channel": "stable"
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

## input

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `priority` | `"normal"` | `normal` / `overlay_global` | SteamVR Input のアクションセットの優先度（仕様書 3.1 節） |
| `poll_interval_ms` | `20` | 1 から 100 | 主ループの周期。入力の状態を読む間隔でもある |

`overlay_global` は他のアプリがフォーカス中でも読めるが、SteamVR の「Experimental overlay input overrides」が要り、割り当てたボタンはゲーム側で効かなくなる。

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
| `check_enabled` | `true` | | 更新を確認するか |
| `channel` | `"stable"` | `stable` / `test` | `stable` は安定版だけを、`test` はプレリリースも見る |

## 全般

| キー | 既定 | 範囲 | 意味 |
| --- | --- | --- | --- |
| `log_level` | `"info"` | `trace` / `debug` / `info` / `notice` / `warn` / `error` / `fatal` / `none` | ログの水準 |
| `language` | `"auto"` | `auto` / `ja` / `en` | CLI の表示言語。`auto` は環境変数 `LC_ALL`、`LC_MESSAGES`、`LANG` の順に見て、日本語なら `ja`、それ以外は `en` にする |

ログそのものは `language` に依らず日本語で書く。開発者が読み比べるためである。

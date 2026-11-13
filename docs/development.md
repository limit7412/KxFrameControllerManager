# 開発ガイド

## 必要なもの

- Crystal 1.21.0（aarch64 のビルドには aarch64 Linux 版）
- 静的ライブラリ：`libz.a`、`libssl.a`、`libcrypto.a`、`libpcre2-8.a`
  - Ubuntu なら `sudo apt-get install zlib1g-dev libssl-dev libpcre2-dev`

依存する shard は無い。`shards install` は要らない。

## ビルド

```sh
scripts/build.sh                       # リリースビルド。kx-frame-controller-manager ができる
scripts/build.sh --debug               # デバッグビルド
scripts/build.sh --version 1.2.3       # 版を埋める
```

CI とリリースも同じスクリプトを呼ぶ。
複合アクション（`.github/actions/build-linux-aarch64`）が持つのは、Crystal と静的ライブラリを用意すること、これを呼ぶこと、出来た実行ファイルを検査することだけである。
手順を 2 か所に書くと、片方だけ直したときに配布物と手元ビルドが食い違い、しかも手元では再現しないため気付けない（KxNotifyUtils の issue #20）。

実行ファイルは glibc へ動的にリンクし、それ以外の依存は静的に取り込む（仕様書 6.3 節）。
`libopenvr_api.so` を `dlopen` するため、musl での完全な静的リンクは使えない。
ヘッドセットの glibc は 2.39（SteamOS 0.4.5）であり、ビルドに使う Ubuntu 24.04 の glibc も 2.39 である。

## 検査

```sh
scripts/verify.sh kx-frame-controller-manager
scripts/verify.sh kx-frame-controller-manager-linux-aarch64 --arch aarch64 --glibc 2.39 --version 1.2.3
```

次の 3 つを見る。どれもビルドは通ってしまう類の誤りである。

- 動的な依存が glibc の持つものだけか。`readelf -d` の `NEEDED` を見る。libgc や libssl が残っていれば、静的リンクが効いていない
- 要求する glibc の版がヘッドセットを超えないか。`objdump -T` のシンボルの版を見る。ビルドに使うランナーを新しい版へ上げると、ここで落ちる
- 起動して、埋めた版を表示できるか

## バージョンとリリース

版の source of truth はタグである。
`src/main.cr` の `VERSION` は環境変数 `KXFCM_VERSION` から読み、渡さなければ `0.1.0-dev` になる。

タグは `X.Y.Z` を安定版、`X.Y.Z-testN` をプレリリースとする。

### プレリリース（自動）

`master` へ取り込むと `.github/workflows/prerelease.yml` が動く。
最新の安定版タグからパッチを 1 つ上げた `X.Y.(Z+1)` を次期バージョンとし、`-testN` の N を進めてタグを打ち、実行ファイルを添えたプレリリースを作る。
安定版のタグがまだ無いうちは 0.0.0 を起点にし、`0.0.1-testN` を作る。

配布物の中身が変わらない変更（spec、ドキュメント、ワークフロー自身）では作らない。
判定しているパスの一覧はワークフロー内のコメントにある。

マイナーやメジャーを上げたいプレリリースは手動で作る。

### 安定版リリース（手動）

GitHub でタグ `X.Y.Z` のリリースを作って公開すると、`.github/workflows/release.yml` が実行ファイルをビルドして添付する。

### 添付物

リリースとプレリリースには次の 2 つを添付する（仕様書 6.3 節）。

- `kx-frame-controller-manager-linux-aarch64`：実行ファイル単体。`update` コマンドが名前で探す
- `KxFrameControllerManager-<版>-linux-aarch64.tar.gz`：`KxFrameControllerManager/` の下に実行ファイル、`install.sh`、`LICENSE.txt`、`THIRD-PARTY-NOTICES.md` を入れたもの。BOOTH へはこちらを上げる

tar.gz を作るのは `scripts/package.sh` で、手元でも `scripts/package.sh --version 1.2.3` で同じものを作れる。
導入用の `packaging/get.sh` は tar.gz の名前を同じ規則で組み立てて取りに行く。名前か中の構成（`KxFrameControllerManager/install.sh`）を変えるときは、`get.sh` も合わせて直す。
`get.sh` は既定ブランチの raw URL から配っているため、既定ブランチへ入った時点で利用者に届く。

## テスト

```sh
crystal tool format --check src spec
crystal spec
crystal build --cross-compile --target aarch64-unknown-linux-gnu src/main.cr -o kx
```

外部境界をテスト用実装に差し替えているため、SteamVR もヘッドセットも要らない。
差し替えの実装は `spec/support/fakes.cr` にある。

最後のクロスコンパイルは、リンクを行わずに aarch64 向けの意味解析だけを走らせる。
CPU で分岐するコード（`libopenvr_api.so` を探すディレクトリなど）は、ここで aarch64 として型検査される。
Crystal は呼ばれていないメソッドを型検査しないため、`main.cr` から届かないコードは spec のほうで確かめる。

CI はこの 2 段構成を採っている。
x86_64 のジョブで書式と単体テストとクロスコンパイルを回し、arm のジョブで実際のビルドと検査と単体テストを行う。

どちらのジョブも、先に変更したパスを見て、CI の対象になる変更が無ければスキップする（`docs/` や README だけの PR など）。
スキップしたジョブは成功と同じく必須のチェックを満たすため、そうした PR もそのままマージできる。
対象のパスの一覧は `ci.yml` の `changes` ジョブにある。判定できなかったときは CI を実行する。

## 表示言語

文字列は `locales/<コード>.json` にあり、コンパイル時に実行ファイルへ埋め込む。
`ja.json` を正とし、全言語でキーとプレースホルダが揃っていることを spec が確かめる。

言語を足すときは、次の 2 つを行う。

- `locales/` に `<コード>.json` を置く。`meta.*` に、その言語での名前、Steam の言語名、POSIX のロケール名、SteamVR の札、画面の書体を書く
- `src/runtime/i18n.cr` の `CODES` にコードを足す

機械翻訳なら `meta.machine_translated` を `"true"` にする。設定画面の「全般」タブにその旨が出る。

訳した文字列が設定画面の枠に収まるかは、見本を描き出して確かめる。
手元の libcairo と Noto Sans CJK を使う（Ubuntu なら `fonts-noto-cjk`）。

```sh
crystal run scripts/preview_dashboard.cr -- tmp/dashboard-preview
```

全言語、全タブぶんの PNG ができる。
枠に収まらない文字列は画面が字を小さくし、それでも収まらなければ末尾を「…」で切る。切れているものは訳を短くする。

## 実機でしか確かめられないこと

次の項目は、Steam Frame の実機でないと確認できない。
これまでに確かめた結果は[開発状況](status.md)にまとめてある。
仕様書 7.2 節の順に確かめる。基盤として確かめるのは次のものである。

- `/opt/steamvr/bin/linuxarm64/libopenvr_api.so` を開けること
- SteamVR を起動していない状態で `run` しても、SteamVR が起動しないこと
- SteamVR の起動でつながり、vrmanifest を登録できること
- SteamVR の終了で OpenVR を閉じ、次の起動でつなぎ直すこと
- `IVRSystem_026` と `IVRApplications_008` が `VR_IsInterfaceVersionValid` を通ること
- VR のメニューの「プログラムを起動」の一覧に「KxFrameControllerManager」が出て、選ぶと常駐が起動すること

# 設計

このドキュメントは、コードを触る人が最初に読むものである。
何がどこにあるか、どの向きに依存してよいか、機能を足すとき何を書くかを述べる。
規則は KxNotifyUtils の `docs/architecture.md` を引き継いでいる。

## 全体

プロセスはヘッドセット上の 1 本だけである（仕様書 4 章）。
入力は OpenVR（`libopenvr_api.so` を実行時に `dlopen`）から読み、切断はヘッドセット内の SteamVR ウェブサーバー `127.0.0.1:27062` への WebSocket で行う。
常駐の管理は systemd のユーザーユニットが持つ。

## ディレクトリ構成

```
src/
  main.cr                          composition root（組み立て、依存注入、コマンドの実行、主ループ）
  power_off/                       中立ドメイン
    models.cr                        手、27062 の一覧、切断の対象と結末、シリアルの変換
    hold_detector.cr                 片手ぶんの長押しの状態機械
    repository.cr                    入力、振動、デバイス、切断要求の抽象
    usecase.cr                       長押しの判定、対象の決定と照合、切断の実行と確認
  power_save/                      両方が切れている間の省電力
    models.cr                        変えるキー、読んだ値、戻すための記録
    repository.cr                    設定値と記録ファイルの抽象、記録ファイルの実装
    usecase.cr                       入る、戻る、戻し忘れの回復
  frame_link/                      27062 との通信
    codec.cr                         メッセージの符号化と復号
    websocket_repository.cr          要求ごとに張る WebSocket
  steamvr/                         SteamVR 連携
    ffi.cr                           openvr_api の定数、構造体、FnTable
    repository.cr                    OpenVR 呼び出しと vrmanifest 書き出しの抽象、イベントの型
    openvr_repository.cr             libopenvr_api.so を dlopen する実装
    usecase.cr                       接続、vrmanifest とアクションマニフェストの書き出しと登録、イベントの受け取り
    input_repository.cr              IVRInput による入力と振動
    device_repository.cr             コントローラーの左右、接続、シリアル
    settings_repository.cr           IVRSettings による設定値の読み書き
  config/                          設定
  update/                          更新
  runtime/                         実行環境
    paths.cr                         設定、ログ、マニフェスト、ユニットの置き場所
    logging.cr                       日次ローテーションのログと標準エラーへの出力
    i18n.cr                          表示する文字列の辞書
    scheduler.cr                     主ループの 1 拍で何を呼ぶか
    cli.cr                           コマンドの解釈
    systemd.cr                       ユニットの書き出しと systemctl --user の呼び出し
  error/
    usecase.cr                       例外のログ記録
actions/                           SteamVR Input のアクションマニフェストと frame_controller の既定バインド
packaging/                         systemd ユーザーユニットの雛形と install.sh
locales/                           ja.json / en.json
spec/                              単体テスト。support/fakes.cr が外部境界を差し替える
scripts/                           build.sh / verify.sh / package.sh
.github/                           workflows と actions/build-linux-aarch64
```

`actions/` と `packaging/` のユニットの雛形は、コンパイル時に実行ファイルへ埋め込む。
配布物の実行ファイルは単体でも `install` でき、SteamVR へつながるたびにアクションマニフェストを書き出す。

## 依存の向き

依存の向きは次のとおり固定する。

- `power_off` は他のどのコンテキストにも依存しない。ただし設定の型（`config/models`）だけは参照する。
- `power_save` は `power_off` の `DisconnectRepository` を使う。入る直前に 27062 の一覧を確かめるためである。
- `steamvr` は `power_off` の `InputRepository`、`HapticRepository`、`DeviceRepository` と、`power_save` の `SettingsRepository` を、`frame_link` は `DisconnectRepository` を継承して実装する。
- `runtime` は usecase を呼ぶだけで、ロジックを持たない。
- FFI の宣言はコンテキスト内の `ffi.cr` に隔離し、同じコンテキストの repository だけが参照する。

この規則の目的は、テスト境界の確保と、追加のときに変更範囲を狭めることにある。
長押しの判定と切断の手順は OpenVR にも 27062 にも依存しないため、repository をテスト用実装に差し替えれば実機なしで確かめられる。

## 主ループ

常駐の主ループは 1 本のスレッドで回る。

```
loop do
  SIGHUP を受けていれば設定を読み直す
  つながっていれば
    OpenVR のイベントを読む（切断の確認に使う）
    接続の後の最初の拍なら、27062 の疎通を別のファイバで確かめる
    長押しの判定（UpdateActionState と GetDigitalActionData）
    省電力の判定（左右がつながっているか）
  つながっていなければ間隔を空けて接続を試す
  input.poll_interval_ms（既定 20 ミリ秒）眠る
end
```

切断を決めたら、要求と確認は別のファイバで行う。
確認は最長で `confirm_timeout_ms` の 2 倍待つため、主ループで待つと長押しの判定が止まる。
切断を処理している間は、次の切断を始めない。

処理して短く `sleep` する形は KxNotifyUtils と同じである。
Crystal のファイバは協調的にしか切り替わらず、`sleep` で制御を返さないと、切断要求や更新の確認を待つファイバが進まない。
KxNotifyUtils にあったトレイと libui-ng のステップは無い。

1 拍で何を呼ぶかは `Runtime::Scheduler` が決める。
SteamVR が動いていない間は `steamvr.retry_interval_s` ごとに接続を試し、つながったら vrmanifest を登録する。
`VREvent_Quit` を受けたら応答してから OpenVR を閉じ、1 間隔の後に再試行へ戻る。
KxNotifyUtils と違い、SteamVR の終了でプロセスは終わらない（仕様書 3.6 節）。

SIGTERM と SIGINT で終わり、SIGHUP で設定を読み直す。
ハンドラは印を立てるだけで、処理は主ループが行う。
終わる前と、SteamVR の終了を受けて OpenVR を閉じる前に、省電力で変えた値を戻す。

## 設定の反映

設定は不変のスナップショット（`Config::Root`）として持ち、反映はスナップショットの差し替えで行う。
検証は `config/usecase` にあり、仕様書 6.1 節の範囲を見る。
コンテキストにしか分からない条件は、`main.cr` から `register_validator` で足す。

## SteamVR との接続

`VRApplication_Background` で初期化する。
SteamVR が動いていないときに SteamVR を起こさず、初期化のほうを失敗させる種別はこれだけである。
SteamVR が動いていないことは `VRInitError_Init_NoServerForBackgroundApp` という初期化の失敗として表れるので、この番号だけは異常として扱わず、ログも `debug` に留める。

インターフェースは `IVRSystem_026`、`IVRApplications_008`、`IVRInput_011`、`IVRSettings_003` に固定し、初期化のたびに `VR_IsInterfaceVersionValid` で確かめる。
前の 2 つが通らなければ SteamVR 連携を無効にする。
後の 2 つが通らなければ、それを使う機能（長押しの検出、省電力）だけを止め、接続は保つ。

アクションのハンドルは、SteamVR へつながるたびに取り直す。
`Repository#generation` が開き直すたびに進み、入力の側はこの番号の変化を見る。

vrmanifest は接続のたびに書き出し直して登録する。
目的は SteamVR のコントローラーバインド画面に本ツールを出すことであり、自動起動には使わない。
実行ファイルのパスは `binary_path_linux` に書く。

## 仕様書からの変更点

仕様書（issue #1）から変えた点を挙げる。

- **Crystal の版**：仕様書は 1.14.0 の aarch64 版を使うとしていたが、1.14.0 には aarch64 Linux 向けの公式の配布物が無い。`crystal-lang/install-crystal` は公式の配布物を取りに行くため、arm のランナーで 1.14.0 は入らない。aarch64 Linux 向けの配布物がある 1.19.1 に上げた。x86_64 の検査のジョブも同じ版に揃えてある。1.19 では Linux のイベントループが libevent を使わなくなっており、静的に取り込むライブラリが 1 つ減った。
- **静的リンクの方法**：Crystal の `--static` は glibc ごと静的にしようとするので使わない。静的ライブラリへのリンクだけを集めたディレクトリをリンカの探索の先頭に置き、glibc 以外を静的に取り込む。詳しくは `scripts/build.sh` のコメントにある。`-static-libgcc` も付け、動的な依存を glibc だけにしてある。
- **CA 証明書の場所**：OpenSSL を静的に取り込むと、証明書を探す既定の場所がビルドした Ubuntu のもの（`/usr/lib/ssl`）になる。SteamOS は Arch Linux 系で、そこには無い。更新の確認が HTTPS で失敗しないよう、`/etc/ssl/certs/ca-certificates.crt` などを探して渡す。`SSL_CERT_FILE` で上書きできる。
- **更新の置き換え**：Linux では走っている実行ファイルの上へリネームで重ねられる。KxNotifyUtils の Windows 版にあった `.old` への退避と巻き戻しは無くした。
- **プレリリースの起点**：KxNotifyUtils は安定版のタグが無いとプレリリースを作れなかった。こちらは最初の安定版を出す前から試せるよう、タグが無ければ 0.0.0 を起点にして `0.0.1-testN` を作る。
- **エラーの知らせ方**：トレイが無いため、`Error::Usecase` はログへ残すだけにした。systemd 下ではログが標準エラーにも出るため、`journalctl --user` でも読める。
- **IVRInput と IVRSettings の版**：仕様書はヘッドセットの `openvr_capi.h` から決めるとしていたが、まだ読めていない。OpenVR SDK の master の `openvr_capi.h` と同じ版にし、初期化のたびに `VR_IsInterfaceVersionValid` で確かめる。通らなければその機能だけを止める。
- **既定バインドの controller_type**：Steam Frame のコントローラーは `frame_controller` である。SteamVR のドライバの入力プロファイル（`drivers/frame_controller/resources/input/frame_controller_profile.json`）に、左の `/input/view` と右の `/input/menu` がある。
- **CLI が SteamVR につながらないときの disconnect**：`left` と `right` は 27062 の一覧が報告する左右だけで決める（仕様書 4.3 節）。どちらの手か 1 台に決まらなければ切らない。
- **未設定のキーの判定**：IVRSettings は、既定値を持つキーなら未設定でも既定値を返す。未設定と分かるのは、既定値も無いキー（`UnsetSettingHasNoDefault`）だけである。`analogGain` が既定値を持つ場合、戻すときは消さずに読んだ既定値を書く。実機の振る舞いは 7.2 節の確認で見る。
- **言語の決め方**：`language` が `auto` のときは、環境変数 `LC_ALL`、`LC_MESSAGES`、`LANG` の順に見る。Windows の表示言語に当たるものが無いためである。

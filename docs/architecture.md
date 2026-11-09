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
    bindings.cr                      既定バインドへ長押しのボタンを差し込む
  dashboard/                       設定画面（SteamVR のダッシュボードのタブ）
    canvas.cr                        描画先の抽象、色、文字の揃え
    cairo.cr                         libcairo を dlopen して描く実装
    models.cr                        画面へ見せる状態、画面から変える項目と 1 段ぶんの変え方
    view.cr                          画面の組み立てと、押せる場所の一覧
    usecase.cr                       タブの作成と破棄、操作の受け取り、描き直し、手動の切断
  config/                          設定
  update/                          更新
    models.cr                        版、添付、リリース
    repository.cr                    GitHub Releases から取る
    usecase.cr                       新しい版を探す
    installer.cr                     取得、照合、置き換え、元の実行ファイルの退避と巻き戻し
    state.cr                         自動更新の状態（確かめた時刻、戻した版、進み具合、最後の結末）、起動の印、排他
    auto_updater.cr                  自動更新の流れ（試しの起動、再起動、起動の確かめ、巻き戻し）
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
packaging/                         systemd ユーザーユニットの雛形、install.sh、導入用の get.sh
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
- `runtime` は usecase を呼ぶだけで、ロジックを持たない。`runtime/systemd` は `update` の `ServiceControl` を継承して実装する。自動更新が常駐のユニットを再起動するためである。
- `dashboard` は `steamvr` の repository（オーバーレイの部分）、`config` の usecase、`power_off` の型だけを参照する。常駐の部品には `main.cr` が渡す Proc を通して触れる。
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

## 設定画面

設定画面は SteamVR のダッシュボードのタブ（`IVROverlay` のダッシュボードオーバーレイ）として出す。
仕様書 5.3 節が持ち込まないとした KxNotifyUtils の設定ウィンドウ（libui-ng）の代わりである。

画面は CPU で描いた画素を `SetOverlayRaw` で渡す。ブラウザエンジンも GUI ツールキットも持たない。
Frame 向けの既存のツール（FrameMover、frameeyeosc、Babble-Frame-Runtime）も、Cairo などで描いた画像をダッシュボードのタブに出しており、ブラウザは抱えていない。
デスクトップの窓は VR の中から見えず、ヘッドセットのブラウザで開く Web 画面は、VR の中で別のアプリへ切り替える手間がかかる。

描画には libcairo を使う。実行時に `dlopen` するため、実行ファイルの動的な依存は glibc だけのまま変わらない（`scripts/verify.sh`）。
文字は Cairo の toy API で "Noto Sans CJK JP" を指定する。SteamOS に入っている書体である。
libcairo が無ければタブを出さず、常駐の他の機能は止めない。

`SetOverlayRaw` は渡すたびに画面が一瞬消える。そのため描き直すのは、タブが見えている間に内容が変わったときだけにする。
状態は見えている間だけ 1 秒ごとに組み立て直し、前と同じなら描かない。ポインタの移動では描き直さない。
押せる場所は描くときに一覧にしておき、`MouseButtonUp` の座標と照らし合わせる。オーバーレイのマウスの座標は左下が原点なので、上下を反転してから比べる。

OpenVR は `VRApplication_Background` のまま使う。Background のアプリでもダッシュボードオーバーレイは作れる（Babble-Frame-Runtime が同じ形）。
`IVROverlay_028` が通らなければタブだけを出さない。
OpenVR を閉じる前には必ずオーバーレイを消す。画面を受け取っている途中のオーバーレイを残して閉じると、SteamVR 側が落ちた例がある（FrameMover）。
前の接続のオーバーレイが残っていて `KeyInUse` が返ったときは、見つけて消してから作り直す。

手動の切断は 2 回押しで動かす。VR の中では誤って触れやすく、確認のダイアログも出せないためである。
切断は確認まで数秒待つので、主ループを止めないよう別のファイバで行う。長押しの切断と重なったときは受け付けない。

画面からの保存は `Config::Usecase#save` を通し、ファイルへ書いたうえで SIGHUP と同じ反映を行う。
数値は検証（仕様書 6.1 節）の範囲の中でだけ動かし、範囲外の値を作らない。

長押しのボタンを変えると、既定バインドを書き直してから本ツールの OpenVR の接続だけを閉じ、次の拍でつなぎ直す。
つなぎ直しのときに新しい既定バインドを書き出し、`SetActionManifestPath` を呼び直す。
つなぎ直すとタブも消えるので、つなぎ直しはタブが見えていない間まで待つ。
SteamVR そのものは再起動しない（仕様書 2 章）。

更新のタブは、自動更新を常駐の中へ持ち込まない。
「今すぐ更新」は `systemd-run --user` で一時的なユニット（`kx-frame-controller-manager-update-now`）を作り、そこで手動の `update` を走らせる。
常駐の子プロセスにすると、常駐のユニットを再起動したときに一緒に止められ、新しい版の起動を確かめて戻す者がいなくなる。
同じ名前のユニットが走っている間は `systemd-run` が断るので、重ねて押しても更新は 1 つしか走らない。

進み具合と結末は、自動更新が状態のファイル（`update.json`）へ残し、常駐はそれを読むだけにする。
タイマーから起きた更新も、画面から始めた更新も、同じ記録に残るためである。
更新のプロセスが途中で落ちると段階が残ったままになるので、段階にはプロセス番号と始めた時刻を添える。読む側は、その番号のプロセスが本ツールの `update` として動いていなければ段階を捨てる。番号は再起動の後などに別のプロセスへ使い回されうるため、いるかどうかだけでは見ない。ユニットが止める時間（15 分）を大きく過ぎた段階も捨てる。
画面の「更新を確認」で確かめた時刻は、状態のファイルの `last_checked_at` には書かない。これは自動更新の間隔の起点であり、画面で確かめたせいで、見つけた版の自動での置き換えが遅れないようにするためである。画面は常駐が覚えておき、どちらか新しいほうを「最後の確認」に出す。
設定と間隔のために何もしなかった回は結末を残さない。タイマーは 30 分ごとに起きるため、残すと前の結末がすぐ見えなくなる。
「更新を確認」は置き換えまで進まず、GitHub Releases を見るだけなので、常駐の中の別のファイバで行う。

## 設定の反映

設定は不変のスナップショット（`Config::Root`）として持ち、反映はスナップショットの差し替えで行う。
検証は `config/usecase` にあり、仕様書 6.1 節の範囲を見る。
コンテキストにしか分からない条件は、`main.cr` から `register_validator` で足す。

## SteamVR との接続

`VRApplication_Background` で初期化する。
SteamVR が動いていないときに SteamVR を起こさず、初期化のほうを失敗させる種別はこれだけである。
SteamVR が動いていないことは `VRInitError_Init_NoServerForBackgroundApp` という初期化の失敗として表れるので、この番号だけは異常として扱わず、ログも `debug` に留める。

インターフェースは `IVRSystem_026`、`IVRApplications_008`、`IVRInput_011`、`IVRSettings_003`、`IVROverlay_028` に固定し、初期化のたびに `VR_IsInterfaceVersionValid` で確かめる。
前の 2 つが通らなければ SteamVR 連携を無効にする。
後の 3 つが通らなければ、それを使う機能（長押しの検出、省電力、設定画面）だけを止め、接続は保つ。

アクションのハンドルは、SteamVR へつながるたびに取り直す。
`Repository#generation` が開き直すたびに進み、入力の側はこの番号の変化を見る。

vrmanifest は接続のたびに書き出し直して登録する。
目的は SteamVR のコントローラーバインド画面に本ツールを出すことであり、自動起動には使わない。
実行ファイルのパスは `binary_path_linux` に書く。

## 仕様書からの変更点

仕様書（issue #1）から変えた点を挙げる。

- **設定画面とボタンの割り当て**：仕様書は GUI の設定画面をスコープ外とし、ボタンの割り当ては SteamVR のバインド画面だけで行うとしていた。利用者の要望で、SteamVR のダッシュボードのタブとして設定画面を足した。ボタンは設定 `input.left_button` と `input.right_button` で既定バインドへ差し込む。SteamVR のバインド画面で選んだバインドがあれば、そちらが優先される点は変わらない。

- **Crystal の版**：仕様書は 1.14.0 の aarch64 版を使うとしていたが、1.14.0 には aarch64 Linux 向けの公式の配布物が無い。`crystal-lang/install-crystal` は公式の配布物を取りに行くため、arm のランナーで 1.14.0 は入らない。aarch64 Linux 向けの配布物がある 1.19.1 に上げた。x86_64 の検査のジョブも同じ版に揃えてある。1.19 では Linux のイベントループが libevent を使わなくなっており、静的に取り込むライブラリが 1 つ減った。
- **静的リンクの方法**：Crystal の `--static` は glibc ごと静的にしようとするので使わない。静的ライブラリへのリンクだけを集めたディレクトリをリンカの探索の先頭に置き、glibc 以外を静的に取り込む。詳しくは `scripts/build.sh` のコメントにある。`-static-libgcc` も付け、動的な依存を glibc だけにしてある。
- **CA 証明書の場所**：OpenSSL を静的に取り込むと、証明書を探す既定の場所がビルドした Ubuntu のもの（`/usr/lib/ssl`）になる。SteamOS は Arch Linux 系で、そこには無い。更新の確認が HTTPS で失敗しないよう、`/etc/ssl/certs/ca-certificates.crt` などを探して渡す。`SSL_CERT_FILE` で上書きできる。
- **更新の置き換え**：Linux では走っている実行ファイルの上へリネームで重ねられる。置き換えそのものに `.old` への退避は要らないが、自動更新で新しい版が起動しなかったときに戻す先として、置き換える前の実行ファイルを `.old` へハードリンクで残す。
- **自動更新**：仕様書は `update` コマンドでの置き換えだけを決めていた。systemd のタイマーから `update --auto` を起こし、置き換えた後に常駐を再起動して起動を確かめ、起動しなければ戻す流れを足した。常駐の中で行わないのは、常駐が自分を再起動すると、新しい版の起動を確かめる前に自分が止まり、戻す者がいなくなるためである。流れは[設定リファレンス](configuration.md)の `update` にある。
- **プレリリースの起点**：KxNotifyUtils は安定版のタグが無いとプレリリースを作れなかった。こちらは最初の安定版を出す前から試せるよう、タグが無ければ 0.0.0 を起点にして `0.0.1-testN` を作る。
- **エラーの知らせ方**：トレイが無いため、`Error::Usecase` はログへ残すだけにした。systemd 下ではログが標準エラーにも出るため、`journalctl --user` でも読める。
- **IVRInput と IVRSettings の版**：仕様書はヘッドセットの `openvr_capi.h` から決めるとしていたが、まだ読めていない。OpenVR SDK の master の `openvr_capi.h` と同じ版にし、初期化のたびに `VR_IsInterfaceVersionValid` で確かめる。通らなければその機能だけを止める。
- **既定バインドの controller_type**：Steam Frame のコントローラーは `frame_controller` である。SteamVR のドライバの入力プロファイル（`drivers/frame_controller/resources/input/frame_controller_profile.json`）に、左の `/input/view` と右の `/input/menu` がある。
- **CLI が SteamVR につながらないときの disconnect**：`left` と `right` は 27062 の一覧が報告する左右だけで決める（仕様書 4.3 節）。どちらの手か 1 台に決まらなければ切らない。
- **未設定のキーの判定**：IVRSettings は、既定値を持つキーなら未設定でも既定値を返す。未設定と分かるのは、既定値も無いキー（`UnsetSettingHasNoDefault`）だけである。`analogGain` が既定値を持つ場合、戻すときは消さずに読んだ既定値を書く。実機の振る舞いは 7.2 節の確認で見る。
- **言語の決め方**：`language` が `auto` のときは、環境変数 `LC_ALL`、`LC_MESSAGES`、`LANG` の順に見る。Windows の表示言語に当たるものが無いためである。

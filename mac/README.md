# steno

macOS 用の常時オンデバイス文字起こしツール。システム音声(通話相手)とマイク(自分)を同時に
聞き取り、会話をほぼリアルタイムで JSON Lines に書き続ける。

**音声は一切外に出ない。** 取得・認識・書き出しは全てローカル。ネットワークを使うのは
オンデバイスモデル(Apple 音声認識・話者分離)の初回ダウンロードのみ。サーバもアカウントも
テレメトリも無い。

## 仕組み

```mermaid
flowchart LR
    sys[システム音声] -->|Core Audio process tap| asr
    sys -->|並走| diar["Sortformer<br/>話者ターン境界検出"]
    mic[マイク] -->|AVCaptureSession| asr
    diar -->|境界で finalize| asr
    asr["SpeechAnalyzer<br/>オンデバイス・ja_JP"] --> file[(daily .jsonl)]
    asr --> win[ライブ窓表示]
```

- **システム音声** — Core Audio process tap(ScreenCaptureKit ではない)。video pipeline も
  `replayd` も持たず、それ起因のハングや無音化が無い。
- **マイク** — 特定デバイスに固定した `AVCaptureSession`。システム既定の入力が切り替わっても
  (イヤホン接続など)選んだマイクで録り続ける。
- **話者の区別**は **source**(`system`=相手 / `mic`=自分)で取る。さらに system 側のミックス内に
  複数話者がいる場合、Streaming Sortformer(FluidAudio / CoreML)で**話者が変わった点を検出して
  発話を区切る**。掛け合いが 1 行に merge されて意味を失うのを防ぐのが目的で、話者の特定(誰か)は
  しない(ラベルは付けない)。`STENO_DIAR=0` で無効化できる。

## 要件

- **macOS 26.0+**(`SpeechAnalyzer` と Core Audio process tap)
- **Apple Silicon**
- Swift 6 ツールチェイン(Xcode 26 / Command Line Tools)

## ビルドとインストール

```sh
make build     # → ./steno.app
make install   # → ~/Applications/steno.app
```

インストール後は `~/Applications` から起動する。初回に **マイク / 音声認識 / 音声キャプチャ** の
許可を求められる(いずれも「音声は外部送信しない」と明記)。

**署名**: Apple Development / Developer ID 証明書があればそれで、無ければ ad-hoc 署名になる。macOS
は許可(TCC)を署名単位で管理するため、ad-hoc だと再ビルドごとに許可がリセットされる。頻繁に
ビルドし直すなら自分の証明書で署名すると永続する。

## 使い方

- 窓にライブの文字起こし(時刻・`system`/`mic` バッジ・system は再生元アプリ名)。
- **マイク** ドロップダウンで入力デバイスを選択(記憶され、既定が変わっても固定)。
- **リセット** で再起動せずキャプチャを作り直す。

文字起こしは `~/.config/steno/transcripts/YYYY-MM-DD.jsonl` (ローカル日付)に追記される。

## 出力フォーマット

確定発話ごとに JSON 1 行。steno(書く)と後段(読む)の唯一の契約面:

```json
{"ts":"2026-06-16T15:28:06.186+09:00","epoch":1781591286.18,"isFinal":true,"seq":7,"source":"system","app":"Microsoft Teams","text":"…"}
```

| キー | 意味 |
|---|---|
| `ts` / `epoch` | ISO 8601 ローカル時刻 / Unix 秒 |
| `isFinal` | 常に `true`(確定発話のみ書く) |
| `seq` | ファイル内通し番号(日付替わり / 起動でリセット) |
| `source` | `system`(相手)/ `mic`(自分) |
| `app` | system のみ: 出力中だったアプリ名 |
| `text` | 文字起こしテキスト |

スキーマは話者分離の有無で変わらない(話者ラベルは持たない)。ただし `source=system` の発話は
話者が変わった点で区切られるため、複数話者の掛け合いは 1 行に merge されず、話者ターンごとに
別の行(別 `seq`)として並ぶ。

## 設定

環境変数(`Info.plist` の `LSEnvironment` で指定):

| 変数 | 意味 |
|---|---|
| `STENO_DIR` | 基準ディレクトリ(既定 `~/.config/steno`) |
| `TRANSCRIPT_DIR` | 出力先のみ(既定 `STENO_DIR/transcripts`) |
| `STENO_VOCAB` | 認識ヒント語彙ファイル |
| `STENO_DIAR=0` | system の話者ターン区切りを無効化(既定は有効) |
| `STENO_DEBUG=1` | 詳細ログ |

**語彙ヒント**: 固有名詞・専門用語(1 行 1 語、`#` でコメント)を `~/.config/steno/vocabulary.txt`
に置くと認識ヒント(contextual strings)として渡され、一般モデルが崩す名前や用語が当たるように
なる。再起動で反映。

## ログ

`~/.config/steno/` に出力する:

- `steno.log` — 時刻付きの重要イベント(起動・復旧・エラー)。**まずここを見る**
- `stdout.log` / `stderr.log` — 生の標準出力 / 標準エラー(フレームワーク警告やクラッシュ直前の出力まで)。各 1 世代ローテート

## 既知の制限

- **確定までのレイテンシ**は長い発話で数十秒(瞬時ではない)。話者ターン区切りはこれを能動的に
  短縮もする(境界で finalize するため)。
- **`ja_JP` 専用**(ロケール固定)。他言語は `AppController.swift` のロケールを書き換える
- **話者ターン区切りの粗さ** — 境界検出に ~1s の遅延があり、次話者の冒頭 ~1s が前の行にこぼれる
  ことがある。また相槌(「はい」等)の高速な応酬では切りすぎて短い行が増える。区切りの目的(掛け合いを
  分離して意味を保つ)には十分だが、行境界は厳密ではない。
- **話者分離の同時話者数**は内部モデル上 4。超えても**区切り**は機能する(5 人目が既存スロットに
  寄っても遷移は拾える)が、ラベル相当の分離精度は 4 人想定。
- 初回起動時のみ話者分離モデル(`FluidInference/diar-streaming-sortformer-coreml`)をダウンロードする
  (以降はローカルキャッシュ)。ダウンロードに失敗しても素の文字起こしに縮退して動き続ける。

## ライセンス

MIT — [LICENSE](LICENSE)。

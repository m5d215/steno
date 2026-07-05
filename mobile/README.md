# steno (iOS)

iOS 用の常時オンデバイス文字起こし。マイクで周囲の会話を聞き取り、確定発話ごとにローカルの
JSON Lines へ書きながら、同じレコードを指定した宛先へリアルタイムに POST し続ける。

ASR + 話者分離のエンジンは共有パッケージ [`StenoCore`](../Core) を使い、macOS 版([`mac/`](../mac))と
同じコードを載せる。mac がシステム音声＋マイクの二層を Core Audio process tap で扱うのに対し、
iOS は tap が無いので**マイク一本の環境音**に割り切り、代わりに「ローカルに書いた発話を別マシンへ
送る」転送層を持つ。

**音声は端末の外に出ない。** 取得も認識もローカル(Apple のオンデバイス `SpeechAnalyzer`)。
外へ出るのは**文字起こし結果のテキストだけ**で、宛先は自分で指定する(Tailscale 上の自宅 PC 等)。

## 仕組み

```
マイク (AVAudioEngine) ──► Transcriber (SpeechAnalyzer, ja_JP)
                              │ 確定発話
                              ▼
                        TranscriptStore ──► ローカル jsonl (SSOT, append-only)
                              │ 未送信キュー
                              ▼
                          Shipper ──► POST <endpoint>/ingest (Bearer 認証)
```

- **エンジンは共有**。`Transcriber`(SpeechAnalyzer)は [`StenoCore`](../Core) のもの。capture・
  `TranscriptStore`・`Shipper`・UI が iOS 固有部として本ディレクトリに載る。
- **話者ターン区切り(任意・既定 on)**。複数人の会話で話者が変わった点を Core の `SpeakerSegmenter`
  (Streaming Sortformer)で検出し、`Transcriber` を finalize して行を割る。mic を Transcriber と
  Segmenter に fan-out する。off にすると間(無音)でしか切れず、掛け合いが 1 行に merge される。
  誰が話したかのラベルは付かない(区切りのみ)。設定でトグル。初回のみ話者分離モデルを DL する。
- **capture と network を分離**する。capture は「まずローカル jsonl に書く」だけ。送信は Shipper が
  別で追いかける。宛先が落ちていても発話は失われず、復帰したら溜まったぶんを drain する。
- **at-least-once**。各レコードはグローバル単調増加の `seq` を持ち、サーバは `(deviceId, seq)` で
  冪等に dedup する前提。送信済みカーソル(`lastShippedSeq`)は永続し、アプリ再起動を跨いで復元する。
- **常時録音**は `UIBackgroundModes: audio` ＋ `.record` の AVAudioSession。interruption(電話等)や
  経路変化からは interruption 通知と liveness watchdog の 2 系統で復帰する。

## 送信フォーマット

確定発話ごとに 1 レコード。ローカル jsonl と POST ペイロードで同一:

```json
{"deviceId":"iphone","ts":"2026-07-03T15:28:06.186+09:00","epoch":1783060086.18,"seq":42,"source":"mic","text":"…"}
```

`POST <endpoint>/ingest` の body はこのレコードの JSON 配列。サーバは受理した最大 seq を
`{"acked": <seq>}` で返す(省略時はバッチ末尾の seq を送信済みとみなす)。ローカルの jsonl は
`Documents/transcripts/YYYY-MM-DD.jsonl`。

## 設定(アプリ内)

| 項目 | 意味 |
|---|---|
| 宛先ベース URL | 例 `http://100.x.y.z:8787`。Tailscale 上の PC。末尾に `/ingest` を付けて POST |
| Bearer トークン | `Authorization: Bearer <token>` に載せる共有シークレット |
| デバイス ID | 送信元の識別子(サーバ dedup キーの一部)。既定 `iphone` |

WireGuard(Tailscale)がトンネルを暗号化するので、宛先は素の HTTP でよい。

## 要件

- **iOS 26.0+**(`SpeechAnalyzer`)
- Xcode 26 / Swift 6

## ビルド

[xcodegen](https://github.com/yonaskolb/XcodeGen) で `.xcodeproj` を生成する(SSOT は `project.yml`)。

```sh
make gen     # project.yml → steno-mobile.xcodeproj
make build   # シミュレータ向けにビルド(コンパイル確認)
make open    # Xcode で開く(実機は Team を設定して署名)
```

実機で常用するには署名が要る。無料プロビジョニングだと 7 日ごとに再署名が必要なので、
常駐させるなら Apple Developer Program での署名を推奨。

## ライセンス

MIT — [LICENSE](../LICENSE)。

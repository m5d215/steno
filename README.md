# steno

常時オンデバイス文字起こし。macOS と iOS の 2 アプリが、共有エンジンの上に載る monorepo。

**音声は端末の外に出ない。** 取得も認識も Apple のオンデバイス `SpeechAnalyzer` でローカル完結する。

## 構成

| ディレクトリ | 中身 |
|---|---|
| [`mac/`](mac/README.md) | macOS 常駐版。システム音声(Core Audio process tap)＋マイクを聞き、会話を JSON Lines に書き続ける |
| [`mobile/`](mobile/README.md) | iOS 版。マイク一本の環境音を書き起こし、ローカル記録しつつ Tailscale 越しに指定サーバへリアルタイム POST する |
| `Core/` | 共有エンジン `StenoCore`。両アプリで同一の「音を食って確定発話と話者境界を出す」部分だけを抽出 |

## Core が持つもの / 持たないもの

`Core/`(StenoCore)は**プラットフォーム非依存のエンジンだけ**:

- `Transcriber` — SpeechAnalyzer ラッパ(確定発話を `onFinal` で流す)
- `SpeakerSegmenter` — Streaming Sortformer(FluidAudio)で話者ターン境界を検出(区切りであってラベル付けではない)
- `BufferConverter` — SpeechAnalyzer 用の PCM format 変換(内部)

capture 層・writer・UI・転送はプラットフォームで別物なので**各アプリに残す**。境界を「純粋なエンジン」に絞ることで `#if os(...)` の氾濫を避けている。両アプリは `Core` を local package として依存する(mac は SwiftPM path 依存、mobile は xcodegen の local package)。

## ビルド

各アプリのディレクトリで:

```sh
# macOS
cd mac && make build      # → mac/steno.app

# iOS
cd mobile && make open     # Xcode で開いて実機 run(署名は Team 設定済み)
cd mobile && make build    # シミュレータ向けにコンパイル確認
```

詳細は各サブディレクトリの README を見る。

## ライセンス

MIT — [LICENSE](LICENSE)。

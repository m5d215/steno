// swift-tools-version: 6.0
import PackageDescription

// steno — 常時ローカルで聞いて、喋りを書き起こし続ける macOS 常駐ツール。
// 完全オンデバイス(音声を外部に出さない)・半リアルタイム・省エネを狙う。
//
// 設計の芯(PoC で実測して確定):
//   - system 音声は Core Audio process tap で取る(ScreenCaptureKit を使わない。
//     SCK の replayd hang / 経路変化での無音化を回避し、video pipeline 分の電力も切る)
//   - liveness は frames-stall 検知 → tap/aggregate 完全再生成(device-running は当てにしない。
//     BT/held-open で張り付くため trigger に使えないと実測で判明)
//   - 話者は source(system=相手 / mic=自分)で区別する。加えて system 側のミックス内に複数話者が
//     いる場合に「話者が変わったら発話を区切る」ため、Streaming Sortformer(FluidAudio, CoreML)で
//     話者ターン境界を検出し finalize(through:) で発話を切る(既定で有効、STENO_DIAR=0 で無効化)。
//     目的は話者特定ではなく区切りなのでラベル精度は問わない。ANE は SpeechAnalyzer×2 が握るため
//     diarizer の compute units は ANE を外す(.cpuAndGPU)。
//   - メニューバーではなく窓 UI。App Nap は ProcessInfo.beginActivity で明示的に抑止する
//
// ASR + 話者分離のエンジン(Transcriber / SpeakerSegmenter / BufferConverter)は ../Core の
// StenoCore に切り出して mobile と共有する。ここには capture / writer / UI / 認可 など macOS 固有部のみ。
let package = Package(
    name: "steno",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .executableTarget(
            name: "steno",
            dependencies: [.product(name: "StenoCore", package: "Core")],
            path: "Sources/steno"
        )
    ]
)

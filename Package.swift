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
//     話者ターン境界を検出し finalize(through:) で発話を切る方式を評価中(spike, STENO_DIAR gate)。
//     ラベル精度は最低限で良い(目的は特定ではなく区切り)。ANE は SpeechAnalyzer×2 が握るため
//     diarizer の compute units は ANE を外す(.cpuAndGPU)。
//   - メニューバーではなく窓 UI。App Nap は ProcessInfo.beginActivity で明示的に抑止する
let package = Package(
    name: "steno",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "steno",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/steno"
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// StenoCore — mac / mobile 両アプリで共有する、プラットフォーム非依存の ASR + 話者分離エンジン。
//   - Transcriber       Apple SpeechAnalyzer ラッパ(確定発話を onFinal で流す)
//   - SpeakerSegmenter  Streaming Sortformer(FluidAudio)で話者ターン境界を検出
//   - BufferConverter   SpeechAnalyzer が要求する format への PCM 変換(内部)
// capture 層・writer・UI はプラットフォーム固有なので各アプリに残す。ここは「音を食って
// 確定発話と話者境界を出す」ところまで。両アプリで完全に同一の部分だけを抽出している。
let package = Package(
    name: "StenoCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "StenoCore", targets: ["StenoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .target(
            name: "StenoCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/StenoCore"
        )
    ]
)

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
//   - 話者は source(system=相手 / mic=自分)だけで区別する。Sortformer の話者分離(spk_N)は
//     精度が低く、後段の LLM 要約はそれ無しで十分機能するため持たない(外部モデル依存も無し)
//   - メニューバーではなく窓 UI。App Nap は ProcessInfo.beginActivity で明示的に抑止する
let package = Package(
    name: "steno",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "steno",
            path: "Sources/steno"
        )
    ]
)

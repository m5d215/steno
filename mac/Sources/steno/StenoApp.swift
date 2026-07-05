import Combine
import StenoCore
import SwiftUI

/// steno — 常時ローカルで聞いて、喋りを話者付きで書き起こし続ける macOS アプリ。
/// 通常の窓 UI。App Nap 対策は UI 形態ではなく AppController の activity assertion で行う。
@main
struct StenoApp: App {
    // 何よりも先に stdout/stderr をファイルへ張り替える(GUI 起動でも生ログを残すため)。
    // @StateObject の AppController() は autoclosure で遅延生成されるので、ここが最初に走る。
    init() {
        redirectStandardStreams()
        // Core(StenoCore)エンジンのログも steno.log へ流す。従来 mac の firehose を保つ。
        StenoCoreLog.sink = { StenoLog.shared.write($0) }
    }

    @StateObject private var controller = AppController()

    var body: some Scene {
        WindowGroup("steno") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 480, minHeight: 420)
        }
    }
}

private let lineTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct ContentView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.isRecording ? Color.orange : Color.secondary.opacity(0.4))
                    .frame(width: 11, height: 11)
                Text("steno").font(.title3.bold())
                // 起動中・エラーなど特筆すべき状態のときだけ出す(録音中/停止中はドットとボタンで示す)。
                if !controller.statusLine.isEmpty {
                    Text(controller.statusLine)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(controller.isRecording ? "停止" : "開始") { controller.toggle() }
                    .disabled(!controller.ready)
            }

            deviceControls

            Divider()

            transcript
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // capturer の現在デバイス名と入力デバイス一覧を main 上で定期取り込み(pull 方式)。
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            controller.syncDeviceNames()
        }
    }

    @ViewBuilder private var deviceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            // システム音声: 既定出力に追従(読み取り専用)。tap が今どのデバイスを録ってるか。
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Text("システム音声").foregroundStyle(.secondary)
                Text(controller.systemDeviceName)
                Spacer()
                Button { controller.reset() } label: {
                    Label("リセット", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(!controller.ready)
            }
            // マイク: 選択デバイスに pin(システム既定が変わっても固定マイクで録る)。
            HStack(spacing: 6) {
                Image(systemName: "mic").foregroundStyle(.secondary)
                Text("マイク").foregroundStyle(.secondary)
                Picker("", selection: $controller.selectedMicUID) {
                    Text("システム既定").tag(String?.none)
                    ForEach(controller.inputDevices) { d in
                        Text(d.name).tag(Optional(d.uid))
                    }
                }
                .labelsHidden().fixedSize()
                if controller.selectedMicUID == nil {
                    Text("→ \(controller.micDeviceName)").foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .font(.caption)
    }

    @ViewBuilder private var transcript: some View {
        if controller.lines.isEmpty {
            VStack {
                Spacer()
                Text("ここに文字起こしがリアルタイムで表示されます")
                    .font(.callout).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(controller.lines) { line in
                            TranscriptRow(line: line).id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .onChange(of: controller.lines.count) { _, _ in
                    guard let last = controller.lines.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct TranscriptRow: View {
    let line: TranscriptLine

    /// system=青系 / mic=緑系 で source を色分けする。
    private var sourceColor: Color { line.source == "mic" ? .green : .blue }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(lineTimeFormatter.string(from: line.time))
                .font(.caption.monospaced()).foregroundStyle(.tertiary)
            // source(system=相手 / mic=自分)を色付き badge に。
            Text(line.source)
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(sourceColor.opacity(0.18))
                .foregroundStyle(sourceColor)
                .clipShape(Capsule())
            Text(line.text)
                .font(.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let app = line.app {
                Text(app)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                statusBar
                transcript
                controlButton
            }
            .padding()
            .navigationTitle("steno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Label(model.micStatus, systemImage: "mic.fill")
                .foregroundStyle(model.isRunning ? .green : .secondary)
            Spacer()
            Text("未送信 \(model.pendingCount)")
                .foregroundStyle(model.pendingCount > 0 ? .orange : .secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 4)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(timeFmt.string(from: Date(timeIntervalSince1970: line.epoch)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(line.text)
                                .font(.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(line.seq)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.lines.count) {
                if let last = model.lines.last {
                    withAnimation { proxy.scrollTo(last.seq, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var controlButton: some View {
        VStack(spacing: 6) {
            Button {
                Task {
                    if model.isRunning {
                        await model.stop()
                    } else {
                        await model.start()
                    }
                }
            } label: {
                Text(model.isRunning ? "停止" : "開始")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)

            Text(model.shipStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

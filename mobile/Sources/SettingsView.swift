import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Config.endpointKey) private var endpoint = ""
    @AppStorage(Config.tokenKey) private var token = ""
    @AppStorage(Config.deviceIdKey) private var deviceId = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.y.z:8787", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("宛先ベース URL")
                } footer: {
                    Text("Tailscale 上の PC のベース URL。末尾に /ingest を付けて POST する。")
                }

                Section("Bearer トークン") {
                    TextField("token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField(Config.defaultDeviceId, text: $deviceId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("デバイス ID")
                } footer: {
                    Text("送信元の識別子。空なら \(Config.defaultDeviceId)。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Config.endpointKey) private var endpoint = ""
    @AppStorage(Config.tokenKey) private var token = ""
    @AppStorage(Config.deviceIdKey) private var deviceId = ""
    @AppStorage(Config.diarEnabledKey) private var diarEnabled = true

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

                Section {
                    Toggle("話者ターンで区切る", isOn: $diarEnabled)
                } header: {
                    Text("話者分離")
                } footer: {
                    Text("複数人の会話で、話者が変わった点で発話を分ける(オンデバイス)。"
                        + "off だと間(無音)でしか切れず、掛け合いは 1 行に merge される。変更は次回の開始から反映。")
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

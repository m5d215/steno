import Foundation

/// 設定値。SettingsView は同じキーで @AppStorage bind し、非 UI 層(Shipper)はここから読む。
/// UserDefaults が SSOT なので設定変更は次の送信ループから即反映される。
enum Config {
    static let endpointKey = "endpoint"   // 例: http://100.x.y.z:8787 (Tailscale の宛先ベース URL)
    static let tokenKey = "token"         // Bearer トークン
    static let deviceIdKey = "deviceId"   // 送信元の識別子(サーバ側 dedup キーの一部)
    static let diarEnabledKey = "diarEnabled"  // 話者ターンで発話を区切るか(既定 on)
    static let voiceProcessingKey = "voiceProcessing"  // Apple のノイズ抑制+AGC(既定 off、実験)

    static let defaultDeviceId = "iphone"

    static var endpoint: String { UserDefaults.standard.string(forKey: endpointKey) ?? "" }
    static var token: String { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
    static var deviceId: String {
        let v = UserDefaults.standard.string(forKey: deviceIdKey) ?? ""
        return v.isEmpty ? defaultDeviceId : v
    }

    /// 話者ターン区切り(オンデバイス話者分離)。未設定なら on。
    static var diarEnabled: Bool {
        UserDefaults.standard.object(forKey: diarEnabledKey) as? Bool ?? true
    }

    /// Apple の voice processing(ノイズ抑制 + AGC)。未設定なら off(実験用トグル)。
    static var voiceProcessingEnabled: Bool {
        UserDefaults.standard.bool(forKey: voiceProcessingKey)
    }
}

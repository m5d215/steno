import AVFoundation
import Foundation

/// 入力(マイク)デバイスの 1 件。UI の picker と pin 指定に使う。
/// uid は AVCaptureDevice.uniqueID(MicCapturer の AVCaptureSession がこれでデバイスを固定する)。
struct AudioInputDevice: Identifiable, Hashable {
    var id: String { uid }
    let uid: String
    let name: String
}

enum AudioDevices {
    /// 録音可能な入力デバイス一覧(picker 用)。AVCaptureDevice で列挙する。
    /// MicCapturer は AVCaptureSession で uniqueID 指定によりデバイスを固定するので、
    /// 列挙もここに揃える(Core Audio の UID とは別系統)。
    static func inputDevices() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified)
        return discovery.devices.map {
            AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName)
        }
    }
}

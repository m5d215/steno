import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// 今 system 出力に音を出しているアプリ名を Core Audio の process object から引く。
///
/// system tap は global なミックスダウン(全プロセスの音を 1 本に束ねる)なので、バッファ自体には
/// 出元プロセスの情報が無い。確定発話のたびにここで「今出力中のプロセス」を点読みして、
/// source=system の app ラベルにする(heuristic)。前面アプリ名(frontmost window)より遥かに
/// 当てになる: 通話中は Teams 等が継続して output を握るので、確定の瞬間に読んでも妥当に当たる。
///
/// 厳密な「このバッファはこのプロセスの音」ではない(複数同時出力なら集合になる)。だが用途は
/// 後段の文脈付け・ノイズ切り分け(BGM が system に混じったとき app=Music で落とせる)なので十分。
enum OutputProcesses {
    /// 今出力中のアプリ名(複数なら ", " 連結)。出力なし/取得不可なら nil。
    static func currentOutputAppName() -> String? {
        let names = currentOutputAppNames()
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// 今出力中のアプリ名一覧(重複除去・順序維持)。自プロセスは除外。
    static func currentOutputAppNames() -> [String] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for obj in processObjectList() {
            let running = scalarProp(obj, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0
            guard running != 0 else { continue }
            let pid = scalarProp(obj, kAudioProcessPropertyPID, initial: pid_t(-1)) ?? -1
            guard pid > 0, pid != selfPID else { continue }
            // GUI アプリは localizedName が綺麗("Microsoft Teams")。NSRunningApplication が引けない
            // daemon(coreaudiod 等)は自然に弾かれる。最後の砦として bundleID。
            if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
                names.append(name)
            } else if let bid = bundleID(obj), !bid.isEmpty {
                names.append(bid)
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    // MARK: - Core Audio property 読み取り

    private static func processObjectList() -> [AudioObjectID] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let st = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, $0.baseAddress!)
        }
        return st == noErr ? ids : []
    }

    private static func scalarProp<T>(
        _ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T
    ) -> T? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        return st == noErr ? value : nil
    }

    private static func bundleID(_ obj: AudioObjectID) -> String? {
        scalarProp(obj, kAudioProcessPropertyBundleID, initial: "" as CFString) as String?
    }
}

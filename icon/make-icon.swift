import AppKit
import Foundation

// steno のアプリアイコンを 1 枚の 1024px PNG として描く。
// 出力 PNG → sips/iconutil で .icns に(Makefile の `make icon`)。
// デザイン: ダークな blue-slate のスクワークル + 白い waveform グリフ(音声→テキストの示唆)。

let S: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

guard
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 背景: 角丸スクワークル + 縦グラデーション
let margin = S * 0.06
let rect = NSRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.225
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let top = NSColor(calibratedRed: 0.20, green: 0.26, blue: 0.38, alpha: 1)
let bottom = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.15, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

// 白い waveform グリフを中央に
let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.46, weight: .semibold)
if let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil),
    let sym = base.withSymbolConfiguration(cfg)
{
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    sym.draw(in: NSRect(origin: .zero, size: sym.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let sz = tinted.size
    tinted.draw(
        in: NSRect(x: (S - sz.width) / 2, y: (S - sz.height) / 2, width: sz.width, height: sz.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

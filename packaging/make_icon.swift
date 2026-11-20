import Cocoa

// Renders NowBar's app icon (a dark squircle echoing the HUD: play glyph over a progress bar)
// into packaging/NowBar.icns. Run once after changing the design; the build only copies it:
//   swift packaging/make_icon.swift

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging")
let iconset = root.appendingPathComponent("NowBar.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)          // draw in 1024-pt design space
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon grid: 824-pt body centred in 1024, with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: NSColor(calibratedWhite: 0.24, alpha: 1), ending: NSColor(calibratedWhite: 0.06, alpha: 1))!
        .draw(in: body, angle: -90)
    // faint top sheen
    NSGradient(starting: NSColor(white: 1, alpha: 0.10), ending: NSColor(white: 1, alpha: 0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // play glyph
    let cfg = NSImage.SymbolConfiguration(pointSize: 330, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = play.size
        play.draw(in: NSRect(x: 512 - s.width / 2 + 18, y: 560 - s.height / 2, width: s.width, height: s.height))
    }
    // progress bar: track, fill, knob
    let track = NSRect(x: 252, y: 300, width: 520, height: 26)
    NSColor(white: 1, alpha: 0.25).setFill()
    NSBezierPath(roundedRect: track, xRadius: 13, yRadius: 13).fill()
    var fill = track; fill.size.width *= 0.62
    NSColor.white.setFill()
    NSBezierPath(roundedRect: fill, xRadius: 13, yRadius: 13).fill()
    NSBezierPath(ovalIn: NSRect(x: fill.maxX - 30, y: track.midY - 30, width: 60, height: 60)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("NowBar.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(root.path)/NowBar.icns" : "iconutil failed")

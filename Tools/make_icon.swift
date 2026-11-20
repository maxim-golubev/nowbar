import Cocoa

// Draws NowBar's app icon, a graphite tile echoing the HUD (a play glyph over a progress
// bar), into the files that are committed and copied by the build:
//   Resources/NowBar.icns                        the app icon, 16 to 1024 px
//   docs/images/icon-light.png, icon-dark.png    the README's icon, for light and dark pages
// Run from the repository root after changing the design:
//   swift Tools/make_icon.swift

enum Variant { case app, light, dark }

/// The icon in a 1024-pt design space. `grid` is the share of the canvas the tile fills:
/// macOS's icon grid (824 of 1024) for the app; for a web page, where the margin is only
/// empty space, just enough room is kept for the shadow.
func render(pixels: Int, grid: CGFloat, variant: Variant) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let side = 1024 * grid, inset = (1024 - side) / 2
    let body = NSRect(x: inset, y: inset + side * 0.012, width: side, height: side)
    let tile = NSBezierPath(roundedRect: body, xRadius: side * 0.2245, yRadius: side * 0.2245)
    let unit = side / 824                                    // artwork below is drawn for an 824-pt tile

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(variant == .dark ? 0.5 : 0.35)
    shadow.shadowBlurRadius = 24 * unit; shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
    shadow.set()
    NSColor.black.setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let (top, bottom): (CGFloat, CGFloat) = variant == .dark ? (0.30, 0.11) : (0.24, 0.06)
    NSGradient(starting: NSColor(calibratedWhite: top, alpha: 1), ending: NSColor(calibratedWhite: bottom, alpha: 1))!
        .draw(in: body, angle: -90)
    NSGradient(starting: NSColor(white: 1, alpha: 0.10), ending: NSColor(white: 1, alpha: 0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    if variant == .dark {                                    // a hairline rim keeps the tile off a dark page
        NSColor(white: 1, alpha: 0.14).setStroke()
        let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5 * unit, dy: 1.5 * unit),
                               xRadius: side * 0.2245, yRadius: side * 0.2245)
        rim.lineWidth = 3 * unit; rim.stroke()
    }

    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: body.minX + x * unit, y: body.minY + y * unit) }
    let cfg = NSImage.SymbolConfiguration(pointSize: 330 * unit, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = play.size, c = p(430, 460)
        play.draw(in: NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
    }
    let track = NSRect(origin: p(152, 200), size: NSSize(width: 520 * unit, height: 26 * unit))
    NSColor(white: 1, alpha: 0.25).setFill()
    NSBezierPath(roundedRect: track, xRadius: 13 * unit, yRadius: 13 * unit).fill()
    var fill = track; fill.size.width *= 0.62
    NSColor.white.setFill()
    NSBezierPath(roundedRect: fill, xRadius: 13 * unit, yRadius: 13 * unit).fill()
    let k = 60 * unit
    NSBezierPath(ovalIn: NSRect(x: fill.maxX - k / 2, y: track.midY - k / 2, width: k, height: k)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NowBar.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! render(pixels: points * factor, grid: 824 / 1024, variant: .app).write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/NowBar.icns"]
try! iconutil.run(); iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try! fm.createDirectory(atPath: "docs/images", withIntermediateDirectories: true)
try! render(pixels: 256, grid: 944 / 1024, variant: .light).write(to: URL(fileURLWithPath: "docs/images/icon-light.png"))
try! render(pixels: 256, grid: 944 / 1024, variant: .dark).write(to: URL(fileURLWithPath: "docs/images/icon-dark.png"))
print("Wrote Resources/NowBar.icns, docs/images/icon-light.png and icon-dark.png")

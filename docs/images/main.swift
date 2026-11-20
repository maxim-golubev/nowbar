// Draws the README's animation off-screen with the app's own HUD view: the top-right corner of
// a screen as Mission Control opens, NowBar fading in with it, a pause and a skip clicked
// inside Mission Control, and Mission Control closing with NowBar fading out. One set of
// frames per page colour (GitHub's light and dark). Tracks and covers are made up.
//
//   swiftc -O -framework Cocoa -framework ApplicationServices -framework ServiceManagement \
//       -o "$TMPDIR/nowbar-hero" docs/images/main.swift $(ls Sources/*.swift | grep -v /main.swift)
//   "$TMPDIR/nowbar-hero" "$TMPDIR/hero"
//   for t in light dark; do ffmpeg -y -f concat -i "$TMPDIR/hero/$t.txt" -filter_complex \
//       "split[a][b];[a]palettegen=max_colors=192:stats_mode=full[p];[b][p]paletteuse=dither=none" \
//       -loop 0 docs/images/hero-$t.gif; done
import Cocoa

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hero"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
_ = NSApplication.shared

// ---- scene geometry (points; origin bottom-left of the screen crop) ----
let scale: CGFloat = 2
let pad: CGFloat = 14
let crop = NSSize(width: 640, height: 352)
let canvas = NSSize(width: crop.width + pad * 2, height: crop.height + pad * 2)
let menuBarH: CGFloat = 24
let hudOrigin = NSPoint(x: crop.width - 12 - Layout.W, y: crop.height - menuBarH - 12 - Layout.H)

func ease(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func mix(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
    NSRect(x: mix(a.minX, b.minX, t), y: mix(a.minY, b.minY, t), width: mix(a.width, b.width, t), height: mix(a.height, b.height, t))
}

// Two app windows: where they sit on the desktop, and their Mission Control thumbnails.
let windowA = (desk: NSRect(x: 26, y: -40, width: 470, height: 300), mc: NSRect(x: 40, y: 54, width: 268, height: 171))
let windowB = (desk: NSRect(x: 250, y: -110, width: 420, height: 270), mc: NSRect(x: 340, y: 40, width: 236, height: 152))

struct Theme { let name: String; let page: NSColor; let dark: Bool }
let themes = [Theme(name: "light", page: .white, dark: false),
              Theme(name: "dark", page: NSColor(srgbRed: 0x0d / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1), dark: true)]

// ---- made-up tracks with drawn covers ----
func cover(_ c1: NSColor, _ c2: NSColor, rings: Bool) -> NSImage {
    NSImage(size: NSSize(width: 300, height: 300), flipped: false) { r in
        NSGradient(starting: c1, ending: c2)!.draw(in: r, angle: -55)
        if rings {
            for i in 0..<5 {
                let d = CGFloat(70 + i * 46)
                NSColor(white: 1, alpha: 0.16).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: 210 - d / 2, y: 90 - d / 2, width: d, height: d))
                ring.lineWidth = 9; ring.stroke()
            }
        } else {
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 168, y: 160, width: 70, height: 70)).fill()
            NSColor(white: 0, alpha: 0.18).setFill()
            for i in 0..<4 { NSRect(x: 0, y: CGFloat(i) * 26 + 20, width: 300, height: 9).fill() }
        }
        return true
    }
}
struct Track { let title: String, artist: String, duration: Double, art: NSImage }
let tracks = [
    Track(title: "Glass Harbor", artist: "The Quiet Engines", duration: 247,
          art: cover(NSColor(srgbRed: 0.98, green: 0.55, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.80, green: 0.18, blue: 0.45, alpha: 1), rings: false)),
    Track(title: "Nightline", artist: "Mara Vell", duration: 214,
          art: cover(NSColor(srgbRed: 0.16, green: 0.72, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.13, green: 0.25, blue: 0.62, alpha: 1), rings: true)),
]

// ---- one frame's state ----
struct Frame {
    var mc: CGFloat = 0           // Mission Control open fraction, 0…1
    var hudAlpha: CGFloat = 0
    var track = 0
    var elapsed = 72.0
    var playing = true
    var cursor: NSPoint? = nil    // crop coordinates of the arrow's tip
    var ripple: NSPoint? = nil    // a click being made here
    var duration: Double = 0.04   // seconds on screen
}

// ---- drawing ----
let hudView = HUDView(frame: NSRect(x: 0, y: 0, width: Layout.W, height: Layout.H))
func hudImage(_ f: Frame) -> NSImage {
    let t = tracks[f.track]
    var n = NowPlaying()
    n.title = t.title; n.artist = t.artist; n.duration = t.duration
    n.elapsed = f.elapsed; n.playing = f.playing; n.stamp = Date()
    hudView.np = n; hudView.art = t.art
    let rep = hudView.bitmapImageRepForCachingDisplay(in: hudView.bounds)!
    hudView.cacheDisplay(in: hudView.bounds, to: rep)
    let img = NSImage(size: hudView.bounds.size); img.addRepresentation(rep)
    return img
}

func drawWallpaper(_ r: NSRect) {
    NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.20, blue: 0.48, alpha: 1),
                        NSColor(srgbRed: 0.42, green: 0.25, blue: 0.58, alpha: 1),
                        NSColor(srgbRed: 0.86, green: 0.47, blue: 0.45, alpha: 1)])!.draw(in: r, angle: -32)
    for (c, x, y, d) in [(NSColor(srgbRed: 1, green: 0.75, blue: 0.5, alpha: 0.22), 0.86, 0.12, 360.0),
                         (NSColor(srgbRed: 0.45, green: 0.6, blue: 1, alpha: 0.18), 0.1, 0.9, 420.0)] as [(NSColor, CGFloat, CGFloat, CGFloat)] {
        let center = NSPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        NSGradient(starting: c, ending: c.withAlphaComponent(0))!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: d / 2, options: [])
    }
}

func drawWindow(_ r: NSRect, dark: Bool, kind: Int) {
    let radius = max(6, 11 * r.width / 470)
    let u = r.width / 470                                   // window art is drawn for a 470-pt window
    let body = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
    sh.shadowBlurRadius = 18 * u; sh.shadowOffset = NSSize(width: 0, height: -6 * u); sh.set()
    (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.98, alpha: 1)).setFill(); body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); body.addClip()
    // title bar
    let bar = NSRect(x: r.minX, y: r.maxY - 30 * u, width: r.width, height: 30 * u)
    (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); bar.fill()
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + (14 + CGFloat(i) * 19) * u, y: bar.midY - 6 * u, width: 12 * u, height: 12 * u)).fill()
    }
    let ink = dark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.08)
    ink.setFill()
    if kind == 0 {   // a sidebar and text lines
        NSRect(x: r.minX, y: r.minY, width: 120 * u, height: r.height - 30 * u).fill()
        for i in 0..<9 {
            let w = [300, 260, 320, 180, 290, 240, 310, 200, 270][i]
            NSBezierPath(roundedRect: NSRect(x: r.minX + 146 * u, y: bar.minY - CGFloat(28 + i * 24) * u,
                                             width: CGFloat(w) * u, height: 9 * u), xRadius: 4 * u, yRadius: 4 * u).fill()
        }
    } else {         // a grid of tiles
        for row in 0..<3 { for col in 0..<4 {
            NSBezierPath(roundedRect: NSRect(x: r.minX + CGFloat(18 + col * 100) * u, y: bar.minY - CGFloat(96 + row * 84) * u,
                                             width: 86 * u, height: 70 * u), xRadius: 8 * u, yRadius: 8 * u).fill()
        } }
    }
    NSGraphicsContext.restoreGraphicsState()
}

func text(_ s: String, at p: NSPoint, size: CGFloat, alpha: CGFloat, weight: NSFont.Weight = .medium) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: NSColor(white: 1, alpha: alpha)]
    s.draw(at: p, withAttributes: attrs)
}

func render(_ f: Frame, theme: Theme) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    theme.page.setFill(); NSRect(origin: .zero, size: canvas).fill()

    let screen = NSRect(x: pad, y: pad, width: crop.width, height: crop.height)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 12, yRadius: 12)
    NSGraphicsContext.saveGraphicsState()
    screenPath.addClip()
    let xf = NSAffineTransform(); xf.translateX(by: pad, yBy: pad); xf.concat()
    let local = NSRect(origin: .zero, size: crop)
    let t = ease(f.mc)

    drawWallpaper(local)
    NSColor(white: 0, alpha: 0.28 * t).setFill(); local.fill()           // Mission Control dims the desktop

    // spaces bar (Mission Control) and menu bar (desktop) trade places
    text("Desktop 1", at: NSPoint(x: 150, y: crop.height - 30 + 10 * (1 - t)), size: 12, alpha: 0.95 * t)
    text("Desktop 2", at: NSPoint(x: 240, y: crop.height - 30 + 10 * (1 - t)), size: 12, alpha: 0.6 * t)
    NSColor(white: 1, alpha: 0.22 * (1 - t)).setFill()
    NSRect(x: 0, y: crop.height - menuBarH, width: crop.width, height: menuBarH).fill()
    text("Thu 14:05", at: NSPoint(x: crop.width - 76, y: crop.height - 18), size: 12, alpha: 0.95 * (1 - t))
    let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.95 * (1 - t))]))
    if let item = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        item.draw(at: NSPoint(x: crop.width - 104, y: crop.height - 19), from: .zero, operation: .sourceOver, fraction: 1)
    }

    drawWindow(mix(windowA.desk, windowA.mc, t), dark: theme.dark, kind: 0)
    drawWindow(mix(windowB.desk, windowB.mc, t), dark: theme.dark, kind: 1)

    if f.hudAlpha > 0 {
        let hud = hudImage(f)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.45 * f.hudAlpha)
        sh.shadowBlurRadius = 16; sh.shadowOffset = NSSize(width: 0, height: -5); sh.set()
        hud.draw(in: NSRect(origin: hudOrigin, size: hud.size), from: .zero, operation: .sourceOver, fraction: f.hudAlpha)
        NSGraphicsContext.restoreGraphicsState()
    }
    if let r = f.ripple {
        NSColor(white: 1, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.x - 15, y: r.y - 15, width: 30, height: 30)).fill()
    }
    if let c = f.cursor {
        let arrow = NSCursor.arrow.image, hot = NSCursor.arrow.hotSpot
        arrow.draw(in: NSRect(x: c.x - hot.x, y: c.y - (arrow.size.height - hot.y), width: arrow.size.width, height: arrow.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()

    NSColor(white: theme.dark ? 1 : 0, alpha: theme.dark ? 0.10 : 0.12).setStroke()
    let rim = NSBezierPath(roundedRect: screen.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
    rim.lineWidth = 1; rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ---- the timeline ----
func onHUD(_ r: NSRect) -> NSPoint { NSPoint(x: hudOrigin.x + r.midX, y: hudOrigin.y + r.midY) }
var frames: [Frame] = []
var f = Frame()
f.duration = 1.0; frames.append(f)                                    // the desktop
for i in 1...10 {                                                     // a swipe up: NowBar fades in with it
    f.mc = CGFloat(i) / 10; f.hudAlpha = f.mc; f.elapsed += 0.04; f.duration = 0.04; frames.append(f)
}
f.duration = 0.7; frames.append(f)
f.elapsed += 1; frames.append(f)
let start = NSPoint(x: 250, y: 120), play = onHUD(Layout.playRect), next = onHUD(Layout.nextRect)
for i in 1...8 {                                                      // the pointer goes to pause
    let k = ease(CGFloat(i) / 8)
    f.cursor = NSPoint(x: mix(start.x, play.x, k), y: mix(start.y, play.y, k)); f.duration = 0.035; frames.append(f)
}
f.ripple = play; f.playing = false; f.duration = 0.12; frames.append(f)
f.ripple = nil; f.duration = 1.0; frames.append(f)
for i in 1...5 {                                                      // then to skip
    let k = ease(CGFloat(i) / 5)
    f.cursor = NSPoint(x: mix(play.x, next.x, k), y: mix(play.y, next.y, k)); f.duration = 0.035; frames.append(f)
}
f.ripple = next; f.track = 1; f.elapsed = 0; f.playing = true; f.duration = 0.12; frames.append(f)
f.ripple = nil; f.duration = 0.8; frames.append(f)
f.elapsed += 1; frames.append(f)
f.cursor = nil; f.duration = 0.3; frames.append(f)
for i in stride(from: 9, through: 0, by: -1) {                        // a swipe down: NowBar fades out with it
    f.mc = CGFloat(i) / 10; f.hudAlpha = f.mc; f.elapsed += 0.04; f.duration = 0.04; frames.append(f)
}
f.duration = 0.9; frames.append(f)

for theme in themes {
    var list = ""
    for (i, frame) in frames.enumerated() {
        let name = String(format: "%@-%02d.png", theme.name, i)
        try! render(frame, theme: theme).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        list += "file '\(name)'\nduration \(frame.duration)\n"
    }
    list += "file '\(String(format: "%@-%02d.png", theme.name, frames.count - 1))'\n"   // concat needs the last frame twice
    try! list.write(toFile: (out as NSString).appendingPathComponent("\(theme.name).txt"), atomically: true, encoding: .utf8)
}
print("wrote \(frames.count) frames per theme to \(out)")

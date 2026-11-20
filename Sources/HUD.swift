import Cocoa

// ---------------------------------------------------------------------------
// HUD geometry — regions shared by native clicks and the Mission Control tap
// ---------------------------------------------------------------------------
enum Region { case prev, playpause, next, seek(Double), none }

struct Layout {
    // Rows, bottom to top: times, seek bar, buttons, artist, title. The times sit in their own
    // row with clear space above them, so the bar's knob never touches them.
    static let W: CGFloat = 276, H: CGFloat = 108
    static let art = NSRect(x: 12, y: (H - 74) / 2, width: 74, height: 74)
    static let contentX: CGFloat = 98
    static let titleY: CGFloat = 82, artistY: CGFloat = 64
    static let btnY: CGFloat = 38, btnSize: CGFloat = 22, btnGap: CGFloat = 20
    static var btnCenterX: CGFloat { (contentX + W - 12) / 2 }
    static let barRect = NSRect(x: contentX, y: 25, width: W - contentX - 12, height: 4)
    static let timesRect = NSRect(x: contentX, y: 6, width: W - contentX - 12, height: 13)

    static var prevRect: NSRect  { NSRect(x: btnCenterX - btnGap - btnSize*1.5, y: btnY-2, width: btnSize, height: btnSize) }
    static var playRect: NSRect  { NSRect(x: btnCenterX - btnSize/2,            y: btnY-2, width: btnSize, height: btnSize) }
    static var nextRect: NSRect  { NSRect(x: btnCenterX + btnGap + btnSize*0.5, y: btnY-2, width: btnSize, height: btnSize) }

    static func barFraction(_ x: CGFloat) -> Double {
        Double(max(0, min(1, (x - barRect.minX) / barRect.width)))
    }

    // hit-test a point in view-local (bottom-left) coords
    static func region(at p: NSPoint) -> Region {
        if prevRect.insetBy(dx: -6, dy: -6).contains(p) { return .prev }
        if playRect.insetBy(dx: -6, dy: -6).contains(p) { return .playpause }
        if nextRect.insetBy(dx: -6, dy: -6).contains(p) { return .next }
        if barRect.insetBy(dx: -4, dy: -10).contains(p) { return .seek(barFraction(p.x)) }
        return .none
    }
}

// ---------------------------------------------------------------------------
// HUD view
// ---------------------------------------------------------------------------
final class HUDView: NSView {
    var np = NowPlaying()
    var art: NSImage?
    var notice: String?          // replaces track info when the engine can't run
    var scrub: Double?           // bar fraction while the user drags; seek is sent on release

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    private static let titleAttrs = attrs(size: 12, weight: .semibold, color: .white)
    private static let artistAttrs = attrs(size: 10, weight: .regular, color: NSColor(white: 0.7, alpha: 1))
    private static let timeAttrs = attrs(size: 9, weight: .regular, color: NSColor(white: 0.6, alpha: 1), mono: true)
    private static let timeAttrsRight = attrs(size: 9, weight: .regular, color: NSColor(white: 0.6, alpha: 1), mono: true, right: true)
    private static var glyphs: [String: NSImage] = [:]

    private static func attrs(size: CGFloat, weight: NSFont.Weight, color: NSColor,
                              mono: Bool = false, right: Bool = false) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        style.alignment = right ? .right : .left
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    // SF Symbols rendered white once and cached (they're redrawn several times a second).
    private static func glyph(_ name: String, size: CGFloat = 11, color: NSColor = .white) -> NSImage? {
        let key = "\(name)/\(size)/\(color)"
        if let g = glyphs[key] { return g }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let g = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        glyphs[key] = g
        return g
    }

    override func draw(_ r: NSRect) {
        // rounded dark background
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        // artwork, aspect-filled (video/podcast art is often not square)
        let artPath = NSBezierPath(roundedRect: Layout.art, xRadius: 7, yRadius: 7)
        NSColor(white: 0.2, alpha: 1).setFill(); artPath.fill()
        if let a = art, a.size.width > 0, a.size.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            artPath.addClip()
            let s = a.size, side = min(s.width, s.height)
            let src = NSRect(x: (s.width - side) / 2, y: (s.height - side) / 2, width: side, height: side)
            a.draw(in: Layout.art, from: src, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else if let g = Self.glyph("music.note", size: 26, color: NSColor(white: 0.45, alpha: 1)) {
            center(g, in: Layout.art)
        }

        let cW = Layout.W - Layout.contentX - 12
        let title = notice ?? (np.isEmpty ? "Nothing playing" : np.title)
        let sub = notice != nil ? "brew install media-control" : np.artist
        title.draw(with: NSRect(x: Layout.contentX, y: Layout.titleY, width: cW, height: 18),
                   options: [.usesLineFragmentOrigin], attributes: Self.titleAttrs)
        sub.draw(with: NSRect(x: Layout.contentX, y: Layout.artistY, width: cW, height: 16),
                 options: [.usesLineFragmentOrigin], attributes: Self.artistAttrs)

        // transport glyphs
        if let g = Self.glyph("backward.fill") { center(g, in: Layout.prevRect) }
        if let g = Self.glyph(np.playing ? "pause.fill" : "play.fill") { center(g, in: Layout.playRect) }
        if let g = Self.glyph("forward.fill") { center(g, in: Layout.nextRect) }

        // progress bar (shows the scrub position while dragging)
        let elapsed = scrub.map { $0 * np.duration } ?? np.liveElapsed()
        let frac = np.duration > 0 ? CGFloat(elapsed / np.duration) : 0
        NSColor(white: 0.3, alpha: 1).setFill()
        NSBezierPath(roundedRect: Layout.barRect, xRadius: 2, yRadius: 2).fill()
        var fill = Layout.barRect; fill.size.width *= max(0, min(1, frac))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        if np.duration > 0 {
            let k: CGFloat = scrub != nil ? 11 : 9
            let knob = NSRect(x: Layout.barRect.minX + fill.width - k/2, y: Layout.barRect.midY - k/2, width: k, height: k)
            NSBezierPath(ovalIn: knob).fill()
        }
        // time labels
        let times = Layout.timesRect
        mmss(elapsed).draw(with: times, options: [.usesLineFragmentOrigin], attributes: Self.timeAttrs)
        mmss(np.duration).draw(with: times, options: [.usesLineFragmentOrigin], attributes: Self.timeAttrsRight)
    }

    private func center(_ img: NSImage, in rect: NSRect) {
        let s = img.size
        img.draw(in: NSRect(x: rect.midX - s.width/2, y: rect.midY - s.height/2, width: s.width, height: s.height))
    }

    // native interaction (when NOT in Mission Control)
    override func mouseDown(with e: NSEvent) {
        Controller.shared.press(at: convert(e.locationInWindow, from: nil))
    }
    override func mouseDragged(with e: NSEvent) {
        Controller.shared.drag(to: convert(e.locationInWindow, from: nil))
    }
    override func mouseUp(with e: NSEvent) { Controller.shared.release() }
}

final class HUDPanel: NSPanel { override var canBecomeKey: Bool { false } }

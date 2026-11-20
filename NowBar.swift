import Cocoa
import ApplicationServices

// ============================================================================
// NowBar — a "better Now Playing": a menu-bar app whose floating controller
// stays usable inside Mission Control.
//
//  • Click the menu-bar icon  -> HUD appears top-right of the ACTIVE monitor.
//  • Works in normal use (native clicks) AND inside Mission Control (HID tap).
//  • Auto-arms when Mission Control opens (toggle), auto-hides after inactivity.
//  • Engine: the `media-control` CLI (reads/controls any app's Now Playing).
// ============================================================================

let MEDIA_CONTROL = "/opt/homebrew/bin/media-control"
let VERBOSE = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("--selftest")
func vlog(_ s: String) { if VERBOSE { FileHandle.standardError.write(("[NowBar] " + s + "\n").data(using: .utf8)!) } }

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
struct NowPlaying {
    var title = "", artist = "", album = "", bundleID = "", contentID = ""
    var duration = 0.0, elapsed = 0.0, rate = 1.0
    var playing = false
    var stamp = Date()           // when `elapsed` was measured
    func liveElapsed() -> Double {
        guard playing, duration > 0 else { return min(elapsed, duration > 0 ? duration : elapsed) }
        return min(duration, elapsed + Date().timeIntervalSince(stamp) * rate)
    }
}

func mmss(_ t: Double) -> String {
    if t.isNaN || t < 0 { return "0:00" }
    let s = Int(t.rounded()); return String(format: "%d:%02d", s/60, s%60)
}

// ---------------------------------------------------------------------------
// media-control engine: a long-lived `stream` plus fire-and-forget commands
// ---------------------------------------------------------------------------
final class Engine {
    var onUpdate: ((NowPlaying) -> Void)?
    private(set) var np = NowPlaying()
    private var merged: [String: Any] = [:]
    private var stream: Process?
    private var lineBuf = ""
    private var lastArtKey = ""
    var artwork: NSImage?

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: MEDIA_CONTROL)
        p.arguments = ["stream", "--no-artwork"]      // metadata + position; art fetched separately
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData; if d.isEmpty { return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            self?.feed(s)
        }
        do { try p.run(); stream = p; vlog("stream started") }
        catch { vlog("stream failed: \(error)") }
        refreshOnce()
    }

    private func feed(_ chunk: String) {
        lineBuf += chunk
        while let nl = lineBuf.firstIndex(of: "\n") {
            let line = String(lineBuf[..<nl]); lineBuf = String(lineBuf[lineBuf.index(after: nl)...])
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            ingest(line)
        }
    }

    private func ingest(_ line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        for (k, v) in obj { merged[k] = v }
        var n = NowPlaying()
        n.title    = merged["title"] as? String ?? ""
        n.artist   = merged["artist"] as? String ?? ""
        n.album    = merged["album"] as? String ?? ""
        n.bundleID = merged["bundleIdentifier"] as? String ?? ""
        n.contentID = merged["contentItemIdentifier"] as? String ?? ""
        n.duration = (merged["duration"] as? Double) ?? 0
        n.elapsed  = (merged["elapsedTime"] as? Double) ?? 0
        n.rate     = (merged["playbackRate"] as? Double) ?? 1
        n.playing  = (merged["playing"] as? Bool) ?? false
        if let tsStr = merged["timestamp"] as? String {
            let f = ISO8601DateFormatter(); n.stamp = f.date(from: tsStr) ?? Date()
        } else { n.stamp = Date() }
        let trackKey = n.contentID.isEmpty ? (n.title + "|" + n.artist) : n.contentID
        DispatchQueue.main.async {
            self.np = n
            self.onUpdate?(n)
            if trackKey != self.lastArtKey { self.lastArtKey = trackKey; self.fetchArtwork(for: n, key: trackKey) }
        }
    }

    func refreshOnce() {
        DispatchQueue.global().async {
            let out = run([MEDIA_CONTROL], ["get"])
            if !out.isEmpty { DispatchQueue.main.async { self.ingest(out) } }
        }
    }

    // Artwork: MediaRemote artworkData when available, else per-app URL (Spotify), else nil.
    private func fetchArtwork(for n: NowPlaying, key: String) {
        DispatchQueue.global().async {
            var img: NSImage?
            // 1) try media-control get WITH artwork
            let out = run([MEDIA_CONTROL], ["get"])
            if let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
               let b64 = d["artworkData"] as? String, let data = Data(base64Encoded: b64) {
                img = NSImage(data: data)
            }
            // 2) Spotify URL fallback
            if img == nil, n.bundleID == "com.spotify.client" {
                let url = run(["/usr/bin/osascript"], ["-e", "tell application \"Spotify\" to artwork url of current track"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if url.hasPrefix("http"), let u = URL(string: url), let data = try? Data(contentsOf: u) {
                    img = NSImage(data: data)
                }
            }
            DispatchQueue.main.async {
                guard self.lastArtKey == key else { return }   // track changed meanwhile
                self.artwork = img
                self.onUpdate?(self.np)
            }
        }
    }

    func command(_ name: String) { DispatchQueue.global().async { _ = run([MEDIA_CONTROL], [name]) }; refreshSoon() }
    func seek(_ seconds: Double) { DispatchQueue.global().async { _ = run([MEDIA_CONTROL], ["seek", String(format: "%.2f", max(0, seconds))]) }; refreshSoon() }
    private func refreshSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refreshOnce() } }
}

@discardableResult
func run(_ exe: [String], _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe[0]); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// ---------------------------------------------------------------------------
// HUD geometry — regions shared by native clicks and the Mission Control tap
// ---------------------------------------------------------------------------
enum Region { case prev, playpause, next, seek(Double), none }

struct Layout {
    static let W: CGFloat = 276, H: CGFloat = 100
    static let art = NSRect(x: 12, y: 13, width: 74, height: 74)
    static let contentX: CGFloat = 98
    static let titleY: CGFloat = 72, artistY: CGFloat = 54
    static let btnY: CGFloat = 26, btnSize: CGFloat = 22, btnGap: CGFloat = 20
    static var btnCenterX: CGFloat { (contentX + W - 12) / 2 }
    static let barRect = NSRect(x: contentX, y: 13, width: W - contentX - 12, height: 4)

    static var prevRect: NSRect  { NSRect(x: btnCenterX - btnGap - btnSize*1.5, y: btnY-2, width: btnSize, height: btnSize) }
    static var playRect: NSRect  { NSRect(x: btnCenterX - btnSize/2,            y: btnY-2, width: btnSize, height: btnSize) }
    static var nextRect: NSRect  { NSRect(x: btnCenterX + btnGap + btnSize*0.5, y: btnY-2, width: btnSize, height: btnSize) }

    // hit-test a point in view-local (bottom-left) coords
    static func region(at p: NSPoint) -> Region {
        if prevRect.insetBy(dx: -6, dy: -6).contains(p) { return .prev }
        if playRect.insetBy(dx: -6, dy: -6).contains(p) { return .playpause }
        if nextRect.insetBy(dx: -6, dy: -6).contains(p) { return .next }
        let bar = barRect.insetBy(dx: -4, dy: -10)
        if bar.contains(p) {
            let frac = max(0, min(1, (p.x - barRect.minX) / barRect.width))
            return .seek(Double(frac))
        }
        return .none
    }
}

// ---------------------------------------------------------------------------
// HUD view
// ---------------------------------------------------------------------------
final class HUDView: NSView {
    var np = NowPlaying()
    var art: NSImage?
    var dragging = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func draw(_ r: NSRect) {
        // rounded dark background
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor(white: 0.08, alpha: 0.92).setFill(); bg.fill()

        // artwork
        let artPath = NSBezierPath(roundedRect: Layout.art, xRadius: 7, yRadius: 7)
        NSColor(white: 0.2, alpha: 1).setFill(); artPath.fill()
        if let a = art {
            artPath.setClip()
            a.draw(in: Layout.art, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            // reset clip
            NSGraphicsContext.current?.restoreGraphicsState(); NSGraphicsContext.current?.saveGraphicsState()
        }

        let cW = Layout.W - Layout.contentX - 12
        drawText(np.title.isEmpty ? "Nothing playing" : np.title, x: Layout.contentX, y: Layout.titleY,
                 w: cW, size: 12, weight: .semibold, color: .white)
        drawText(np.artist, x: Layout.contentX, y: Layout.artistY, w: cW, size: 10, weight: .regular,
                 color: NSColor(white: 0.7, alpha: 1))

        // transport glyphs
        symbol("backward.fill", in: Layout.prevRect)
        symbol(np.playing ? "pause.fill" : "play.fill", in: Layout.playRect)
        symbol("forward.fill", in: Layout.nextRect)

        // progress bar
        let frac = np.duration > 0 ? CGFloat(np.liveElapsed() / np.duration) : 0
        NSColor(white: 0.3, alpha: 1).setFill()
        NSBezierPath(roundedRect: Layout.barRect, xRadius: 2.5, yRadius: 2.5).fill()
        var fill = Layout.barRect; fill.size.width *= max(0, min(1, frac))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        // knob
        let knob = NSRect(x: Layout.barRect.minX + fill.width - 4, y: Layout.barRect.midY - 5, width: 9, height: 9)
        NSColor.white.setFill(); NSBezierPath(ovalIn: knob).fill()
        // time labels
        drawText(mmss(np.liveElapsed()), x: Layout.contentX, y: 0, w: 54, size: 8, weight: .regular, color: NSColor(white: 0.6, alpha: 1))
        let dur = mmss(np.duration)
        drawText(dur, x: Layout.W - 12 - 54, y: 0, w: 54, size: 8, weight: .regular, color: NSColor(white: 0.6, alpha: 1), right: true)
    }

    private func symbol(_ name: String, in rect: NSRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - s.width/2, y: rect.midY - s.height/2, width: s.width, height: s.height))
    }

    private func drawText(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat,
                          weight: NSFont.Weight, color: NSColor, right: Bool = false) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        style.alignment = right ? .right : .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
        s.draw(with: NSRect(x: x, y: y, width: w, height: size + 6), options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    // native interaction (when NOT in Mission Control)
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch Layout.region(at: p) {
        case .prev: Controller.shared.engine.command("previous-track")
        case .next: Controller.shared.engine.command("next-track")
        case .playpause: Controller.shared.engine.command("toggle-play-pause")
        case .seek(let f): dragging = true; Controller.shared.seekFraction(f)
        case .none: break
        }
    }
    override func mouseDragged(with e: NSEvent) {
        guard dragging else { return }
        let p = convert(e.locationInWindow, from: nil)
        let f = max(0, min(1, (p.x - Layout.barRect.minX) / Layout.barRect.width))
        Controller.shared.seekFraction(Double(f))
    }
    override func mouseUp(with e: NSEvent) { dragging = false }
}

final class HUDPanel: NSPanel { override var canBecomeKey: Bool { false } }

// ---------------------------------------------------------------------------
// Mission Control detection
// ---------------------------------------------------------------------------
func missionControlActive() -> Bool {
    // Mission Control stacks 2+ full-screen Dock windows (layers 20/18/0). A revealed
    // auto-hide Dock makes only ONE, so require at least two to avoid false positives.
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var count = 0
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String) == "Dock" else { continue }
        guard ((w[kCGWindowLayer as String] as? Int) ?? -1) >= 0 else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let wd = (b["Width"] as? Double) ?? 0, ht = (b["Height"] as? Double) ?? 0
        if wd > 1000, ht > 700 { count += 1; if count >= 2 { return true } }
    }
    return false
}

// ---------------------------------------------------------------------------
// Controller — wires everything together
// ---------------------------------------------------------------------------
final class Controller: NSObject {
    static let shared = Controller()
    let engine = Engine()
    var statusItem: NSStatusItem!
    let panel: HUDPanel
    let view: HUDView

    // visibility is driven by two independent reasons:
    var mcShowing = false        // shown because Mission Control is open (hide when it closes)
    var menuShowing = false      // shown because the menu-bar icon was clicked (hide on click-outside)
    var triggerHidden = false    // user triggered an MC close; stay hidden until MC fully gone
    var triggerHideTime = Date.distantPast
    var visible: Bool { mcShowing || menuShowing }
    var outsideMonitor: Any?     // global click monitor for popover-style dismissal

    // geometry the tap reads (CG top-left coords), refreshed when the HUD moves
    var hudGlobalRect = CGRect.zero
    var mcActive = false
    var eventTap: CFMachPort?    // HID tap: intercept clicks in Mission Control
    var moveTap: CFMachPort?     // session tap: suppress hover-through highlight
    var primaryHeight: CGFloat = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? (NSScreen.main?.frame.height ?? 1080)

    override init() {
        view = HUDView(frame: NSRect(x: 0, y: 0, width: Layout.W, height: Layout.H))
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: Layout.W, height: Layout.H),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = NSWindow.Level(rawValue: 25)              // above Mission Control's layer-20 overlay
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.contentView = view
    }

    func start() {
        setupStatusItem()
        engine.onUpdate = { [weak self] np in
            self?.view.np = np; self?.view.art = self?.engine.artwork; self?.view.needsDisplay = true
            self?.updateStatusTitle(np)
        }
        engine.start()
        requestAccessibility()
        installTap()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        vlog("controller started")
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "NowBar")
            b.image?.isTemplate = true
            b.target = self; b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func updateStatusTitle(_ np: NowPlaying) {
        // keep menubar compact: just the glyph; tooltip carries the track
        statusItem.button?.toolTip = np.title.isEmpty ? "NowBar" : "\(np.title) — \(np.artist)"
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggleMenuPopover()
        }
    }

    func showMenu() {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: menuShowing ? "Hide controller" : "Show controller",
                             action: #selector(toggleMenuPopover), keyEquivalent: ""))
        m.items.last?.target = self
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit NowBar", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        m.addItem(q)
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore click-to-toggle for next time
    }

    // Menu-bar click: show as a popover that dismisses on a click outside it.
    @objc func toggleMenuPopover() {
        if menuShowing {
            menuShowing = false; removeOutsideMonitor()
        } else {
            menuShowing = true; installOutsideMonitor()
        }
        updateVisibility()   // positions on the active monitor when it becomes visible
    }

    func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        // Fires only for clicks delivered to OTHER apps (not our own HUD/menu-bar item),
        // so clicking the HUD keeps it open while clicking anything else dismisses it.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.menuShowing else { return }
            self.menuShowing = false
            self.removeOutsideMonitor()
            self.updateVisibility()
        }
    }
    func removeOutsideMonitor() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    // Single source of truth for whether the panel is on screen.
    func updateVisibility() {
        let want = visible
        if want && !panel.isVisible {
            positionHUD(); panel.orderFrontRegardless(); engine.refreshOnce()
        } else if !want && panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func positionHUD() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let margin: CGFloat = 12
        let origin = NSPoint(x: vf.maxX - Layout.W - margin, y: vf.maxY - Layout.H - margin)
        panel.setFrameOrigin(origin)
        refreshGlobalRect()
    }

    func refreshGlobalRect() {
        let f = panel.frame
        hudGlobalRect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    func seekFraction(_ f: Double) {
        let dur = engine.np.duration; if dur > 0 { engine.seek(dur * f) }
    }

    // ---- per-tick housekeeping ----
    // The poll only detects Mission Control *opening* (a slight appear-lag is fine) and acts
    // as a safety net. Closing is event-driven (see triggerHide) so it's instant, beating the
    // Mission Control close animation. The event taps live only while MC is open.
    func tick() {
        if eventTap == nil && AXIsProcessTrusted() { installTap() }
        let nowMC = missionControlActive()
        if nowMC != mcActive {
            mcActive = nowMC
            setTaps(enabled: nowMC)               // taps run only during Mission Control
            if !nowMC { triggerHidden = false }   // reset once MC is fully gone
        }
        // Safety net: if we hid on a trigger but MC is still open well past the close animation,
        // it was a space switch (not a close) — bring the HUD back.
        if triggerHidden, nowMC, Date().timeIntervalSince(triggerHideTime) > 1.5 {
            triggerHidden = false
        }
        mcShowing = nowMC && !triggerHidden
        updateVisibility()
        if visible { refreshGlobalRect(); view.needsDisplay = true }
    }

    func setTaps(enabled: Bool) {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: enabled) }
        if let t = moveTap { CGEvent.tapEnable(tap: t, enable: enabled) }
    }

    // Hide instantly when the user does anything that closes Mission Control, so the HUD is
    // gone before the close animation finishes (no waiting on the window teardown).
    func triggerHide() {
        guard mcShowing else { return }
        triggerHidden = true
        triggerHideTime = Date()
        mcShowing = false
        updateVisibility()
    }

    // ---- Mission Control click interception ----
    func installTap() {
        // Clicks on the HUD (controls) plus the events that close Mission Control: any other
        // mouse button or any key. Enabled only while MC is open (see setTaps), so it isn't
        // observing input the rest of the time.
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: tapCallback, userInfo: nil) else {
            vlog("event tap NOT created — grant Accessibility, then relaunch"); return
        }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)   // off until Mission Control opens
        vlog("hid (click) tap installed")

        // Session-level tap: delete hover/drag-move events that land on the HUD during
        // Mission Control. Placed downstream of the cursor, so the pointer still moves —
        // this just stops the Dock from highlighting the window thumbnail behind the HUD.
        let moveMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        if let mt = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: moveMask,
                                      callback: moveTapCallback, userInfo: nil) {
            moveTap = mt
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mt, 0), .commonModes)
            CGEvent.tapEnable(tap: mt, enable: false)   // off until Mission Control opens
            vlog("session (hover) tap installed")
        } else { vlog("session (hover) tap NOT created") }
    }

    // Where to send the Dock's perceived cursor when hovering the HUD: the menu bar of the
    // cursor's monitor (above the spaces bar, no thumbnails). Returns nil when no relocation
    // is needed. The real cursor sprite is unaffected (this is a downstream session tap).
    func hoverRelocation(at point: CGPoint) -> CGPoint? {
        guard mcShowing, hudGlobalRect.contains(point) else { return nil }
        // Send the Dock's perceived cursor to the far RIGHT edge of the HUD's monitor, same
        // height as the cursor. On-screen (off-screen points get ignored, leaving the highlight),
        // but at the screen edge it lands in the margin beside the thumbnail grid — so the Dock
        // clears the highlight. Left/right edges trigger nothing (only top=spaces bar,
        // bottom=dock), and keeping y avoids those. Real cursor sprite is unaffected.
        let cocoaY = primaryHeight - point.y
        for s in NSScreen.screens {
            let f = s.frame
            if point.x >= f.minX, point.x <= f.maxX, cocoaY >= f.minY, cocoaY <= f.maxY {
                return CGPoint(x: f.maxX - 2, y: point.y)
            }
        }
        return CGPoint(x: point.x, y: point.y)
    }

    // A click in the top strip of its monitor is the Mission Control spaces bar — switching
    // spaces keeps MC open, so it must NOT dismiss the HUD.
    func isInTopStrip(_ point: CGPoint) -> Bool {
        let cocoaY = primaryHeight - point.y
        for s in NSScreen.screens {
            let f = s.frame
            if point.x >= f.minX, point.x <= f.maxX, cocoaY >= f.minY, cocoaY <= f.maxY {
                return (point.y - (primaryHeight - f.maxY)) < 170
            }
        }
        return point.y < 170
    }

    // called from the HID tap callback (on main run loop). Returns true to swallow the event.
    func handleTap(type: CGEventType, point: CGPoint, keyCode: Int64) -> Bool {
        guard mcShowing else { return false }
        let insideHUD = hudGlobalRect.contains(point)

        // Inputs that CLOSE Mission Control -> hide instantly (never swallow them). Skip the ones
        // that switch spaces while keeping MC open: Ctrl+←/→ (123/124) and spaces-bar clicks.
        // Note Ctrl+↑ (126) is the default *close* shortcut, so it must still hide.
        let isSpaceSwitch = (keyCode == 123 || keyCode == 124)   // ← / →
        switch type {
        case .keyDown where !isSpaceSwitch:
            triggerHide(); return false
        case .otherMouseDown:
            triggerHide(); return false
        case .leftMouseDown where !insideHUD && !isInTopStrip(point):
            triggerHide(); return false
        default: break
        }

        guard insideHUD else { return false }
        // convert CG top-left global -> view-local (bottom-left)
        let local = NSPoint(x: point.x - hudGlobalRect.minX, y: hudGlobalRect.maxY - point.y)
        switch type {
        case .leftMouseDown:
            switch Layout.region(at: local) {
            case .prev: engine.command("previous-track")
            case .next: engine.command("next-track")
            case .playpause: engine.command("toggle-play-pause")
            case .seek(let f): view.dragging = true; seekFraction(f)
            case .none: break
            }
            return true   // swallow clicks on the HUD so MC never selects the window behind
        case .leftMouseDragged:
            if view.dragging {
                let f = max(0, min(1, (local.x - Layout.barRect.minX) / Layout.barRect.width))
                seekFraction(Double(f))
            }
            return true
        case .leftMouseUp:
            view.dragging = false
            return true
        default: return false
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        vlog("Accessibility trusted: \(trusted)")
    }
}

// HID tap callback -> clicks. Routes to the singleton on the main run loop.
let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = Controller.shared.eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let kc = event.getIntegerValueField(.keyboardEventKeycode)
    let swallow = Controller.shared.handleTap(type: type, point: event.location, keyCode: kc)
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// Session tap callback -> instead of deleting hover events over the HUD (which would freeze
// the Dock's highlight state and leave a stale outline), RELOCATE them to a no-thumbnail spot
// so the Dock clears any existing highlight and never lights up the thumbnail behind the HUD.
let moveTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = Controller.shared.moveTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if let safe = Controller.shared.hoverRelocation(at: event.location) { event.location = safe }
    return Unmanaged.passUnretained(event)
}

// ---------------------------------------------------------------------------
// Self-test: prove the integrated app controls playback during Mission Control
// ---------------------------------------------------------------------------
func runSelfTest() {
    let c = Controller.shared
    DispatchQueue.global().async {
        usleep(1_200_000)
        DispatchQueue.main.sync { c.menuShowing = true; c.positionHUD(); c.updateVisibility() }
        usleep(400_000)
        let before = run([MEDIA_CONTROL], ["get"])
        vlog("SELFTEST before: \(before.trimmingCharacters(in: .whitespacesAndNewlines))")
        vlog("SELFTEST opening Mission Control")
        _ = run(["/usr/bin/open"], ["-a", "Mission Control"]); usleep(1_300_000)
        vlog("SELFTEST mcActive=\(missionControlActive())  hudRect=\(c.hudGlobalRect)")
        // synth-click the play/pause button center, in CG global top-left coords
        let pr = Layout.playRect
        let gx = c.hudGlobalRect.minX + pr.midX
        let gy = c.hudGlobalRect.maxY - pr.midY
        vlog("SELFTEST synth click at (\(Int(gx)),\(Int(gy)))")
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: gx, y: gy), mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: gx, y: gy), mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(900_000)
        let after = run([MEDIA_CONTROL], ["get"])
        vlog("SELFTEST after:  \(after.trimmingCharacters(in: .whitespacesAndNewlines))")
        // dismiss MC + restore state
        let esc = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: esc, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: esc, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(600_000)
        _ = run([MEDIA_CONTROL], ["toggle-play-pause"])    // restore
        usleep(300_000)
        func playing(_ s: String) -> String {
            (try? (JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])?["playing"] as? Bool).flatMap { "\($0 ?? false)" } ?? "?"
        }
        let ok = playing(before) != playing(after)
        FileHandle.standardError.write("SELFTEST RESULT: play-state changed during Mission Control = \(ok)\n".data(using: .utf8)!)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

// ---------------------------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Controller.shared
app.delegate = nil
Controller.shared.start()
if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
}
app.run()

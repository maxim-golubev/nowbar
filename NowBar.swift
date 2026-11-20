import Cocoa
import ApplicationServices
import ServiceManagement

// ============================================================================
// NowBar — a "better Now Playing": a menu-bar app whose floating controller
// stays usable inside Mission Control.
//
//  • Click the menu-bar icon  -> HUD appears top-right of the ACTIVE monitor.
//  • Works in normal use (native clicks) AND inside Mission Control (HID tap).
//  • Appears with Mission Control (fading with the trackpad swipe) and leaves with it.
//  • Engine: the `media-control` CLI (reads/controls any app's Now Playing).
//    MediaRemote itself is entitlement-gated since macOS 15.4, so a helper is
//    the only reliable way to observe system-wide Now Playing.
// ============================================================================

let MEDIA_CONTROL: String? = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }
let VERBOSE = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("--selftest")
func vlog(_ s: String) { if VERBOSE { FileHandle.standardError.write(Data(("[NowBar] " + s + "\n").utf8)) } }

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
struct NowPlaying {
    var title = "", artist = "", album = "", bundleID = ""
    var duration = 0.0, elapsed = 0.0, rate = 1.0
    var playing = false
    var stamp = Date()           // when `elapsed` was measured

    var isEmpty: Bool { title.isEmpty }
    var trackKey: String { [bundleID, title, artist, album].joined(separator: "\u{1F}") }

    func liveElapsed(at now: Date = Date()) -> Double {
        var t = elapsed
        if playing { t += now.timeIntervalSince(stamp) * rate }
        if duration > 0 { t = min(t, duration) }
        return max(0, t)
    }

    // Build from media-control's key/value state. Accepts both `--micros` keys and the
    // plain ones so a flat `get` dump parses the same way as the stream.
    init() {}
    init(_ s: [String: Any]) {
        func num(_ k: String) -> Double? { (s[k] as? NSNumber)?.doubleValue }
        title    = s["title"] as? String ?? ""
        artist   = s["artist"] as? String ?? ""
        album    = s["album"] as? String ?? ""
        bundleID = s["bundleIdentifier"] as? String ?? ""
        duration = num("durationMicros").map { $0 / 1e6 } ?? num("duration") ?? 0
        elapsed  = num("elapsedTimeMicros").map { $0 / 1e6 } ?? num("elapsedTime") ?? 0
        rate     = num("playbackRate") ?? 1      // absent while paused
        playing  = (s["playing"] as? NSNumber)?.boolValue ?? false
        if let us = num("timestampEpochMicros") {
            stamp = Date(timeIntervalSince1970: us / 1e6)
        } else if let iso = s["timestamp"] as? String, let d = ISO8601DateFormatter().date(from: iso) {
            stamp = d
        }
    }
}

func mmss(_ t: Double) -> String {
    guard t.isFinite, t > 0 else { return "0:00" }
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s/3600, s/60%60, s%60) : String(format: "%d:%02d", s/60, s%60)
}

// ---------------------------------------------------------------------------
// media-control engine: one long-lived `stream` plus serialized commands.
//
// Stream protocol (one JSON object per line):
//   {"type":"data","diff":false,"payload":{…full state…}}   new track / initial / nothing playing ({})
//   {"type":"data","diff":true, "payload":{…changed keys…}} null value = key removed
// Artwork rides along in the stream, but only when it changes (it arrives ~30 ms after a
// track change as its own diff), so it costs nothing on play/pause/seek updates.
//
// All parsing state lives on `q`; results are published to the main thread.
// ---------------------------------------------------------------------------
final class Engine {
    var onUpdate: ((NowPlaying) -> Void)?   // main thread
    private(set) var np = NowPlaying()      // main thread
    private(set) var artwork: NSImage?      // main thread
    var available: Bool { MEDIA_CONTROL != nil }

    private let q = DispatchQueue(label: "nowbar.engine")
    private let cmdQ = DispatchQueue(label: "nowbar.commands")   // serial: commands run in click order

    // --- q-only state ---
    private var truth: [String: Any] = [:]     // what the stream last told us
    private var overlay: [String: Any] = [:]   // optimistic values from our own commands
    private var overlayExpiry = Date.distantPast
    private var buf = Data()
    private var trackKey = ""
    private var artKey = ""                    // track the current artwork belongs to
    private var art: NSImage?
    private var emptyGen = 0                   // cancels a pending deferred "nothing playing"
    private var bufGen = 0                     // which stream instance `buf` holds bytes from

    // --- main-only state ---
    private var stream: Process?
    private var restartDelay = 1.0
    private var streamStarted = Date()
    private var stopping = false
    private var streamGen = 0

    func start() {
        guard available else { vlog("media-control not found"); return }
        launchStream()
    }

    func stop() {
        stopping = true
        stream?.terminate()
    }

    private func launchStream() {
        guard let exe = MEDIA_CONTROL, !stopping else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["stream", "--micros"]
        streamGen += 1
        let gen = streamGen
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice   // an unread stderr pipe would eventually block the child
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }   // EOF: unhook, or this spins forever
            self?.q.async { self?.feed(d, gen: gen) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.streamEnded(proc.terminationStatus) }
        }
        do {
            try p.run(); stream = p; streamStarted = Date(); vlog("stream started (pid \(p.processIdentifier))")
        } catch {
            vlog("stream failed: \(error)"); streamEnded(-1)
        }
    }

    // The stream should live forever; if it dies (brew upgrade, crash) bring it back with backoff.
    private func streamEnded(_ status: Int32) {
        stream = nil
        guard !stopping else { return }
        if Date().timeIntervalSince(streamStarted) > 30 { restartDelay = 1 }
        vlog("stream exited (\(status)); restarting in \(restartDelay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in self?.launchStream() }
        restartDelay = min(restartDelay * 2, 30)
    }

    // Split on raw newline bytes *before* decoding: a chunk boundary can fall inside a
    // multi-byte UTF-8 character (accented titles), which would make the chunk undecodable.
    // Bytes are tagged per stream instance so a dead stream's tail can't corrupt the new one.
    private func feed(_ d: Data, gen: Int) {
        if gen < bufGen { return }
        if gen > bufGen { buf.removeAll(); bufGen = gen }
        buf.append(d)
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if !line.isEmpty { ingest(line) }
        }
    }

    private static let timeKeys = ["elapsedTimeMicros", "timestampEpochMicros", "elapsedTime", "timestamp"]

    private func ingest(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let payload: [String: Any], isDiff: Bool
        if let p = obj["payload"] as? [String: Any] {
            payload = p; isDiff = (obj["diff"] as? Bool) ?? false
        } else if obj["type"] == nil {
            payload = obj; isDiff = false             // flat `get` output
        } else { return }

        // Every (re)started stream opens with an empty full state and sends the real one right
        // after; switching player apps does the same. Hold an empty state back briefly so these
        // don't flash "Nothing playing" and drop the artwork.
        emptyGen &+= 1
        if !isDiff, payload.isEmpty, !truth.isEmpty {
            let g = emptyGen
            q.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.emptyGen == g else { return }
                self.apply([:], isDiff: false)
            }
            return
        }
        apply(payload, isDiff: isDiff)
    }

    private func apply(_ payload: [String: Any], isDiff: Bool) {
        let before = NowPlaying(truth)
        if !isDiff { truth.removeAll(); overlay.removeAll() }
        for (k, v) in payload where k != "artworkData" {
            if v is NSNull { truth.removeValue(forKey: k) } else { truth[k] = v }
            overlay.removeValue(forKey: k)            // the real value has arrived
        }

        // A bare {"playing":…} diff keeps the old elapsed/timestamp pair. Re-anchor it at the
        // transition, otherwise resuming after a long pause would extrapolate from the
        // pause-time timestamp and slam the progress bar to the end.
        var after = NowPlaying(truth)
        if isDiff, before.playing != after.playing, !Self.timeKeys.contains(where: { payload[$0] != nil }) {
            anchor(&truth, at: before.liveElapsed())
            after = NowPlaying(truth)
        }

        let key = after.trackKey
        if let a = payload["artworkData"] {
            art = (a as? String).flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) }
            artKey = key
        } else if after.isEmpty {
            art = nil; artKey = key
        } else if key != trackKey {
            // New track without artwork yet: keep the previous cover briefly (the new one
            // normally lands within ~30 ms) instead of flashing the placeholder.
            q.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.artworkTimedOut(key) }
        }
        trackKey = key
        publish()
    }

    private func anchor(_ s: inout [String: Any], at position: Double) {
        s["elapsedTimeMicros"] = position * 1e6
        s["timestampEpochMicros"] = Date().timeIntervalSince1970 * 1e6
        s.removeValue(forKey: "elapsedTime"); s.removeValue(forKey: "timestamp")
    }

    private func current() -> NowPlaying {
        guard overlayExpiry > Date() else { return NowPlaying(truth) }
        return NowPlaying(truth.merging(overlay) { _, o in o })
    }

    private func publish() {
        if overlayExpiry <= Date() { overlay.removeAll() }
        let n = current(), a = art
        DispatchQueue.main.async {
            self.np = n; self.artwork = a
            self.onUpdate?(n)
        }
    }

    private func artworkTimedOut(_ key: String) {
        guard trackKey == key, artKey != key else { return }
        art = nil; artKey = key
        publish()
        if NowPlaying(truth).bundleID == "com.spotify.client" { fetchSpotifyArtwork(for: key) }
    }

    // Fallback when MediaRemote carries no artwork: Spotify exposes a cover URL via AppleScript.
    private func fetchSpotifyArtwork(for key: String) {
        DispatchQueue.global(qos: .utility).async {
            let url = run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to artwork url of current track"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.hasPrefix("http"), let u = URL(string: url) else { return }
            URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
                guard let self, let data, let img = NSImage(data: data) else { return }
                self.q.async {
                    guard self.trackKey == key, self.art == nil else { return }
                    self.art = img; self.publish()
                }
            }.resume()
        }
    }

    // Optimistic local state for our own commands, so the HUD reacts on click instead of
    // after the stream round-trip. Real stream values replace it key by key; if the command
    // had no effect, it lapses after 2 s and the HUD falls back to the truth.
    private func optimistic(_ mutate: @escaping (inout [String: Any], NowPlaying) -> Void) {
        q.async {
            let cur = self.current()
            guard !cur.isEmpty else { return }
            if self.overlayExpiry <= Date() { self.overlay.removeAll() }
            mutate(&self.overlay, cur)
            self.overlayExpiry = Date().addingTimeInterval(2)
            self.publish()
            self.q.asyncAfter(deadline: .now() + 2.05) { self.publish() }
        }
    }

    func setPlaying(_ play: Bool) {
        optimistic { o, cur in o["playing"] = play; self.anchor(&o, at: cur.liveElapsed()) }
        send([play ? "play" : "pause"])
    }

    func seek(_ seconds: Double) {
        let t = max(0, seconds)
        optimistic { o, _ in self.anchor(&o, at: t) }
        send(["seek", String(format: "%.2f", t)])
    }

    func next()     { send(["next-track"]) }
    func previous() { send(["previous-track"]) }

    private func send(_ args: [String]) {
        guard let exe = MEDIA_CONTROL else { return }
        cmdQ.async { run(exe, args) }
    }
}

// Run a helper to completion and return stdout. A watchdog kills it if it hangs so a stuck
// helper can never wedge the serial command queue.
@discardableResult
func run(_ exe: String, _ args: [String], timeout: TimeInterval = 5) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
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
    private static let timeAttrs = attrs(size: 8, weight: .regular, color: NSColor(white: 0.6, alpha: 1), mono: true)
    private static let timeAttrsRight = attrs(size: 8, weight: .regular, color: NSColor(white: 0.6, alpha: 1), mono: true, right: true)
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
        mmss(elapsed).draw(with: NSRect(x: Layout.contentX, y: 0, width: 54, height: 14),
                           options: [.usesLineFragmentOrigin], attributes: Self.timeAttrs)
        mmss(np.duration).draw(with: NSRect(x: Layout.W - 12 - 54, y: 0, width: 54, height: 14),
                               options: [.usesLineFragmentOrigin], attributes: Self.timeAttrsRight)
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

// ---------------------------------------------------------------------------
// Mission Control detection
// ---------------------------------------------------------------------------
// Polled: the window list sees MC ~120 ms after it starts opening, whereas the Dock's
// AXExposeShowAllWindows notification arrives ~400 ms in — polling is the faster signal.
enum MissionControl {
    static var dockPID: pid_t = currentDockPID()
    static func currentDockPID() -> pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? -1
    }

    // Mission Control stacks 2+ full-screen Dock windows (layers 20/18/0). A revealed
    // auto-hide Dock makes only ONE, so require at least two to avoid false positives.
    // Matching on PID through NSDictionary avoids bridging every window to a Swift dict.
    static func isActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as NSArray? else { return false }
        var count = 0
        for case let w as NSDictionary in list {
            guard (w[kCGWindowOwnerPID] as? NSNumber)?.int32Value == dockPID,
                  ((w[kCGWindowLayer] as? NSNumber)?.intValue ?? -1) >= 0,
                  let bd = w[kCGWindowBounds] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            if r.width > 1000, r.height > 700 { count += 1; if count >= 2 { return true } }
        }
        return false
    }
}
func missionControlActive() -> Bool { MissionControl.isActive() }

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
    var triggerGrace: TimeInterval = 1.5   // how long MC may stay open after a trigger before we come back
    var visible: Bool { mcShowing || menuShowing }
    var outsideMonitor: Any?     // global click monitor for popover-style dismissal

    // presentation: `presented` is the intent; the panel may still be fading toward it
    var presented = false
    var fadeGen = 0              // invalidates the completion of a superseded fade
    var swipe: Swipe?            // a vertical Mission Control trackpad swipe currently steering the HUD
    struct Swipe { let opening: Bool; var progress = 0.0 }
    enum Fade {
        static let mission: TimeInterval = 0.22   // matches Mission Control's own open/close animation
        static let menu: TimeInterval = 0.12
    }
    var gestureTap: CFMachPort?  // listen-only: Dock swipe gesture events (no keys, no clicks)
    var dockObserver: AXObserver?  // AXExposeShowAllWindows / AXExposeExit from the Dock

    // geometry the tap reads (CG top-left coords), refreshed when the HUD moves
    var hudGlobalRect = CGRect.zero
    var mcActive = false
    var eventTap: CFMachPort?    // HID tap: intercept clicks in Mission Control
    var moveTap: CFMachPort?     // session tap: suppress hover-through highlight
    var tapScrubbing = false     // a scrub that started through the MC tap (vs. native mouse)
    var primaryHeight: CGFloat = Controller.currentPrimaryHeight()
    var timer: Timer?

    static func currentPrimaryHeight() -> CGFloat {
        (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first)?.frame.height ?? 1080
    }

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
        if !engine.available { view.notice = "media-control not found" }
        engine.onUpdate = { [weak self] np in
            guard let self else { return }
            if VERBOSE, np.playing != self.view.np.playing || np.trackKey != self.view.np.trackKey {
                vlog("state: playing=\(np.playing) title=\(np.title) @\(String(format: "%.1f", np.liveElapsed()))")
            }
            self.view.np = np; self.view.art = self.engine.artwork; self.view.needsDisplay = true
            self.updateStatusTitle(np)
        }
        engine.start()
        requestAccessibility()
        installTap()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.primaryHeight = Self.currentPrimaryHeight()
            if self.panel.isVisible { self.positionHUD() } else { self.refreshGlobalRect() }
        }
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.stop()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.dock" {
                MissionControl.dockPID = app!.processIdentifier
                Controller.shared.installDockObserver()
            }
        }

        // .common so it keeps ticking while the status menu is tracking; tolerance lets the
        // system coalesce wake-ups.
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.04
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
        let tip = np.isEmpty ? "NowBar" : (np.artist.isEmpty ? np.title : "\(np.title) — \(np.artist)")
        if statusItem.button?.toolTip != tip { statusItem.button?.toolTip = tip }
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
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
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit NowBar", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore click-to-toggle for next time
    }

    @objc func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
            if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    // Menu-bar click: show as a popover that dismisses on a click outside it.
    @objc func toggleMenuPopover() {
        if menuShowing {
            menuShowing = false; removeOutsideMonitor()
        } else {
            menuShowing = true; installOutsideMonitor()
        }
        updateVisibility(fadeIn: Fade.menu, fadeOut: Fade.menu)   // positions on the active monitor when it becomes visible
    }

    func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        // Fires only for clicks delivered to OTHER apps (not our own HUD/menu-bar item),
        // so clicking the HUD keeps it open while clicking anything else dismisses it.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.menuShowing else { return }
            self.menuShowing = false
            self.removeOutsideMonitor()
            self.updateVisibility(fadeOut: Fade.menu)
        }
    }
    func removeOutsideMonitor() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    // Single source of truth for whether the panel is on screen. While a trackpad swipe is
    // steering the HUD, the swipe owns it; it hands back when the fingers lift.
    // Default fades: appear with Mission Control's opening animation; vanish at once when the
    // poll finds MC already gone (any delay there is exactly the leftover-HUD flash).
    func updateVisibility(fadeIn: TimeInterval = Fade.mission, fadeOut: TimeInterval = 0) {
        guard swipe == nil else { return }
        let want = visible
        if want != presented { present(want, over: want ? fadeIn : fadeOut) }
    }

    func present(_ show: Bool, over duration: TimeInterval) {
        presented = show
        fadeGen &+= 1
        let gen = fadeGen
        if show, !panel.isVisible {
            positionHUD(); view.needsDisplay = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        if !show { view.scrub = nil }
        let target: CGFloat = show ? 1 : 0
        guard duration > 0, panel.isVisible else {
            panel.alphaValue = target
            if !show { panel.orderOut(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = target
        }, completionHandler: { [weak self] in
            guard let self, self.fadeGen == gen, !show else { return }
            self.panel.orderOut(nil)
        })
    }

    // ---- Mission Control trackpad swipe: the HUD's opacity follows the fingers ----
    // Dock swipes arrive as CGS event type 30 with gesture type 23 (field 110). Field 132 is the
    // IOHID phase (1 began, 2 changed, 4 ended, 8 cancelled), 123 the axis (2 = vertical) and the
    // double in 124 the progress: 0→1 opening Mission Control, 0→-1 closing it (App Exposé mirrors
    // the signs, so only the magnitude is used). 129 carries the release velocity.
    func dockSwipe(phase: Int64, axis: Int64, progress: Double, velocity: Double) {
        guard axis == 2, !menuShowing else { return }
        switch phase {
        case 1:
            // Ask the window list directly: the poll may be up to 200 ms stale here.
            let opening = !MissionControl.isActive()
            if !opening && !presented { return }   // closing an MC we were hidden in: nothing to fade
            swipe = Swipe(opening: opening)
            fadeGen &+= 1                          // cancel any fade in flight; the fingers rule now
            if opening {
                triggerHidden = false
                presented = true
                if !panel.isVisible {
                    positionHUD(); view.needsDisplay = true
                    panel.alphaValue = 0
                    panel.orderFrontRegardless()
                }
            }
        case 2:
            guard var s = swipe else { return }
            s.progress = progress; swipe = s
            let p = CGFloat(min(1, abs(progress)))
            panel.alphaValue = s.opening ? p : 1 - p
        case 4, 8:
            guard let s = swipe else { return }
            swipe = nil
            let commits = phase == 4 && Self.swipeCommits(progress: s.progress, velocity: velocity)
            vlog("swipe \(s.opening ? "open" : "close") ended p=\(String(format: "%.2f", s.progress)) v=\(String(format: "%.2f", velocity)) -> \(commits ? "commit" : "cancel")")
            // The outcome is a prediction; AXExposeShowAllWindows / AXExposeExit (and, last, the
            // poll) correct it within a few hundred ms if macOS decided otherwise.
            let showAfter = s.opening == commits
            if !showAfter {
                triggerHidden = true; triggerHideTime = Date(); triggerGrace = 0.8
                mcShowing = false
            }
            present(showAfter || menuShowing, over: Fade.mission)
        default: break
        }
    }

    // Pure decision: does releasing a swipe here finish the transition? Moving on in the swipe's
    // direction commits, flicking back cancels, and a release at rest goes to the nearer end.
    static func swipeCommits(progress: Double, velocity: Double) -> Bool {
        let along = velocity * (progress >= 0 ? 1 : -1)
        if along > 0.1 { return true }
        if along < -0.1 { return false }
        return abs(progress) >= 0.5
    }

    // Dock accessibility notifications: definitive "fully open" / "closing now" signals.
    // AXExposeExit lands a few ms before the Dock's overlay windows are torn down, so hiding
    // here (not on the next poll) is what keeps the HUD from lingering alone at full opacity.
    func exposeShown() {
        guard swipe == nil else { return }
        if triggerHidden { triggerHidden = false }
        mcShowing = true
        updateVisibility()
    }
    func exposeExited() {
        guard swipe == nil else { return }
        if mcShowing { triggerHidden = true; triggerHideTime = Date(); triggerGrace = 0.8 }
        mcShowing = false
        if !visible && panel.isVisible { present(false, over: 0) }
    }

    func installDockObserver() {
        if let o = dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
            dockObserver = nil
        }
        let pid = MissionControl.dockPID
        guard pid > 0 else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, note, _ in
            switch note as String {
            case "AXExposeShowAllWindows", "AXExposeShowFrontWindows": Controller.shared.exposeShown()
            case "AXExposeExit": Controller.shared.exposeExited()
            default: break
            }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let o = obs else { vlog("dock observer NOT created"); return }
        let dock = AXUIElementCreateApplication(pid)
        for n in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeExit"] {
            AXObserverAddNotification(o, dock, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        dockObserver = o
        vlog("dock observer installed")
    }

    func positionHUD() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
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

    // ---- interaction shared by native mouse events and the Mission Control tap ----
    // `p` is in view-local (bottom-left) coords.
    func press(at p: NSPoint) {
        switch Layout.region(at: p) {
        case .prev: engine.previous()
        case .next: engine.next()
        case .playpause: if !engine.np.isEmpty { engine.setPlaying(!engine.np.playing) }
        case .seek(let f): if engine.np.duration > 0 { view.scrub = f; view.needsDisplay = true }
        case .none: break
        }
    }
    func drag(to p: NSPoint) {
        guard view.scrub != nil else { return }
        view.scrub = Layout.barFraction(p.x); view.needsDisplay = true
    }
    // One seek on release instead of one helper process per drag event.
    func release() {
        guard let f = view.scrub else { return }
        view.scrub = nil
        let dur = engine.np.duration
        if dur > 0 { engine.seek(dur * f) }
        view.needsDisplay = true
    }

    // ---- per-tick housekeeping ----
    // The poll only detects Mission Control *opening* (a slight appear-lag is fine) and acts
    // as a safety net. Closing is event-driven (see triggerHide) so it's instant, beating the
    // Mission Control close animation. The event taps live only while MC is open.
    func tick() {
        if eventTap == nil && AXIsProcessTrusted() { installTap() }
        let nowMC = MissionControl.isActive()
        if nowMC != mcActive {
            mcActive = nowMC
            setTaps(enabled: nowMC)               // taps run only during Mission Control
            if !nowMC {
                triggerHidden = false             // reset once MC is fully gone
                if tapScrubbing { tapScrubbing = false; view.scrub = nil }   // its mouse-up can no longer reach us
            }
        }
        // Safety net: if we hid on a trigger but MC is still open well past the close animation,
        // it was a space switch (not a close) — bring the HUD back.
        if triggerHidden, nowMC, swipe == nil, Date().timeIntervalSince(triggerHideTime) > triggerGrace {
            triggerHidden = false
        }
        mcShowing = nowMC && !triggerHidden
        updateVisibility()
        if VERBOSE {
            for (name, t) in [("hid", eventTap), ("move", moveTap)] {
                if let t, CGEvent.tapIsEnabled(tap: t) != mcActive { vlog("WARN \(name) tap enabled=\(!mcActive) while mcActive=\(mcActive)") }
            }
        }
        // Only a playing track (or an active scrub) changes the picture between stream updates.
        if visible, engine.np.playing || view.scrub != nil { view.needsDisplay = true }
    }

    func setTaps(enabled: Bool) {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: enabled) }
        if let t = moveTap { CGEvent.tapEnable(tap: t, enable: enabled) }
    }

    // Fade out alongside Mission Control's close animation the moment the user does anything
    // that closes it, rather than waiting for the window teardown.
    func triggerHide() {
        guard mcShowing else { return }
        triggerHidden = true
        triggerHideTime = Date()
        triggerGrace = 1.5        // a space switch keeps MC open; give it time before returning
        mcShowing = false
        updateVisibility(fadeOut: Fade.mission)
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
        CGEvent.tapEnable(tap: tap, enable: mcActive)   // off until Mission Control opens
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
            CGEvent.tapEnable(tap: mt, enable: mcActive)   // off until Mission Control opens
            vlog("session (hover) tap installed")
        } else { vlog("session (hover) tap NOT created") }

        // Always-on but listen-only, and it only ever receives Dock swipe gestures: the opening
        // swipe starts before Mission Control exists, so it can't wait for the MC-only taps.
        if let gt = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap,
                                      options: .listenOnly, eventsOfInterest: CGEventMask(1) << 30,
                                      callback: gestureTapCallback, userInfo: nil) {
            gestureTap = gt
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gt, 0), .commonModes)
            CGEvent.tapEnable(tap: gt, enable: true)
            vlog("gesture tap installed")
        } else { vlog("gesture tap NOT created") }
        installDockObserver()
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
        // convert CG top-left global -> view-local (bottom-left)
        let local = NSPoint(x: point.x - hudGlobalRect.minX, y: hudGlobalRect.maxY - point.y)

        // A scrub that began on the HUD owns the mouse until release, wherever the pointer
        // wanders — otherwise a release outside the HUD would leave it stuck mid-drag.
        if tapScrubbing {
            switch type {
            case .leftMouseDragged: drag(to: local); return true
            case .leftMouseUp: tapScrubbing = false; release(); return true
            default: break
            }
        }

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
        switch type {
        case .leftMouseDown:
            press(at: local)
            tapScrubbing = view.scrub != nil
            return true   // swallow clicks on the HUD so MC never selects the window behind
        case .leftMouseDragged, .leftMouseUp:
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
    // NOTE: our own tapEnable(false) also lands here as tapDisabledByUserInput. Only ever
    // re-ENABLE (and only during MC); re-enabling unconditionally would keep the tap on all the
    // time, and disabling from in here re-triggers this callback in a tight loop.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let c = Controller.shared
        if c.mcActive, let t = c.eventTap { CGEvent.tapEnable(tap: t, enable: true) }
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
        let c = Controller.shared
        if c.mcActive, let t = c.moveTap { CGEvent.tapEnable(tap: t, enable: true) }   // see note above
        return Unmanaged.passUnretained(event)
    }
    if let safe = Controller.shared.hoverRelocation(at: event.location) { event.location = safe }
    return Unmanaged.passUnretained(event)
}

// Gesture tap callback -> Dock swipe progress. Listen-only; never alters the event.
let gestureTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // This tap is never disabled on purpose, so turning it back on can't fight us.
        if let t = Controller.shared.gestureTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    func int(_ f: UInt32) -> Int64 { event.getIntegerValueField(CGEventField(rawValue: f)!) }
    func dbl(_ f: UInt32) -> Double { event.getDoubleValueField(CGEventField(rawValue: f)!) }
    if type.rawValue == 30, int(110) == 23 {
        Controller.shared.dockSwipe(phase: int(132), axis: int(123), progress: dbl(124), velocity: dbl(129))
    }
    return Unmanaged.passUnretained(event)
}

// ---------------------------------------------------------------------------
// Self-test: prove the integrated app controls playback during Mission Control
// ---------------------------------------------------------------------------
func runSelfTest() {
    let c = Controller.shared
    guard let mc = MEDIA_CONTROL else {
        FileHandle.standardError.write(Data("SELFTEST RESULT: media-control not installed\n".utf8)); exit(1)
    }
    func playing(_ s: String) -> String {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let p = d["playing"] as? Bool else { return "?" }
        return "\(p)"
    }
    DispatchQueue.global().async {
        usleep(1_200_000)
        DispatchQueue.main.sync { c.menuShowing = true; c.positionHUD(); c.updateVisibility() }
        usleep(400_000)
        let before = run(mc, ["get", "--no-artwork"])
        vlog("SELFTEST before: \(before.trimmingCharacters(in: .whitespacesAndNewlines))")
        vlog("SELFTEST opening Mission Control")
        run("/usr/bin/open", ["-a", "Mission Control"]); usleep(1_300_000)
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
        let after = run(mc, ["get", "--no-artwork"])
        vlog("SELFTEST after:  \(after.trimmingCharacters(in: .whitespacesAndNewlines))")
        vlog("SELFTEST HUD shows playing=\(DispatchQueue.main.sync { c.engine.np.playing })")
        // dismiss MC + restore state
        let esc = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: esc, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: esc, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(600_000)
        run(mc, [playing(before) == "true" ? "play" : "pause"])    // restore
        usleep(300_000)
        let ok = playing(before) != playing(after)
        FileHandle.standardError.write(Data("SELFTEST RESULT: play-state changed during Mission Control = \(ok)\n".utf8))
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

// ---------------------------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Route kill/Ctrl-C/logout through a normal terminate so the stream child is reaped too
// (otherwise it is orphaned to launchd and lingers until its next write hits a dead pipe).
let signalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { NSApp.terminate(nil) }
    s.resume()
    return s
}
Controller.shared.start()
if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
}
app.run()

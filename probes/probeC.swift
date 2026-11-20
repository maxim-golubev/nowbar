import Cocoa

// Probe C (capstone): prove the full pipeline — a HUD at level 25 that is VISIBLE over
// Mission Control, plus an ACTIVE HID event tap that, while MC is open, intercepts a click
// landing inside the HUD, swallows it (so MC doesn't react), and runs a media command.
// Autonomous proof: synthesize a click on the "play/pause" region during MC and confirm
// playback state flipped — then restore it.

let startMS = Date().timeIntervalSince1970
func ts() -> String { String(format: "%.3f", Date().timeIntervalSince1970 - startMS) }
func log(_ s: String) { print("[\(ts())] \(s)"); fflush(stdout) }

func mc(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/media-control"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
func playingState() -> String {
    let json = mc(["get"])
    if let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
        return "playing=\(d["playing"] ?? "?") elapsed=\(String(format: "%.1f", (d["elapsedTime"] as? Double) ?? -1)) title=\(d["title"] ?? "?")"
    }
    return "unparseable"
}

final class HUDView: NSView {
    override func draw(_ r: NSRect) {
        NSColor.black.withAlphaComponent(0.8).setFill(); r.fill()
        let w = bounds.width/3
        let labels = ["⏮ prev", "⏯ play/pause", "⏭ next"]
        for i in 0..<3 {
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14)]
            labels[i].draw(at: NSPoint(x: CGFloat(i)*w + 14, y: bounds.midY-8), withAttributes: attrs)
        }
    }
}
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main!
let H = primary.frame.height
let W: CGFloat = 420, Ph: CGFloat = 120
let cocoaX = primary.frame.midX - W/2, cocoaY = primary.frame.midY - Ph/2
let panel = KeyPanel(contentRect: NSRect(x: cocoaX, y: cocoaY, width: W, height: Ph),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = NSWindow.Level(rawValue: 25)
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
panel.contentView = HUDView(frame: NSRect(x: 0, y: 0, width: W, height: Ph))
panel.orderFrontRegardless()

// global top-left rect of the HUD
let gLeft = cocoaX, gRight = cocoaX + W
let gTop = H - (cocoaY + Ph), gBottom = H - cocoaY

func missionControlActive() -> Bool {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
        if owner == "Dock" && layer == 20, let b = w[kCGWindowBounds as String] as? [String: Any],
           let wd = b["Width"] as? Double, wd > 1000 { return true }
    }
    return false
}

var interceptCount = 0
let cb: CGEventTapCallBack = { _, type, event, _ in
    let p = event.location  // global top-left
    if type == .leftMouseDown, p.x >= gLeft, p.x <= gRight, p.y >= gTop, p.y <= gBottom, missionControlActive() {
        let rel = p.x - gLeft, third = (gRight-gLeft)/3
        let region = rel < third ? "prev" : (rel < 2*third ? "playpause" : "next")
        interceptCount += 1
        log(">>> INTERCEPTED click in HUD during Mission Control, region=\(region) — swallowing + acting")
        DispatchQueue.global().async {
            switch region {
            case "prev": _ = mc(["previous-track"])
            case "next": _ = mc(["next-track"])
            default: _ = mc(["toggle-play-pause"])
            }
        }
        return nil  // swallow: MC does NOT see this click
    }
    return Unmanaged.passUnretained(event)
}
let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                  options: .defaultTap, eventsOfInterest: mask, callback: cb, userInfo: nil) else {
    log("FATAL: could not create event tap (need Accessibility permission)"); exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("HUD up at level 25; active HID tap installed. HUD global rect x[\(Int(gLeft))-\(Int(gRight))] y[\(Int(gTop))-\(Int(gBottom))]")

func openMC() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a","Mission Control"]; try? p.run(); p.waitUntilExit() }
func esc() { let s = CGEventSource(stateID: .combinedSessionState); CGEvent(keyboardEventSource: s, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: s, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap) }
func clickPlayPause() {
    let gx = gLeft + W/2, gy = gTop + Ph/2  // middle region
    let s = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: s, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: gx, y: gy), mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: s, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: gx, y: gy), mouseButton: .left)?.post(tap: .cghidEventTap)
}

DispatchQueue.global().async {
    usleep(500_000)
    log("BEFORE: \(playingState())")
    log("Opening Mission Control...")
    openMC(); usleep(1_200_000)
    log("MC active? \(missionControlActive())")
    log("Synthesizing a click on the play/pause region WHILE Mission Control is open...")
    clickPlayPause(); usleep(900_000)
    log("AFTER click during MC: \(playingState())  (intercepts=\(interceptCount))")
    log("Dismissing Mission Control...")
    esc(); usleep(300_000); esc(); usleep(800_000)
    // restore original playback state (toggle back)
    log("Restoring playback state (toggle back)...")
    _ = mc(["toggle-play-pause"]); usleep(500_000)
    log("RESTORED: \(playingState())")
    DispatchQueue.main.async { app.terminate(nil) }
}
app.run()

import Cocoa

// Probe B: Does a high-level (.statusBar=25 / .popUpMenu=101) stationary panel
//   (a) render ABOVE the Mission Control overlay (layer 20), and
//   (b) receive mouse clicks while Mission Control is active?
// We test with synthetic clicks + a passive HID event tap, all logged with timestamps.

let startMS = Date().timeIntervalSince1970
func ts() -> String { String(format: "%.3f", Date().timeIntervalSince1970 - startMS) }
func log(_ s: String) { print("[\(ts())] \(s)"); fflush(stdout) }

// ---- clickable content view that logs every mouse event ----
final class HitView: NSView {
    var hits = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        log("    hitTest called at \(point) -> self")
        return self
    }
    override func mouseDown(with event: NSEvent) {
        hits += 1
        log(">>> mouseDown RECEIVED on panel  (hit #\(hits))  loc=\(event.locationInWindow)")
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.85).setFill(); dirtyRect.fill()
    }
}

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// primary screen (origin at 0,0), used for coordinate conversion
let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main!
let H = primary.frame.height
let panelW: CGFloat = 360, panelH: CGFloat = 160
let cocoaX = primary.frame.midX - panelW/2
let cocoaY = primary.frame.midY - panelH/2

let panel = KeyPanel(contentRect: NSRect(x: cocoaX, y: cocoaY, width: panelW, height: panelH),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
let levelArg = CommandLine.arguments.contains("popup") ? 101 : 25   // 25=.statusBar, 101=.popUpMenu/.screenSaver
panel.level = NSWindow.Level(rawValue: levelArg)
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.ignoresMouseEvents = false
let hv = HitView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
panel.contentView = hv
panel.orderFrontRegardless()

let clickCocoaCenter = NSPoint(x: cocoaX + panelW/2, y: cocoaY + panelH/2)
let clickGlobal = CGPoint(x: clickCocoaCenter.x, y: H - clickCocoaCenter.y)  // top-left origin
log("panel created at level \(levelArg), cocoa frame \(panel.frame)")
log("synthetic click target (global top-left coords): \(clickGlobal)")

// ---- passive HID event tap: does ANY mouse event flow while MC is open? ----
var tapOK = false
let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
let cb: CGEventTapCallBack = { _, type, event, _ in
    let p = event.location
    log("    [HID TAP] saw \(type.rawValue == 1 ? "leftMouseDown" : "event\(type.rawValue)") at \(p)")
    return Unmanaged.passUnretained(event)
}
if let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                               options: .listenOnly, eventsOfInterest: mask, callback: cb, userInfo: nil) {
    let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    tapOK = true
    log("HID event tap created OK (Accessibility permission present)")
} else {
    log("HID event tap FAILED to create (no Accessibility permission) — tap test will be skipped")
}

func windowZOrder() -> String {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var out = "", rank = 0
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -9999
        let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
        if owner == "Dock" && layer >= 0 { out += "    z#\(rank) Dock layer=\(layer) [MC overlay]\n" }
        if pid == ProcessInfo.processInfo.processIdentifier { out += "    z#\(rank) OUR-PANEL layer=\(layer)\n" }
        rank += 1
    }
    return out.isEmpty ? "    (panel/Dock overlay not found in list)" : out
}

func click(_ p: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func openMC() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", "Mission Control"]; try? p.run(); p.waitUntilExit() }
func pressEscape() {
    let src = CGEventSource(stateID: .combinedSessionState)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
}

// ---- test sequence on background queue ----
DispatchQueue.global().async {
    usleep(500_000)
    log("STEP 1 (baseline, NO Mission Control): z-order of panel vs Dock:")
    print(windowZOrder())
    log("STEP 1: posting synthetic click at panel center (expect mouseDown to fire)...")
    click(clickGlobal)
    usleep(500_000)

    log("STEP 2: opening Mission Control...")
    openMC()
    usleep(1_100_000)
    log("STEP 2: z-order WHILE Mission Control is OPEN (is OUR-PANEL above Dock layer 20?):")
    print(windowZOrder())

    log("STEP 3: posting synthetic click at panel center DURING Mission Control...")
    let before = hv.hits
    click(clickGlobal)
    usleep(700_000)
    let after = hv.hits
    log("STEP 3 RESULT: panel mouseDown fired during MC? -> \(after > before ? "YES (clickable in MC!)" : "NO")  (hits \(before)->\(after))")

    log("STEP 4: dismissing Mission Control (Escape)...")
    pressEscape(); usleep(300_000); pressEscape()
    usleep(800_000)

    log("DONE. Summary:")
    log("  HID tap available: \(tapOK)")
    log("  total panel mouseDown hits: \(hv.hits)")
    DispatchQueue.main.async { app.terminate(nil) }
}

app.run()

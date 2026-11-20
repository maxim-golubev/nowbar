import Cocoa

// Probe D: during Mission Control, which tap sees mouseMoved — the HID tap, the
// session tap, or both? Deleting moved at the HID tap freezes the cursor; a session
// tap is placed after the cursor is moved, so deleting there suppresses MC's hover
// highlight without freezing. We need to know the session tap fires during MC.

let start = Date()
func ts() -> String { String(format: "%.2f", Date().timeIntervalSince(start)) }
func log(_ s: String) { print("[\(ts())] \(s)"); fflush(stdout) }

var hidCount = 0, sessCount = 0

let hidCB: CGEventTapCallBack = { _, _, e, _ in hidCount += 1; return Unmanaged.passUnretained(e) }
let sessCB: CGEventTapCallBack = { _, _, e, _ in sessCount += 1; return Unmanaged.passUnretained(e) }

let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)

func mkTap(_ loc: CGEventTapLocation, _ cb: @escaping CGEventTapCallBack) -> CFMachPort? {
    guard let t = CGEvent.tapCreate(tap: loc, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: mask, callback: cb, userInfo: nil) else { return nil }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return t
}

let hid = mkTap(.cghidEventTap, hidCB)
let sess = mkTap(.cgSessionEventTap, sessCB)
log("hid tap: \(hid != nil ? "ok" : "FAIL")  session tap: \(sess != nil ? "ok" : "FAIL")")

func openMC() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a","Mission Control"]; try? p.run(); p.waitUntilExit() }
func esc() { let s = CGEventSource(stateID: .combinedSessionState); CGEvent(keyboardEventSource: s, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: s, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap) }
func move(_ p: CGPoint) { CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }

DispatchQueue.global().async {
    usleep(400_000)
    // baseline (no MC)
    hidCount = 0; sessCount = 0
    for i in 0..<6 { move(CGPoint(x: 700 + i*8, y: 400)); usleep(60_000) }
    usleep(200_000)
    log("BASELINE (no MC): hid=\(hidCount) session=\(sessCount)")

    log("opening Mission Control")
    openMC(); usleep(1_200_000)
    hidCount = 0; sessCount = 0
    for i in 0..<10 { move(CGPoint(x: 900 + i*5, y: 500)); usleep(60_000) }
    usleep(300_000)
    log("DURING MC: hid=\(hidCount) session=\(sessCount)")
    log("  -> if session>0, a session tap can suppress the hover highlight cursor-safely")

    esc(); usleep(400_000); esc()
    DispatchQueue.main.async { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()

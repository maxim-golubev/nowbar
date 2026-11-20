import Cocoa
import ApplicationServices

// ---------------------------------------------------------------------------
// Event taps — clicks and hover on the HUD while Mission Control is open, the keys and
// clicks that close it, and the trackpad swipe that drives the fade.
// ---------------------------------------------------------------------------
extension Controller {
    func setTaps(enabled: Bool) {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: enabled) }
        if let t = moveTap { CGEvent.tapEnable(tap: t, enable: enabled) }
    }

    // ---- Mission Control click interception ----
    func installTap() {
        // Clicks on the HUD (its controls), plus the keys and clicks that close Mission Control.
        // Enabled only while MC is open (see setTaps), so it isn't observing input the rest of
        // the time.
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
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

        // Session-level tap: moves pointer-move events that land on the HUD during Mission
        // Control elsewhere (see hoverRelocation). It sits after the pointer is drawn, so the
        // pointer still moves; this only stops the Dock highlighting the thumbnail behind the
        // HUD. Drags are left alone: moving them would yank a thumbnail being dragged.
        let moveMask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        if let mt = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: moveMask,
                                      callback: moveTapCallback, userInfo: nil) {
            moveTap = mt
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mt, 0), .commonModes)
            CGEvent.tapEnable(tap: mt, enable: mcActive)   // off until Mission Control opens
            vlog("session (hover) tap installed")
        } else { vlog("session (hover) tap NOT created") }

        // Always on, but listen-only, and it asks only for Dock control events (CGS type 30),
        // which carry the Mission Control and space-switching swipes; it sees no keys and no
        // clicks. The opening swipe starts before Mission Control exists, so it can't wait for
        // the MC-only taps.
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

    var hudOnScreen: Bool { presented && panel.isVisible }

    // Where the Dock should think the pointer is while it is over the HUD in Mission Control, or
    // nil to leave the event alone. The far right edge of the HUD's display, at the same height:
    // on screen (the Dock ignores off-screen points and would keep the highlight), in the margin
    // beside the thumbnail grid, and clear of the spaces bar (top) and the Dock (bottom). The
    // pointer itself is unaffected.
    func hoverRelocation(at point: CGPoint) -> CGPoint? {
        guard mcActive, hudOnScreen, hudGlobalRect.contains(point) else { return nil }
        let cocoaY = primaryHeight - point.y
        for s in NSScreen.screens {
            let f = s.frame
            if point.x >= f.minX, point.x <= f.maxX, cocoaY >= f.minY, cocoaY <= f.maxY {
                return CGPoint(x: f.maxX - 2, y: point.y)
            }
        }
        return nil
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

    // Keys that close Mission Control. Others (Space, Tab, Ctrl-number, the arrows that switch
    // spaces) leave it open; a close not foreseen here is still caught by AXExposeExit, just at
    // the end of the animation instead of fading along with it.
    static func closesMissionControl(keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 53, 36, 76: return true                        // Escape, Return, keypad Enter
        case 99, 160:    return true                        // F3, the Mission Control key
        case 125, 126:   return flags.contains(.maskControl) // Ctrl-↓ (App Exposé), Ctrl-↑
        default:         return false
        }
    }

    // Called from the HID tap callback on the main run loop, only while Mission Control is open.
    // Returns true to swallow the event. `point` is global, top-left origin.
    func handleTap(type: CGEventType, point: CGPoint, keyCode: Int64, flags: CGEventFlags) -> Bool {
        let local = NSPoint(x: point.x - hudGlobalRect.minX, y: hudGlobalRect.maxY - point.y)

        // A press that began on the HUD owns the mouse until it is released, wherever the
        // pointer goes: its drags and its release are the HUD's (a scrub), and nobody else's.
        if hudOwnsPress {
            switch type {
            case .leftMouseDragged: drag(to: local); return true
            case .leftMouseUp: hudOwnsPress = false; release(); return true
            default: break
            }
        }
        guard mcActive else { return false }

        switch type {
        case .keyDown:
            if Self.closesMissionControl(keyCode: keyCode, flags: flags) { triggerHide() }
            return false
        case .leftMouseDown:
            hudOwnsPress = false; clickOrigin = nil   // a new press: nothing carried over from a lost release
            if hudOnScreen, hudGlobalRect.contains(point) {
                press(at: local)
                hudOwnsPress = true
                return true    // Mission Control never sees it, so it never selects the window behind
            }
            // Outside the HUD it may be a click on a thumbnail (which closes Mission Control) or
            // the start of a drag (which doesn't). The spaces bar never closes it.
            if !isInTopStrip(point) { clickOrigin = point }
            return false
        case .leftMouseUp:
            if let o = clickOrigin, hypot(point.x - o.x, point.y - o.y) < 5 { triggerHide() }
            clickOrigin = nil
            return false
        default:
            return false   // drags the HUD didn't start belong to the Dock
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
    let swallow = Controller.shared.handleTap(type: type, point: event.location, keyCode: kc, flags: event.flags)
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// Session tap callback -> pointer moves over the HUD are relocated, not deleted: deleting them
// would freeze the Dock's highlight state and leave a stale outline, while a point beside the
// thumbnail grid makes the Dock clear any highlight and never light up the thumbnail behind.
let moveTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let c = Controller.shared
        if c.mcActive, let t = c.moveTap { CGEvent.tapEnable(tap: t, enable: true) }   // see note above
        return Unmanaged.passUnretained(event)
    }
    if let safe = Controller.shared.hoverRelocation(at: event.location) { event.location = safe }
    return Unmanaged.passUnretained(event)
}

// Gesture tap callback -> Dock swipe progress (gesture type 23; other Dock control events are
// ignored). Listen-only; never alters the event.
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

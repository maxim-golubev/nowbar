import Cocoa

// ---------------------------------------------------------------------------
// Mission Control detection
// ---------------------------------------------------------------------------
// Polled: the window list sees MC ~120 ms after it starts opening, whereas the Dock's
// AXExposeShowAllWindows notification arrives ~400 ms in — polling is the faster signal.
enum MissionControl {
    static var dockPID: pid_t = currentDockPID()
    static func currentDockPID() -> pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first { !$0.isTerminated }?.processIdentifier ?? -1
    }

    // Mission Control stacks 2+ full-screen Dock windows (layers 20/18/0). A revealed
    // auto-hide Dock and Launchpad each make only ONE, so require at least two.
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

import Cocoa

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

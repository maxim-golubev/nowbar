import Cocoa
import ApplicationServices
import ServiceManagement

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
    var visible: Bool { mcShowing || menuShowing }

    // Why the HUD is hidden while Mission Control may still be open, and since when. Each cause
    // has its own grace: if MC is still open once it runs out, the hide was wrong and the HUD
    // comes back. Cleared once MC is fully gone.
    enum HideCause {
        case input          // a key or click that closes MC
        case spacesBarClick // a click on a desktop in the spaces bar: switches to it and closes MC,
                            // but a click on an empty spot doesn't, so it gets a short grace
        case prediction     // our reading of a released swipe
        case exposeExit     // the Dock said MC is closing
        var grace: TimeInterval {
            switch self {
            case .input: return 1.5
            case .spacesBarClick: return 0.6
            case .prediction, .exposeExit: return 0.8
            }
        }
    }
    var hiddenBy: HideCause?
    var hiddenAt = Date.distantPast
    func hide(because cause: HideCause) { hiddenBy = cause; hiddenAt = Date(); mcShowing = false }
    var outsideMonitor: Any?     // global click monitor for popover-style dismissal

    // presentation: `presented` is the intent; the panel may still be fading toward it
    var presented = false
    var fadeGen = 0              // invalidates the completion of a superseded fade
    var swipe: Swipe?            // a vertical Mission Control trackpad swipe currently steering the HUD
    struct Swipe { let opening: Bool; var progress = 0.0; var lastEvent = Date() }
    enum Fade {
        static let mission: TimeInterval = 0.22   // matches Mission Control's own open/close animation
        static let menu: TimeInterval = 0.12
    }
    var gestureTap: CFMachPort?  // listen-only: Dock swipe gesture events (no keys, no clicks)
    var dockObserver: AXObserver?  // AXExposeShowAllWindows / AXExposeExit from the Dock
    var dockObserverPID: pid_t = 0

    // geometry the tap reads (CG top-left coords), refreshed when the HUD moves
    var hudGlobalRect = CGRect.zero
    var mcActive = false
    var eventTap: CFMachPort?    // HID tap: intercept clicks in Mission Control
    var moveTap: CFMachPort?     // session tap: suppress hover-through highlight
    var hudOwnsPress = false     // a press that began on the HUD through the MC tap: its drags and release are ours
    var clickOrigin: CGPoint?    // where a press outside the HUD began; released in place, it's a click that closes MC
    var clickInSpacesBar = false // ...and whether it began in the spaces bar
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
    // The poll is how Mission Control *opening* is noticed (without a swipe), and the safety
    // net for everything else. Closing is event-driven: the closing keys and clicks (see
    // handleTap), the swipe, and AXExposeExit. The click and hover taps run only while MC is open.
    func tick() {
        if eventTap == nil && AXIsProcessTrusted() { installTap() }
        followDockRelaunch()
        if view.notice != nil, engine.available { view.notice = nil; view.needsDisplay = true }
        let nowMC = MissionControl.isActive()
        if nowMC != mcActive {
            mcActive = nowMC
            setTaps(enabled: nowMC)               // click and hover taps run only during Mission Control
            if !nowMC {
                hiddenBy = nil                    // reset once MC is fully gone
                clickOrigin = nil
                if hudOwnsPress { hudOwnsPress = false; view.scrub = nil }   // its release can no longer reach us
            }
        }
        // Safety net: if we hid but MC is still open well past its close animation, the hide was
        // wrong (a space switch, a misread swipe) — bring the HUD back.
        if let cause = hiddenBy, nowMC, swipe == nil, Date().timeIntervalSince(hiddenAt) > cause.grace {
            hiddenBy = nil
        }
        mcShowing = nowMC && hiddenBy == nil
        // A swipe whose end never arrived (a dropped event) must not keep the HUD half-faded.
        // Generous, because a finger resting mid-swipe sends nothing either.
        if let s = swipe, Date().timeIntervalSince(s.lastEvent) > 5 {
            vlog("swipe ended without an end event; settling")
            swipe = nil
            present(visible, over: Fade.mission)
        }
        updateVisibility()
        if VERBOSE {
            for (name, t) in [("click", eventTap), ("hover", moveTap)] {
                if let t, CGEvent.tapIsEnabled(tap: t) != mcActive { vlog("WARN \(name) tap enabled=\(!mcActive) while mcActive=\(mcActive)") }
            }
        }
        // Only a playing track (or an active scrub) changes the picture between stream updates.
        if visible, engine.np.playing || view.scrub != nil { view.needsDisplay = true }
    }

    // The Dock is a UI-element app, so NSWorkspace never announces its relaunch (`killall Dock`,
    // a crash): notice the old process is gone and follow the new one, or MC detection and the
    // Dock notifications would stay pointed at a dead PID.
    func followDockRelaunch() {
        let pid = MissionControl.dockPID
        let alive = pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH)
        if alive && dockObserverPID == pid { return }
        let now = alive ? pid : MissionControl.currentDockPID()
        guard now > 0 else { return }
        if now != pid { vlog("Dock is now pid \(now)") }
        MissionControl.dockPID = now
        if AXIsProcessTrusted() { installDockObserver() }
    }
}

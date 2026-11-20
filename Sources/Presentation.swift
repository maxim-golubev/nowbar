import Cocoa
import ApplicationServices

// ---------------------------------------------------------------------------
// Presentation — when the HUD is on screen and how it fades: with the menu-bar toggle,
// with Mission Control's own animations, and with the user's fingers during a swipe.
// ---------------------------------------------------------------------------
extension Controller {
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
            setAlphaNow(target)
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

    // Sets the opacity at once, replacing any fade in flight (a plain alphaValue write would be
    // overwritten by the running animation on its next step).
    func setAlphaNow(_ alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = alpha
        }
    }

    // ---- Mission Control trackpad swipe: the HUD's opacity follows the fingers ----
    // Dock swipes arrive as CGS event type 30 with gesture type 23 (field 110). Field 132 is the
    // IOHID phase (1 began, 2 changed, 4 ended, 8 cancelled), 123 the axis (2 = vertical) and the
    // double in 124 the progress: 0→1 opening Mission Control, 0→-1 closing it (App Exposé mirrors
    // the signs, so only the magnitude is used). 129 carries the release velocity.
    func dockSwipe(phase: Int64, axis: Int64, progress: Double, velocity: Double) {
        switch phase {
        case 1:
            // Only vertical swipes open and close Mission Control; one shown from the menu bar
            // stays put.
            guard axis == 2, !menuShowing else { return }
            // Ask the window list directly: the poll may be up to 200 ms stale here.
            let opening = !MissionControl.isActive()
            if !opening && !presented { return }   // closing an MC we were hidden in: nothing to fade
            swipe = Swipe(opening: opening)
            fadeGen &+= 1                          // the fingers rule now: no fade completion may act
            if opening {
                hiddenBy = nil
                presented = true
                if !panel.isVisible {
                    positionHUD(); view.needsDisplay = true
                    setAlphaNow(0)
                    panel.orderFrontRegardless()
                } else {
                    setAlphaNow(panel.alphaValue)  // stop a fade in flight where it is
                }
            } else {
                setAlphaNow(panel.alphaValue)
            }
        case 2:
            guard var s = swipe else { return }
            s.progress = progress; s.lastEvent = Date(); swipe = s
            let p = CGFloat(min(1, abs(progress)))
            panel.alphaValue = s.opening ? p : 1 - p
        case 4, 8:
            // Settled whatever the axis or menu state now: a swipe must never be left unfinished.
            guard let s = swipe else { return }
            swipe = nil
            let commits = phase == 4 && Self.swipeCommits(progress: s.progress, velocity: velocity)
            vlog("swipe \(s.opening ? "open" : "close") ended p=\(String(format: "%.2f", s.progress)) v=\(String(format: "%.2f", velocity)) -> \(commits ? "commit" : "cancel")")
            // The outcome is a prediction; AXExposeShowAllWindows / AXExposeExit (and, last, the
            // poll) correct it within a few hundred ms if macOS decided otherwise.
            let showAfter = s.opening == commits
            if !showAfter { hide(because: .prediction) }
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

    // Dock accessibility notifications. AXExposeShowAllWindows arrives once Mission Control has
    // finished opening; it can only undo our own wrong guess about a swipe, never a hide the user
    // caused (it may arrive after an Esc pressed during the opening animation). AXExposeExit
    // lands a few ms before the Dock's overlay windows are torn down, so hiding here (not on the
    // next poll) is what keeps the HUD from lingering alone at full opacity.
    func exposeShown() {
        guard swipe == nil, hiddenBy == .prediction, MissionControl.isActive() else { return }
        hiddenBy = nil
        mcShowing = true
        updateVisibility()
    }
    func exposeExited() {
        guard swipe == nil else { return }
        if mcShowing { hide(because: .exposeExit) }
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
        dockObserverPID = pid
        let dock = AXUIElementCreateApplication(pid)
        for n in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeExit"] {
            AXObserverAddNotification(o, dock, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        dockObserver = o
        vlog("dock observer installed")
    }

    // Fade out alongside Mission Control's close animation the moment the user does something
    // that closes it, rather than waiting for the window teardown.
    func triggerHide(because cause: HideCause) {
        guard mcShowing else { return }
        hide(because: cause)
        updateVisibility(fadeOut: Fade.mission)
    }
}

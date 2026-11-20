import Cocoa

// ---------------------------------------------------------------------------
// Self-test: prove the integrated app controls playback during Mission Control
// ---------------------------------------------------------------------------
func runSelfTest() {
    let c = Controller.shared
    guard let mc = mediaControlPath() else {
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
        vlog("SELFTEST mcActive=\(MissionControl.isActive())  hudRect=\(c.hudGlobalRect)")
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

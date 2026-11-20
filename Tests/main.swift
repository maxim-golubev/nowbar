import Cocoa

// NowBar's tests: the stream parser, the position maths, time formatting, the HUD's hit
// regions, and the swipe rule. No app, no screen, no media-control, no Mission Control.
//
//   ./test.sh

var failures = 0, passes = 0
func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    if ok { passes += 1 } else { failures += 1; print("FAIL \(what)  (\(file):\(line))") }
}
func near(_ a: Double, _ b: Double, _ eps: Double = 0.01) -> Bool { abs(a - b) < eps }
func settle(_ t: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
func nowMicros(minus seconds: Double = 0) -> Int64 { Int64((Date().timeIntervalSince1970 - seconds) * 1e6) }

// ---- mmss ----
check(mmss(0) == "0:00", "zero")
check(mmss(-3) == "0:00", "negative")
check(mmss(.nan) == "0:00", "NaN")
check(mmss(.infinity) == "0:00", "infinity")
check(mmss(59.4) == "0:59", "rounds down")
check(mmss(59.6) == "1:00", "rounds up")
check(mmss(266.866) == "4:27", "song length")
check(mmss(3725) == "1:02:05", "hours")

// ---- NowPlaying ----
do {
    var n = NowPlaying(); n.duration = 200; n.elapsed = 50
    n.stamp = Date(timeIntervalSinceNow: -10)
    check(near(n.liveElapsed(), 50), "paused position does not advance")
    n.playing = true
    check(near(n.liveElapsed(), 60, 0.05), "playing advances with wall time")
    n.rate = 2
    check(near(n.liveElapsed(), 70, 0.05), "advances at the playback rate")
    n.stamp = Date(timeIntervalSinceNow: -3600)
    check(n.liveElapsed() == 200, "clamped to the duration")
    let s: [String: Any] = ["title": "T", "durationMicros": 182_600_000, "elapsedTimeMicros": 6000,
                            "timestampEpochMicros": 1_795_210_243_773_314, "playing": true, "playbackRate": 1]
    let p = NowPlaying(s)
    check(near(p.duration, 182.6) && near(p.elapsed, 0.006, 1e-6), "micros keys")
    check(near(p.stamp.timeIntervalSince1970, 1_795_210_243.773314, 1e-5), "microsecond timestamp")
    let flat = NowPlaying(["title": "T", "duration": 266.866, "elapsedTime": 205.529,
                           "timestamp": "2026-11-20T18:45:00Z", "playing": false])
    check(near(flat.duration, 266.866) && near(flat.elapsed, 205.529), "plain `get` keys")
    check(near(flat.stamp.timeIntervalSince1970, 1_795_200_300), "ISO timestamp")
    check(NowPlaying(["title": "T"]).rate == 1, "no playbackRate means 1")
}

// ---- Engine: the stream protocol ----
do {
    let e = Engine()
    var published: [NowPlaying] = []
    e.onUpdate = { published.append($0) }
    var gen = 1                         // the stream instance the bytes come from
    func push(_ line: String) { e.feed(Data((line + "\n").utf8), gen: gen); e.waitUntilIdle() }

    // A full state, split inside the two-byte "Ø" across two chunks.
    let full = "{\"type\":\"data\",\"diff\":false,\"payload\":{\"title\":\"Øneheart – Café\",\"artist\":\"Ø\",\"album\":\"A\",\"bundleIdentifier\":\"com.spotify.client\",\"durationMicros\":200000000,\"elapsedTimeMicros\":50000000,\"timestampEpochMicros\":\(nowMicros(minus: 3600)),\"playing\":false}}\n"
    let bytes = Data(full.utf8)
    let cut = bytes.firstIndex(of: 0xC3)! + 1
    e.feed(bytes.prefix(upTo: cut), gen: 1); e.feed(bytes.suffix(from: cut), gen: 1); e.waitUntilIdle(); settle()
    check(e.np.title == "Øneheart – Café", "UTF-8 split across chunks: \(e.np.title)")
    check(!e.np.playing && near(e.np.liveElapsed(), 50), "paused at 50 s")

    // Resuming after an hour with a bare {"playing":true}: re-anchored, not slammed to the end.
    push("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":true}}"); settle()
    check(e.np.playing, "resume reflected")
    check(e.np.liveElapsed() < 51, "resume re-anchored (at \(e.np.liveElapsed()))")

    // Paused elsewhere (AirPods, keyboard, another app), and a key removed with null.
    push("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playbackRate\":2}}")
    push("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":false}}")
    push("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playbackRate\":null}}"); settle()
    check(!e.np.playing, "external pause reflected")
    check(e.np.rate == 1, "null removes playbackRate")
    let frozen = e.np.liveElapsed(); settle(0.2)
    check(near(e.np.liveElapsed(), frozen, 0.001), "position frozen while paused")

    // Two lines in one chunk, and a line split across three chunks.
    e.feed(Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"artist\":\"X\"}}\n{\"type\":\"data\",\"diff\":true,\"payload\":{\"album\":\"Y\"}}\n".utf8), gen: 1)
    e.feed(Data("{\"type\":\"data\",".utf8), gen: 1); e.feed(Data("\"diff\":true,\"payload\":".utf8), gen: 1)
    e.feed(Data("{\"title\":\"Z\"}}\n".utf8), gen: 1); e.waitUntilIdle(); settle()
    check(e.np.artist == "X" && e.np.album == "Y" && e.np.title == "Z", "several lines per chunk, one line over several")

    // A dead stream's leftover bytes never prefix the next stream's first line.
    e.feed(Data("{\"type\":\"data\",\"diff\":true,\"payl".utf8), gen: 1)
    e.feed(Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"title\":\"Fresh\"}}\n".utf8), gen: 2)
    e.feed(Data("oad\":{\"title\":\"Stale\"}}\n".utf8), gen: 1); e.waitUntilIdle(); settle()
    check(e.np.title == "Fresh", "stale stream bytes dropped (\(e.np.title))")
    gen = 2

    // Malformed and foreign lines are ignored.
    push("not json"); push("{\"type\":\"error\",\"message\":\"x\"}"); settle()
    check(e.np.title == "Fresh", "garbage ignored")

    // Artwork: from a diff; kept across a track change for a moment, then cleared.
    let img = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
    let b64 = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.base64EncodedString()
    push("{\"type\":\"data\",\"diff\":true,\"payload\":{\"artworkData\":\"\(b64)\"}}"); settle()
    check(e.artwork != nil, "artwork from a diff")
    push("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":true,\"elapsedTimeMicros\":1000,\"timestampEpochMicros\":\(nowMicros())}}"); settle()
    check(e.artwork != nil, "play/seek diffs keep the artwork")
    push("{\"type\":\"data\",\"diff\":false,\"payload\":{\"title\":\"Next\",\"artist\":\"B\",\"bundleIdentifier\":\"x\",\"playing\":true,\"durationMicros\":1000000,\"elapsedTimeMicros\":0,\"timestampEpochMicros\":\(nowMicros())}}"); settle()
    check(e.np.title == "Next" && e.artwork != nil, "previous cover held while the new one is on its way")
    settle(1.2)
    check(e.artwork == nil, "cleared when no cover arrives")

    // Nothing playing — but a restart's {} followed at once by the real state never flashes.
    published.removeAll()
    push("{\"type\":\"data\",\"diff\":false,\"payload\":{}}")
    push("{\"type\":\"data\",\"diff\":false,\"payload\":{\"title\":\"Keep\",\"bundleIdentifier\":\"x\"}}"); settle(0.4)
    check(!published.contains { $0.isEmpty } && e.np.title == "Keep", "restart does not flash 'Nothing playing'")
    push("{\"type\":\"data\",\"diff\":false,\"payload\":{}}"); settle(0.4)
    check(e.np.isEmpty && !e.np.playing, "a lasting {} means nothing playing")

    // A diff right after {} applies to the empty state: no ghost of the old track survives.
    push("{\"type\":\"data\",\"diff\":false,\"payload\":{\"title\":\"Ghost\",\"bundleIdentifier\":\"x\"}}")
    push("{\"type\":\"data\",\"diff\":false,\"payload\":{}}")
    push("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":false}}"); settle(0.4)
    check(e.np.title.isEmpty, "a diff after {} doesn't resurrect the old track (\(e.np.title))")

    // A flat `get` dump parses like a full state.
    push("{\"title\":\"Flat\",\"playing\":true,\"bundleIdentifier\":\"x\"}"); settle()
    check(e.np.title == "Flat" && e.np.playing, "flat get output")
}

// ---- Layout: what a click at each point does ----
do {
    func center(_ r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }
    if case .prev = Layout.region(at: center(Layout.prevRect)) { check(true, "") } else { check(false, "previous button") }
    if case .playpause = Layout.region(at: center(Layout.playRect)) { check(true, "") } else { check(false, "play button") }
    if case .next = Layout.region(at: center(Layout.nextRect)) { check(true, "") } else { check(false, "next button") }
    if case .seek(let f) = Layout.region(at: NSPoint(x: Layout.barRect.minX, y: Layout.barRect.midY)) {
        check(near(f, 0), "bar start = 0") } else { check(false, "bar start") }
    if case .seek(let f) = Layout.region(at: NSPoint(x: Layout.barRect.midX, y: Layout.barRect.midY - 8)) {
        check(near(f, 0.5), "bar is forgiving below") } else { check(false, "bar middle") }
    if case .playpause = Layout.region(at: NSPoint(x: Layout.barRect.midX, y: Layout.barRect.midY + 8)) {
        check(true, "") } else { check(false, "just above the bar, the play button wins") }
    if case .none = Layout.region(at: center(Layout.art)) { check(true, "") } else { check(false, "artwork is inert") }
    check(Layout.barFraction(-100) == 0 && Layout.barFraction(10_000) == 1, "drag fraction clamps")
    for r in [Layout.prevRect, Layout.playRect, Layout.nextRect, Layout.barRect, Layout.art] {
        check(NSRect(x: 0, y: 0, width: Layout.W, height: Layout.H).contains(r), "\(r) inside the HUD")
    }
}

// ---- Keys that close Mission Control ----
check(Controller.closesMissionControl(keyCode: 53, flags: []), "Escape closes")
check(Controller.closesMissionControl(keyCode: 36, flags: []), "Return closes")
check(Controller.closesMissionControl(keyCode: 160, flags: []), "the Mission Control key closes")
check(Controller.closesMissionControl(keyCode: 126, flags: .maskControl), "Ctrl-↑ closes")
check(!Controller.closesMissionControl(keyCode: 126, flags: []), "a plain ↑ doesn't")
check(!Controller.closesMissionControl(keyCode: 123, flags: .maskControl), "Ctrl-← switches spaces")
check(!Controller.closesMissionControl(keyCode: 49, flags: []), "Space doesn't")
check(!Controller.closesMissionControl(keyCode: 18, flags: .maskControl), "Ctrl-1 doesn't")

// ---- Swipe release rule ----
check(Controller.swipeCommits(progress: 0.43, velocity: 1.09), "flick on while opening commits")
check(Controller.swipeCommits(progress: -0.80, velocity: -1.02), "flick on while closing commits")
check(!Controller.swipeCommits(progress: 0.60, velocity: -0.8), "flick back cancels an open")
check(!Controller.swipeCommits(progress: -0.70, velocity: 0.9), "flick back cancels a close")
check(Controller.swipeCommits(progress: 0.55, velocity: 0), "released at rest past halfway commits")
check(!Controller.swipeCommits(progress: 0.30, velocity: 0.05), "released at rest before halfway cancels")

print(failures == 0 ? "\(passes) passed" : "\(failures) FAILED, \(passes) passed")
exit(failures == 0 ? 0 : 1)

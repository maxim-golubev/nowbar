import Cocoa

// Homebrew's location on Apple Silicon, then on Intel. Looked up each time it's needed, so
// installing media-control while NowBar runs is picked up without a relaunch.
func mediaControlPath() -> String? {
    ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

// ---------------------------------------------------------------------------
// media-control engine: one long-lived `stream` plus serialized commands.
//
// Stream protocol (one JSON object per line):
//   {"type":"data","diff":false,"payload":{…full state…}}   new track / initial / nothing playing ({})
//   {"type":"data","diff":true, "payload":{…changed keys…}} null value = key removed
// Artwork rides along in the stream, but only when it changes (it arrives ~30 ms after a
// track change as its own diff), so it costs nothing on play/pause/seek updates.
//
// All parsing state lives on `q`; results are published to the main thread.
// ---------------------------------------------------------------------------
final class Engine {
    var onUpdate: ((NowPlaying) -> Void)?   // main thread
    private(set) var np = NowPlaying()      // main thread
    private(set) var artwork: NSImage?      // main thread
    var available: Bool { mediaControlPath() != nil }

    private let q = DispatchQueue(label: "nowbar.engine")
    private let cmdQ = DispatchQueue(label: "nowbar.commands")   // serial: commands run in click order

    // --- q-only state ---
    private var truth: [String: Any] = [:]     // what the stream last told us
    private var overlay: [String: Any] = [:]   // optimistic values from our own commands
    private var overlayExpiry = Date.distantPast
    private var buf = Data()
    private var trackKey = ""
    private var artKey = ""                    // track the current artwork belongs to
    private var art: NSImage?
    private var emptyGen = 0                   // cancels a pending deferred "nothing playing"
    private var bufGen = 0                     // which stream instance `buf` holds bytes from
    private var pendingEmpty = false           // an empty full state is being held back

    // --- main-only state ---
    private var stream: Process?
    private var restartDelay = 1.0
    private var streamStarted = Date()
    private var stopping = false
    private var streamGen = 0

    func start() {
        guard available else {
            vlog("media-control not found; looking again in 5 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
            return
        }
        launchStream()
    }

    func stop() {
        stopping = true
        stream?.terminate()
    }

    private func launchStream() {
        guard !stopping else { return }
        guard let exe = mediaControlPath() else { streamEnded(-1); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["stream", "--micros"]
        streamGen += 1
        let gen = streamGen
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice   // an unread stderr pipe would eventually block the child
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }   // EOF: unhook, or this spins forever
            self?.q.async { self?.feed(d, gen: gen) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.streamEnded(proc.terminationStatus) }
        }
        streamStarted = Date()   // set before trying, so failed launches back off too
        do {
            try p.run(); stream = p; vlog("stream started (pid \(p.processIdentifier))")
        } catch {
            vlog("stream failed: \(error)"); streamEnded(-1)
        }
    }

    // The stream should live forever; if it dies (brew upgrade, crash) bring it back with backoff.
    private func streamEnded(_ status: Int32) {
        stream = nil
        guard !stopping else { return }
        if Date().timeIntervalSince(streamStarted) > 30 { restartDelay = 1 }
        vlog("stream exited (\(status)); restarting in \(restartDelay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in self?.launchStream() }
        restartDelay = min(restartDelay * 2, 30)
    }

    // Split on raw newline bytes *before* decoding: a chunk boundary can fall inside a
    // multi-byte UTF-8 character (accented titles), which would make the chunk undecodable.
    // Bytes are tagged per stream instance so a dead stream's tail can't corrupt the new one.
    // Internal (not private) so the tests can drive the parser with recorded stream bytes.
    func feed(_ d: Data, gen: Int) {
        if gen < bufGen { return }
        if gen > bufGen { buf.removeAll(); bufGen = gen }
        buf.append(d)
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if !line.isEmpty { ingest(line) }
        }
    }

    private static let timeKeys = ["elapsedTimeMicros", "timestampEpochMicros", "elapsedTime", "timestamp"]

    private func ingest(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let payload: [String: Any], isDiff: Bool
        if let p = obj["payload"] as? [String: Any] {
            payload = p; isDiff = (obj["diff"] as? Bool) ?? false
        } else if obj["type"] == nil {
            payload = obj; isDiff = false             // flat `get` output
        } else { return }

        // Every (re)started stream opens with an empty full state and sends the real one right
        // after; switching player apps does the same. Hold an empty state back briefly so these
        // don't flash "Nothing playing" and drop the artwork. Only a full state replaces it; a
        // diff applies on top of it, so it goes in first.
        emptyGen &+= 1
        if !isDiff, payload.isEmpty, !truth.isEmpty {
            pendingEmpty = true
            let g = emptyGen
            q.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.emptyGen == g, self.pendingEmpty else { return }
                self.pendingEmpty = false
                self.apply([:], isDiff: false)
            }
            return
        }
        if pendingEmpty {
            pendingEmpty = false
            if isDiff { apply([:], isDiff: false) }
        }
        apply(payload, isDiff: isDiff)
    }

    private func apply(_ payload: [String: Any], isDiff: Bool) {
        let before = NowPlaying(truth)
        if !isDiff { truth.removeAll(); overlay.removeAll() }
        for (k, v) in payload where k != "artworkData" {
            if v is NSNull { truth.removeValue(forKey: k) } else { truth[k] = v }
            overlay.removeValue(forKey: k)            // the real value has arrived
        }
        // Position and its timestamp only make sense together: a real one of either replaces
        // the optimistic pair.
        if Self.timeKeys.contains(where: { payload[$0] != nil }) {
            for k in Self.timeKeys { overlay.removeValue(forKey: k) }
        }

        // A bare {"playing":…} diff keeps the old elapsed/timestamp pair. Re-anchor it at the
        // transition, otherwise resuming after a long pause would extrapolate from the
        // pause-time timestamp and slam the progress bar to the end.
        var after = NowPlaying(truth)
        if isDiff, before.playing != after.playing, !Self.timeKeys.contains(where: { payload[$0] != nil }) {
            anchor(&truth, at: before.liveElapsed())
            after = NowPlaying(truth)
        }

        let key = after.trackKey
        if let a = payload["artworkData"] {
            art = (a as? String).flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) }
            artKey = key
        } else if after.isEmpty {
            art = nil; artKey = key
        } else if key != trackKey {
            // New track without artwork yet: keep the previous cover briefly (the new one
            // normally lands within ~30 ms) instead of flashing the placeholder.
            q.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.artworkTimedOut(key) }
        }
        trackKey = key
        publish()
    }

    private func anchor(_ s: inout [String: Any], at position: Double) {
        s["elapsedTimeMicros"] = position * 1e6
        s["timestampEpochMicros"] = Date().timeIntervalSince1970 * 1e6
        s.removeValue(forKey: "elapsedTime"); s.removeValue(forKey: "timestamp")
    }

    private func current() -> NowPlaying {
        guard overlayExpiry > Date() else { return NowPlaying(truth) }
        return NowPlaying(truth.merging(overlay) { _, o in o })
    }

    private func publish() {
        if overlayExpiry <= Date() { overlay.removeAll() }
        let n = current(), a = art
        DispatchQueue.main.async {
            self.np = n; self.artwork = a
            self.onUpdate?(n)
        }
    }

    private func artworkTimedOut(_ key: String) {
        guard trackKey == key, artKey != key else { return }
        art = nil; artKey = key
        publish()
        if NowPlaying(truth).bundleID == "com.spotify.client" { fetchSpotifyArtwork(for: key) }
    }

    // Fallback when MediaRemote carries no artwork: Spotify exposes a cover URL via AppleScript.
    private func fetchSpotifyArtwork(for key: String) {
        DispatchQueue.global(qos: .utility).async {
            // Guarded so it never relaunches a Spotify the user has just quit.
            let script = "if application \"Spotify\" is running then tell application \"Spotify\" to return artwork url of current track"
            let url = run("/usr/bin/osascript", ["-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.hasPrefix("http"), let u = URL(string: url) else { return }
            URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
                guard let self, let data, let img = NSImage(data: data) else { return }
                self.q.async {
                    guard self.trackKey == key, self.art == nil else { return }
                    self.art = img; self.publish()
                }
            }.resume()
        }
    }

    // Optimistic local state for our own commands, so the HUD reacts on click instead of
    // after the stream round-trip. Real stream values replace it key by key; if the command
    // had no effect, it lapses after 2 s and the HUD falls back to the truth.
    private func optimistic(_ mutate: @escaping (inout [String: Any], NowPlaying) -> Void) {
        q.async {
            let cur = self.current()
            guard !cur.isEmpty else { return }
            if self.overlayExpiry <= Date() { self.overlay.removeAll() }
            mutate(&self.overlay, cur)
            self.overlayExpiry = Date().addingTimeInterval(2)
            self.publish()
            self.q.asyncAfter(deadline: .now() + 2.05) { self.publish() }
        }
    }

    func setPlaying(_ play: Bool) {
        optimistic { o, cur in o["playing"] = play; self.anchor(&o, at: cur.liveElapsed()) }
        send([play ? "play" : "pause"])
    }

    func seek(_ seconds: Double) {
        let t = max(0, seconds)
        optimistic { o, _ in self.anchor(&o, at: t) }
        send(["seek", String(format: "%.2f", t)])
    }

    // Tests: block until everything queued on the parsing queue has run.
    func waitUntilIdle() { q.sync {} }

    func next()     { send(["next-track"]) }
    func previous() { send(["previous-track"]) }

    private func send(_ args: [String]) {
        guard let exe = mediaControlPath() else { return }
        cmdQ.async { run(exe, args) }
    }
}

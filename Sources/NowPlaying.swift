import Foundation

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
struct NowPlaying {
    var title = "", artist = "", album = "", bundleID = ""
    var duration = 0.0, elapsed = 0.0, rate = 1.0
    var playing = false
    var stamp = Date()           // when `elapsed` was measured

    var isEmpty: Bool { title.isEmpty }
    var trackKey: String { [bundleID, title, artist, album].joined(separator: "\u{1F}") }

    func liveElapsed(at now: Date = Date()) -> Double {
        var t = elapsed
        if playing { t += now.timeIntervalSince(stamp) * rate }
        if duration > 0 { t = min(t, duration) }
        return max(0, t)
    }

    // Build from media-control's key/value state. Accepts both `--micros` keys and the
    // plain ones so a flat `get` dump parses the same way as the stream.
    init() {}
    init(_ s: [String: Any]) {
        func num(_ k: String) -> Double? { (s[k] as? NSNumber)?.doubleValue }
        title    = s["title"] as? String ?? ""
        artist   = s["artist"] as? String ?? ""
        album    = s["album"] as? String ?? ""
        bundleID = s["bundleIdentifier"] as? String ?? ""
        duration = num("durationMicros").map { $0 / 1e6 } ?? num("duration") ?? 0
        elapsed  = num("elapsedTimeMicros").map { $0 / 1e6 } ?? num("elapsedTime") ?? 0
        rate     = num("playbackRate") ?? 1      // absent while paused
        playing  = (s["playing"] as? NSNumber)?.boolValue ?? false
        if let us = num("timestampEpochMicros") {
            stamp = Date(timeIntervalSince1970: us / 1e6)
        } else if let iso = s["timestamp"] as? String, let d = ISO8601DateFormatter().date(from: iso) {
            stamp = d
        }
    }
}

func mmss(_ t: Double) -> String {
    guard t.isFinite, t > 0 else { return "0:00" }
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s/3600, s/60%60, s%60) : String(format: "%d:%02d", s/60, s%60)
}

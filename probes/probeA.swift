import CoreGraphics
import Foundation

// Probe A: census on-screen windows before / during Mission Control to find the
// Dock overlay's window layer and how the menu-bar / ControlCenter windows behave.

func windows() -> [[String: Any]] {
    let opts: CGWindowListOption = [.optionOnScreenOnly]
    return (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
}

struct W {
    let owner: String, pid: Int, layer: Int, name: String, alpha: Double, b: String, num: Int
}

func parse(_ list: [[String: Any]]) -> [W] {
    list.map { w in
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -9999
        let name = w[kCGWindowName as String] as? String ?? ""
        let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
        let num = (w[kCGWindowNumber as String] as? Int) ?? -1
        var bstr = "?"
        if let bb = w[kCGWindowBounds as String] as? [String: Any],
           let x = bb["X"] as? Double, let y = bb["Y"] as? Double,
           let ww = bb["Width"] as? Double, let hh = bb["Height"] as? Double {
            bstr = "(\(Int(x)),\(Int(y)) \(Int(ww))x\(Int(hh)))"
        }
        return W(owner: owner, pid: pid, layer: layer, name: name, alpha: alpha, b: bstr, num: num)
    }
}

func dump(_ label: String, _ ws: [W]) {
    print("\n========== \(label): \(ws.count) on-screen windows ==========")
    // layer histogram
    var hist: [Int: Int] = [:]
    for w in ws { hist[w.layer, default: 0] += 1 }
    let hs = hist.keys.sorted().map { "\($0):\(hist[$0]!)" }.joined(separator: "  ")
    print("layer histogram -> \(hs)")
    // detail for interesting owners or non-zero layers
    let interesting = ["Dock", "Control Center", "ControlCenter", "Window Server", "WindowServer",
                       "Wallpaper", "Spotlight", "NotificationCenter", "Notification Center"]
    for w in ws.sorted(by: { $0.layer > $1.layer }) {
        if w.layer != 0 || interesting.contains(w.owner) {
            let nm = w.name.isEmpty ? "" : " name=\"\(w.name)\""
            print(String(format: "  layer=%5d alpha=%.2f win#%d pid=%d owner=%@%@ bounds=%@",
                         w.layer, w.alpha, w.num, w.pid, w.owner, nm, w.b))
        }
    }
}

func sh(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = args
    try? p.run(); p.waitUntilExit()
}

print("Probe A start. Triggering Mission Control programmatically and sampling window layers.")

let before = parse(windows())
dump("BEFORE Mission Control", before)

// trigger Mission Control
sh(["-a", "Mission Control"])
usleep(900_000)
let during1 = parse(windows())
dump("DURING Mission Control (t=0.9s)", during1)

usleep(600_000)
let during2 = parse(windows())
dump("DURING Mission Control (t=1.5s)", during2)

// what's NEW during MC vs before (match by window number)
let beforeNums = Set(before.map { $0.num })
let newWins = during2.filter { !beforeNums.contains($0.num) }
print("\n>>> NEW windows that appeared during Mission Control:")
for w in newWins.sorted(by: { $0.layer > $1.layer }) {
    print(String(format: "  layer=%5d alpha=%.2f win#%d pid=%d owner=%@ bounds=%@",
                 w.layer, w.alpha, w.num, w.pid, w.owner, w.b))
}

// dismiss Mission Control (toggle off)
sh(["-a", "Mission Control"])
usleep(700_000)
// belt & suspenders: also post Escape
let src = CGEventSource(stateID: .combinedSessionState)
if let down = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
   let up = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
}
usleep(500_000)
let after = parse(windows())
dump("AFTER (Mission Control dismissed)", after)
print("\nProbe A done.")

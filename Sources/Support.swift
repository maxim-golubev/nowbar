import Foundation

// Logging for --verbose / --selftest, and the one helper for running a child process.

let VERBOSE = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("--selftest")
func vlog(_ s: String) { if VERBOSE { FileHandle.standardError.write(Data(("[NowBar] " + s + "\n").utf8)) } }

// Run a helper to completion and return stdout. A watchdog ends one that hangs (SIGTERM, then
// SIGKILL a second later), so a stuck helper can't wedge the serial command queue.
@discardableResult
func run(_ exe: String, _ args: [String], timeout: TimeInterval = 5) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let pid = p.processIdentifier
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        guard p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(pid, SIGKILL) } }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

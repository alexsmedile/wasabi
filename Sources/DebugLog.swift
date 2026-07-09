import Foundation

/// Opt-in debug logging to /tmp/wasabi.log.
///
/// Logging here is synchronous file I/O (open → seek → write → close). On the
/// navigation path (`didFinish` fires per load) that's main-thread disk work on
/// every call, so it's **off by default** and gated behind an env flag. Set
/// `WASABI_DEBUG_LOG=1` in the environment to enable it during development.
///
/// When disabled, `DebugLog.write` is a single bool check and returns immediately
/// — zero I/O, zero allocation of the formatted line beyond the caller's string.
enum DebugLog {
    /// Resolved once at startup from the environment.
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WASABI_DEBUG_LOG"] == "1"

    private static let logURL = URL(fileURLWithPath: "/tmp/wasabi.log")

    /// Append a line to the debug log if logging is enabled. The `line` closure is
    /// only evaluated when enabled, so callers pay nothing to build the string when
    /// logging is off.
    static func write(_ tag: String, _ line: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = "[\(tag)] \(line())\n"
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

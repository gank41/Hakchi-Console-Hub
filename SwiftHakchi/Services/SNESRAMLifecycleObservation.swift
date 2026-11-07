import Foundation

/// Incomplete prefixes are valid: the RAM owner might have been killed.
enum SNESRAMLifecycleObservation {
    enum Invalid: Error { case frame }
    private static let allowed: Set<String> = ["OWNER_START", "POWER_READY", "WAIT_BEGIN", "WAIT_DONE", "GAME_STARTED", "SIGNAL_RECEIVED", "TRANSITION_BEGIN", "GAME_REAPED", "TRANSITION_FINISH", "POWER_OFF", "FAILURE", "OWNER_RETURN", "ARGUMENTS_FAILED", "TERM_SETUP_FAILED"]
    static func parse(_ data: Data) throws -> [String] {
        guard data.count <= 4096, let text = String(data: data, encoding: .ascii), text.hasSuffix("\n") else { throw Invalid.frame }
        let events = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        guard !events.isEmpty, events.count <= 64, events.first == "OWNER_START", events.allSatisfy({ allowed.contains($0) }) else { throw Invalid.frame }
        return events
    }
    static let command = #"""
    set -eu
    B=/probe/busybox
    f=/probe/trial-owner-lifecycle
    test -f "$B" && test ! -L "$B"
    test -f "$f" && test ! -L "$f"
    size=$("$B" wc -c < "$f")
    test "$size" -gt 0 && test "$size" -le 4096
    "$B" cat "$f"
    """#
}

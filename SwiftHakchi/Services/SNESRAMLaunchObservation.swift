import Foundation
import SwiftHakchiCore

/// Ephemeral, option-value-free evidence from the experimental RAM launcher.
struct SNESRAMLaunchObservation {
    struct Transition { let role: String, number: Int?, kind: String }
    let parent: Int, transitions: [Transition]
    enum Invalid: Error { case frame }
    static func envelope(_ script: String) throws -> (command: String, input: Data) {
        let input = Data(script.trimmingCharacters(in: .newlines).utf8)
        guard !input.isEmpty, input.count <= 65536, !input.contains(0) else { throw Invalid.frame }
        let hash = BackupManifest.digest(input)
        let command = "B=/probe/busybox; s=$(\"$B\" head -c " + String(input.count) + "); h=$(printf '%s' \"$s\" | \"$B\" sha256sum); [ \"${h%% *}\" = '" + hash + "' ] || exit 1; eval \"$s\" </dev/null"
        return (command, input)
    }
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 4096, let text = String(data: data, encoding: .ascii) else { throw Invalid.frame }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 4, lines.first == "HC-MENU-OBS-V1", lines.last == "", lines[lines.count-2] == "END" else { throw Invalid.frame }
        let parentFields = lines[1].split(separator: " ", omittingEmptySubsequences: false)
        guard parentFields.count == 2, parentFields[0] == "PARENT", let parent = Int(parentFields[1]), parent > 0, parent <= 4_194_304 else { throw Invalid.frame }
        var values: [Transition] = []
        for line in lines.dropFirst(2).dropLast(2) {
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            guard f.count == 4, f[0] == "ARG", ["wait", "start", "finish"].contains(String(f[1])),
                  ["eventfd", "missing", "other", "invalid"].contains(String(f[3])), values.count < 64 else { throw Invalid.frame }
            let number: Int?
            if f[3] == "invalid" { guard f[2] == "-" else { throw Invalid.frame }; number = nil }
            else { guard let n = Int(f[2]), n >= 3, n <= 255 else { throw Invalid.frame }; number = n }
            values.append(.init(role: String(f[1]), number: number, kind: String(f[3])))
        }
        return .init(parent: parent, transitions: values)
    }
    static let command = #"""
    set -eu
    B=/probe/busybox
    f=/probe/trial-manager-observation
    test -f "$B" && test ! -L "$B"
    test -f "$f" && test ! -L "$f"
    size=$("$B" wc -c < "$f")
    test "$size" -gt 0 && test "$size" -le 4096
    "$B" cat "$f"
    """#
}

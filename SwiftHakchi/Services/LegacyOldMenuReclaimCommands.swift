import Foundation
import SwiftHakchiCore

/// Deletes only the former menu directory owned by one accepted operation.
/// Host-side inventory proof and a durable intent are required before this runs.
enum LegacyOldMenuReclaimCommands {
    private static func preflight(operationID: UUID, liveTreeSHA256: String,
                                  oldTreeSHA256: String) throws -> String {
        guard oldTreeSHA256.range(of: #"^[a-f0-9]{64}$"#,
                                 options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("The former menu identity is invalid.")
        }
        let prefix = try LegacyArchiveReclaimCommands.acceptedOldMenuPrefix(
            operationID: operationID, treeSHA256: liveTreeSHA256)
        return prefix + "\n" + #"""
        [ "$(stat -c '%d:%i' "$old")" != "$(stat -c '%d:%i' "$live")" ] || exit 130
        [ "$(tree_digest "$old" include)" = '\#(oldTreeSHA256)' ] || exit 131
        old_device=$(stat -c %d "$old") || exit 132
        find "$old" -type d -print | while IFS= read -r directory; do
          [ "$(stat -c %d "$directory")" = "$old_device" ] || exit 133
        done
        """#
    }

    static func inspect(operationID: UUID, liveTreeSHA256: String,
                        oldTreeSHA256: String) throws -> String {
        try preflight(operationID: operationID, liveTreeSHA256: liveTreeSHA256,
                      oldTreeSHA256: oldTreeSHA256) + "\n" + #"""
        allocated=$(du -sk "$old" | awk '{print $1}') || exit 135
        case "$allocated" in ''|*[!0-9]*) exit 135;; esac
        [ "$allocated" -gt 0 ] && [ "$allocated" -le 524288 ] || exit 135
        printf 'OLDMENU_RECLAIM_V1\nID=\#(operationID.uuidString)\nOLD_SHA256=\#(oldTreeSHA256)\nALLOCATED_KIB=%s\nEND\n' "$allocated"
        """#
    }

    static func remove(operationID: UUID, liveTreeSHA256: String,
                       oldTreeSHA256: String) throws -> String {
        try preflight(operationID: operationID, liveTreeSHA256: liveTreeSHA256,
                      oldTreeSHA256: oldTreeSHA256) + "\n" + #"""
        # The exact tree and operation-owned inode were checked immediately above.
        # Do not run a global sync here; it stalled the older Clovershell service.
        rm -r -- "$old"
        [ ! -e "$old" ] && [ ! -L "$old" ] || exit 134
        printf 'RECLAIMED_OLD_MENU:\#(operationID.uuidString):\#(oldTreeSHA256)\n'
        """#
    }

    static func parseInspection(_ data: Data, operationID: UUID,
                                oldTreeSHA256: String) throws -> Int64 {
        guard data.count <= 512, let text = String(data: data, encoding: .ascii) else {
            throw LegacyInspectionError.invalidResponse
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count == 5, lines[0] == "OLDMENU_RECLAIM_V1",
              lines[1] == "ID=\(operationID.uuidString)",
              lines[2] == "OLD_SHA256=\(oldTreeSHA256)",
              lines[3].hasPrefix("ALLOCATED_KIB="),
              let kib = Int64(lines[3].dropFirst("ALLOCATED_KIB=".count)),
              kib > 0, kib <= 524_288, lines[4] == "END" else {
            throw LegacyInspectionError.invalidResponse
        }
        return kib * 1024
    }

    static func requireRemovedReceipt(_ result: SSHResult, operationID: UUID,
                                      oldTreeSHA256: String) throws {
        let expected = Data("RECLAIMED_OLD_MENU:\(operationID.uuidString):\(oldTreeSHA256)\n".utf8)
        guard result.succeeded, result.stderr.isEmpty,
              result.stdoutData == expected else {
            throw LegacyInspectionError.invalidResponse
        }
    }
}

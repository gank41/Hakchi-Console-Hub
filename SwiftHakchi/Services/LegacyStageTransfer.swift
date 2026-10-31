import Foundation
import SwiftHakchiCore

/// The only Clovershell file-upload destination: a unique inactive transaction directory.
enum LegacyStageTransfer {
    static func directory(for operationID: UUID) -> String {
        "/var/lib/hakchi/.swift-hakchi-sync-" + operationID.uuidString
    }

    static func command(operationID: UUID, sha256: String, bytes: Int64) throws -> String {
        guard bytes > 0, bytes <= 256 * 1024 * 1024,
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("The reviewed legacy archive length or hash is invalid.")
        }
        let path = directory(for: operationID)
        return """
        set -eu
        umask 077
        d='\(path)'; f="$d/menu.tar.partial"
        [ ! -e "$d" ] && [ ! -L "$d" ] || exit 41
        mkdir "$d"
        head -c \(bytes) > "$f"
        size=$(wc -c < "$f" | tr -d ' ')
        [ "$size" = '\(bytes)' ] || exit 42
        sum=$(sha256sum "$f")
        [ "${sum%% *}" = '\(sha256)' ] || exit 43
        mv "$f" "$d/menu.tar"
        sync
        printf 'STAGED:\(operationID.uuidString):\(sha256):\(bytes)\n'
        """
    }

    static func requireReceipt(_ result: SSHResult, operationID: UUID, sha256: String, bytes: Int64) throws {
        let expected = "STAGED:\(operationID.uuidString):\(sha256):\(bytes)\n"
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData == Data(expected.utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
    }
}

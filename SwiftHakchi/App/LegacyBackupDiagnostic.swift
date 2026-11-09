import Foundation
import SwiftHakchiCore

/// Read-only preservation path after restoring the legacy USB service.
enum LegacyBackupDiagnostic {
    static func run(client: any LegacyRequestExecuting, destination: URL,
                    expectedFingerprint: String? = nil) async throws -> String {
        let id = try await LegacyDeviceIdentity.read(client: client)
        if let expectedFingerprint, !LegacyDeviceIdentity.matches(id, fingerprint: expectedFingerprint) {
            throw LegacyChangeError.refused("This legacy console's chip identity does not match the reviewed NES. No backup was accepted.")
        }
        let report = try await LegacyConsoleService.inspect(client: client)
        let backup = try await LegacyConsoleService.backup(client: client, report: report, destination: destination,
                                                           expectedChipID: id)
        try LegacyGameChangeService.verifyBackup(backup)
        guard try await LegacyDeviceIdentity.read(client: client) == id else {
            throw LegacyChangeError.refused("The connected console changed while its backup was being checked. The backup was not accepted for this operation.")
        }
        let fields: [String: Any] = ["mode": "backup-legacy-console", "identityMatched": true,
                                     "backupDirectory": backup.path, "verified": true,
                                     "USBOpened": true, "gamesChanged": false]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}

import Foundation
import SwiftHakchiCore

/// Read-only first-NES preservation path after restoring its legacy USB service.
enum LegacyBackupDiagnostic {
    static func run(client: any LegacyRequestExecuting, destination: URL,
                    expectedFingerprint: String = LegacyBoot2ActivationPlan.supportedHWIDSHA256) async throws -> String {
        let id = try await LegacyDeviceIdentity.read(client: client)
        guard LegacyDeviceIdentity.matches(id, fingerprint: expectedFingerprint) else {
            throw LegacyChangeError.refused("This legacy console's chip identity does not match the reviewed NES. No backup was accepted.")
        }
        let report = try await LegacyConsoleService.inspect(client: client)
        let backup = try await LegacyConsoleService.backup(client: client, report: report, destination: destination)
        try LegacyGameChangeService.verifyBackup(backup)
        let fields: [String: Any] = ["mode": "backup-legacy-console", "identityMatched": true,
                                     "backupDirectory": backup.path, "verified": true,
                                     "USBOpened": true, "gamesChanged": false]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}

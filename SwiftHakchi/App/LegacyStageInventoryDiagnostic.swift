import Foundation
import SwiftHakchiCore

/// Read-only inspection of an already uploaded, inactive trial tree.
@MainActor enum LegacyStageInventoryDiagnostic {
    static func run(operationID: UUID, reconcile: Bool = false) async throws -> String {
        try RecoveryFirmwareJournalPolicy.requireOwner()
        let workspace = AppConfig.shared.workspace
        let store = LegacySyncJournalStore(directory: workspace.journals)
        guard let journal = try await store.latestUnresolved(),
              journal.operationID == operationID, journal.phase == .uploaded,
              journal.stageDirectory.deletingLastPathComponent().standardizedFileURL
                == workspace.root.appendingPathComponent("Stages").standardizedFileURL else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let manifest = try JSONDecoder().decode(LegacyMenuStageManifest.self,
            from: Data(contentsOf: journal.stageDirectory.appendingPathComponent("manifest.json")))
        guard manifest.menuDirectory.deletingLastPathComponent().standardizedFileURL == journal.stageDirectory,
              manifest.treeSHA256 == journal.treeSHA256,
              manifest.archiveSHA256 == journal.archiveSHA256,
              manifest.archiveBytes == journal.archiveBytes,
              manifest.entries.count <= LegacyStageVerification.maximumEntries else {
            throw LegacySyncJournalError.invalidRecord
        }
        try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
        let client = LegacyInspectionClient()
        try await client.connect(timeoutMilliseconds: 3000)
        do {
            let lease = try await client.reserveForChange()
            do {
                try LegacyDeviceIdentity.requireFirstNES(try await LegacyDeviceIdentity.read(client: lease))
                let result = try await lease.perform(.inventoryStage(operationID))
                guard result.succeeded, result.stderr.isEmpty else {
                    throw LegacyChangeError.refused("Read-only stage inventory failed at step \(result.exitCode). The menu was not changed.")
                }
                let differences = try LegacyStageVerification.compareInventory(result.stdoutData,
                    operationID: operationID, expected: manifest.entries)
                let lines = String(decoding: result.stdoutData, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                let description = lines.dropFirst().dropLast(2).joined(separator: "\n") + "\n"
                let actualSHA = BackupManifest.digest(Data(description.utf8))
                if reconcile {
                    guard differences.isEmpty, actualSHA == manifest.treeSHA256 else {
                        throw LegacyChangeError.refused("The inactive NES tree does not match the Mac manifest. The saved operation was not advanced.")
                    }
                    try LegacyGameChangeService.verifyBackup(journal.backupDirectory)
                    let inspected = try await lease.perform(.inspectStage(operationID, manifest.treeSHA256))
                    guard inspected.succeeded, inspected.stderr.isEmpty else {
                        throw LegacyInspectionError.invalidResponse
                    }
                    let state = try LegacySyncCommands.parseInspection(inspected.stdoutData,
                        operationID: operationID)
                    guard state.phase == .missing, state.outcome == .beforeRename,
                          state.transaction, state.archive, state.stage, state.verified,
                          state.live, !state.old, !state.failed, !state.lock else {
                        throw LegacySyncJournalError.invalidTransition
                    }
                    try await store.advance(operationID, from: .uploaded, to: .verified)
                }
                await lease.release()
                await client.disconnect()
                let fields: [String: Any] = [
                    "mode": "inspect-legacy-stage", "USBOpened": true, "gamesChanged": false,
                    "operationID": operationID.uuidString, "expectedTreeSHA256": manifest.treeSHA256,
                    "actualTreeSHA256": actualSHA, "expectedEntries": manifest.entries.count,
                    "actualEntries": lines.count - 3, "differenceCount": differences.count,
                    "firstDifferences": Array(differences.prefix(20)),
                    "journalAdvanced": reconcile ? "verified" : "none"
                ]
                return String(decoding: try JSONSerialization.data(withJSONObject: fields,
                    options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
            } catch {
                await lease.release()
                throw error
            }
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

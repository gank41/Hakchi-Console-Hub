import Foundation
import SwiftHakchiCore

protocol LegacyArchiveReclaimDevice: Sendable {
    func inspect() async throws -> LegacyConsoleReport
    func requireIdentity() async throws
    func inspectOperation(operationID: UUID, treeSHA256: String) async throws -> LegacySyncInspection
    func inventoryLive(operationID: UUID) async throws -> Data
    func inspectArchive(operationID: UUID, treeSHA256: String,
                        archiveSHA256: String, archiveBytes: Int64) async throws -> LegacyArchiveReclaimCommands.Inspection
    func removeArchive(operationID: UUID, treeSHA256: String,
                       archiveSHA256: String, archiveBytes: Int64) async throws
}

enum LegacyArchiveReclaimError: Error, LocalizedError {
    case activeMenuChanged([String])
    case menuComparisonUnavailable(String)
    case menuDigestMismatch(String)

    var errorDescription: String? {
        switch self {
        case .activeMenuChanged(let differences):
            if differences.isEmpty {
                return "The active NES menu no longer matches the accepted library. The transfer archive was left in place."
            }
            return "The active NES menu differs from the accepted library (\(differences.prefix(3).joined(separator: "; "))). The transfer archive was left in place."
        case .menuComparisonUnavailable(let reason):
            return "The NES menu could not be compared with its saved file list: \(reason). The transfer archive was left in place."
        case .menuDigestMismatch(let digest):
            return "The NES menu file list matches the saved stage, but its console digest differs (\(digest)). The transfer archive was left in place."
        }
    }
}

enum LegacyArchiveReclaim {
    struct Preview: Sendable {
        let operationID: UUID
        let archiveBytes: Int64
        let freeBytes: Int64
        let archiveSHA256: String
        let treeSHA256: String
        let stageDirectory: URL
        let backupDirectory: URL
    }

    static func preview(record: LegacySyncJournal, workspace: WorkspacePaths,
                        device: any LegacyArchiveReclaimDevice) async throws -> Preview {
        try record.validate()
        guard record.phase == .accepted,
              record.stageDirectory.deletingLastPathComponent().standardizedFileURL == workspace.root.appendingPathComponent("Stages", isDirectory: true),
              workspace.containsBackup(record.backupDirectory) else {
            throw LegacySyncJournalError.invalidRecord
        }
        let local = try LegacySyncPlan.SourceFile.capture(record.stageDirectory.appendingPathComponent("menu.tar"))
        guard local.byteCount == record.archiveBytes,
              local.sha256 == record.archiveSHA256 else { throw LegacySyncJournalError.invalidRecord }
        try LegacyGameChangeService.verifyBackup(record.backupDirectory)
        let backupManifest = try Data(contentsOf: record.backupDirectory.appendingPathComponent("manifest.json"))
        guard backupManifest.count <= 131_072,
              let object = try JSONSerialization.jsonObject(with: backupManifest) as? [String: Any],
              object["sha256"] as? String == record.backupSHA256 else {
            throw LegacySyncJournalError.invalidRecord
        }
        try await device.requireIdentity()
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        let state: LegacySyncInspection
        do {
            state = try await device.inspectOperation(operationID: record.operationID,
                                                       treeSHA256: record.treeSHA256)
        } catch {
            throw LegacyChangeError.refused("Could not read the accepted NES menu state: \(error.localizedDescription)")
        }
        guard state.phase == .accepted, state.outcome == .newTreePresent,
              state.transaction, state.live, state.old, !state.stage,
              !state.failed, !state.lock, state.archive else {
            throw LegacySyncJournalError.invalidTransition
        }
        let archive: LegacyArchiveReclaimCommands.Inspection
        do {
            archive = try await device.inspectArchive(operationID: record.operationID,
                treeSHA256: record.treeSHA256, archiveSHA256: record.archiveSHA256,
                archiveBytes: record.archiveBytes)
        } catch let error as LegacyArchiveReclaimError {
            if case .activeMenuChanged = error {
                let manifestURL = record.stageDirectory.appendingPathComponent("manifest.json")
                guard let manifest = try? JSONDecoder().decode(LegacyMenuStageManifest.self,
                    from: Data(contentsOf: manifestURL)),
                    manifest.treeSHA256 == record.treeSHA256,
                    manifest.archiveSHA256 == record.archiveSHA256,
                    manifest.archiveBytes == record.archiveBytes else {
                    throw LegacyArchiveReclaimError.menuComparisonUnavailable("the Mac stage manifest is missing or changed")
                }
                let inventory: Data
                do { inventory = try await device.inventoryLive(operationID: record.operationID) }
                catch { throw LegacyArchiveReclaimError.menuComparisonUnavailable(error.localizedDescription) }
                let differences: [String]
                do {
                    differences = try LegacyStageVerification.compareInventory(inventory,
                        operationID: record.operationID, expected: manifest.entries)
                } catch {
                    throw LegacyArchiveReclaimError.menuComparisonUnavailable(error.localizedDescription)
                }
                if !differences.isEmpty { throw LegacyArchiveReclaimError.activeMenuChanged(differences) }
                let lines = String(decoding: inventory, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                let listing = lines.dropFirst().dropLast(2).joined(separator: "\n") + "\n"
                let digest = BackupManifest.digest(Data(listing.utf8))
                throw LegacyArchiveReclaimError.menuDigestMismatch(digest)
            }
            throw error
        } catch {
            throw LegacyChangeError.refused("Could not verify the NES transfer archive: \(error.localizedDescription)")
        }
        guard archive.archivePresent, archive.archiveBytes == record.archiveBytes else {
            throw LegacyInspectionError.invalidResponse
        }
        return Preview(operationID: record.operationID, archiveBytes: record.archiveBytes,
                       freeBytes: report.freeBytes, archiveSHA256: record.archiveSHA256,
                       treeSHA256: record.treeSHA256, stageDirectory: record.stageDirectory,
                       backupDirectory: record.backupDirectory)
    }
}

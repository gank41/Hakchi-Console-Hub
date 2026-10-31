import Foundation
import SwiftHakchiCore

/// Selects a device-bound Mac snapshot only when it matches the console's live menu files.
enum LegacyCurrentBackup {
    struct Selection: Sendable {
        let directory: URL
        let archiveSHA256: String
        let treeSHA256: String
        let chipIDFingerprint: String
        let observedReport: LegacyConsoleReport
    }

    static func find(report: LegacyConsoleReport, device: any LegacySavedMenuRestoreDevice,
                     workspace: WorkspacePaths) async throws -> Selection? {
        try await device.requireIdentity()
        let chipID = try await device.chipID()
        let fresh = try await device.inspect()
        try LegacyGameChangeService.validateReport(fresh, against: report)
        guard fresh.visibleCodes == report.visibleCodes else { return nil }
        let candidates = LegacyBackupHistory.scan(roots: workspace.knownBackupRoots)
            .filter { $0.status == .restorable && workspace.containsBackup($0.directory) }
        guard !candidates.isEmpty else { return nil }
        let operationID = UUID()
        let live = try await device.inventoryLive(operationID: operationID)
        for candidate in candidates {
            guard let snapshot = try? LegacyMenuSnapshot.verify(directory: candidate.directory,
                                                                 expectedChipID: chipID),
                  snapshot.observedReport.matchesLayout(of: fresh),
                  snapshot.observedReport.visibleCodes == fresh.visibleCodes,
                  snapshot.observedReport.stockCodes == fresh.stockCodes,
                  let differences = try? LegacyStageVerification.compareInventory(live,
                      operationID: operationID, expected: snapshot.entries),
                  differences.isEmpty else { continue }
            return Selection(directory: candidate.directory,
                archiveSHA256: snapshot.manifest.archiveSHA256,
                treeSHA256: snapshot.menuTreeSHA256,
                chipIDFingerprint: snapshot.manifest.chipIDFingerprint,
                observedReport: snapshot.observedReport)
        }
        return nil
    }

    static func requireCurrent(_ selected: Selection, report: LegacyConsoleReport,
                               device: any LegacySavedMenuRestoreDevice,
                               workspace: WorkspacePaths) async throws {
        guard workspace.containsBackup(selected.directory) else {
            throw LegacyInspectionError.invalidBackup
        }
        try await device.requireIdentity()
        let chipID = try await device.chipID()
        let snapshot = try LegacyMenuSnapshot.verify(directory: selected.directory,
                                                     expectedChipID: chipID)
        guard snapshot.manifest.archiveSHA256 == selected.archiveSHA256,
              snapshot.menuTreeSHA256 == selected.treeSHA256,
              snapshot.manifest.chipIDFingerprint == selected.chipIDFingerprint else {
            throw LegacyInspectionError.invalidBackup
        }
        let fresh = try await device.inspect()
        try LegacyGameChangeService.validateReport(fresh, against: report)
        guard fresh.visibleCodes == selected.observedReport.visibleCodes,
              fresh.stockCodes == selected.observedReport.stockCodes,
              snapshot.observedReport.matchesLayout(of: fresh) else {
            throw LegacyInspectionError.invalidBackup
        }
        let operationID = UUID()
        let live = try await device.inventoryLive(operationID: operationID)
        guard try LegacyStageVerification.compareInventory(live,
            operationID: operationID, expected: snapshot.entries).isEmpty else {
            throw LegacyInspectionError.invalidBackup
        }
    }
}

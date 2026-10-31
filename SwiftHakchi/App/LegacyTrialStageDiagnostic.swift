import Foundation
import SwiftHakchiCore

/// Local-only dry run; the CLI branch never creates a USB client.
@MainActor enum LegacyTrialStageDiagnostic {
    static func run(code: String, backup: URL) throws -> String {
        guard LegacyChangeScripts.validCode(code) else { throw SyncPlanError.invalidInput("Choose one valid custom NES code.") }
        let expectedBackupRoot = RecoveryFirmwareJournalPolicy.root.deletingLastPathComponent()
        guard backup.standardizedFileURL.deletingLastPathComponent() == expectedBackupRoot else {
            throw SyncPlanError.invalidInput("Use a verified backup in the private NES Backups folder.")
        }
        try RecoveryFirmwareJournalPolicy.requireOwner()
        let library = try LegacyBackupLibrary.read(backup)
        let manager = GameManagerService()
        manager.loadGames()
        let local = manager.legacyLocalGames
        guard local.contains(where: { $0.code == code }) else { throw SyncPlanError.missingFile(code) }
        let plan = try LegacySyncPlan.make(localGames: local, remoteGames: library.games,
                                          report: library.report, selectedCodes: [code],
                                          maximumGamesPerPage: AppConfig.shared.consoleMenuLimit.rawValue,
                                          trialCode: code)
        let stages = AppConfig.shared.workspace.root.appendingPathComponent("Stages", isDirectory: true)
        try FileManager.default.createDirectory(at: stages, withIntermediateDirectories: true)
        let stage = try LegacyMenuStage.build(plan: plan, in: stages, verifiedBackup: backup)
        let values: [String: Any] = [
            "mode": "stage-legacy-trial", "USBOpened": false, "gamesChanged": false,
            "trialCode": code, "selectedGames": plan.selectedGames.count,
            "menuPages": plan.pages.count, "addedGames": plan.addedCodes.count,
            "oldGamesLeavingMenu": plan.removedCodes.count,
            "requiredStagingBytes": plan.requiredStagingBytes,
            "freeBytesAtBackup": plan.freeBytesAtReview,
            "reviewSHA256": plan.reviewSHA256,
            "stageDirectory": stage.menuDirectory.deletingLastPathComponent().path,
            "archiveSHA256": stage.archiveSHA256,
            "archiveBytes": stage.archiveBytes
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}

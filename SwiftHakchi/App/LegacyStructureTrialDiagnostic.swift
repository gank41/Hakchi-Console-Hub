import Foundation
import SwiftHakchiCore

/// A private, one-layout NES hardware trial. The public app keeps this layout preview-only.
@MainActor enum LegacyStructureTrialDiagnostic {
    private struct Recipe: Codable {
        let operationID: UUID
        let importedCode: String
        let backupDirectory: URL
        let reviewSHA256: String
        let treeSHA256: String
    }

    private static let workspace = AppConfig.shared.workspace
    private static var stages: URL { workspace.root.appendingPathComponent("Stages", isDirectory: true) }
    private static let structure = ConsoleStructure(mode: .stockRootFoldersEqual,
        maximumGamesPerPage: .twentyFive, backPosition: .bottom, folderArt: .classic)

    static func prepare(code: String, backup: URL) throws -> String {
        try RecoveryFirmwareJournalPolicy.requireOwner()
        guard LegacyChangeScripts.validCode(code), code.hasPrefix("CLV-H-") else {
            throw SyncPlanError.invalidInput("Choose one imported NES game code.")
        }
        let fixedBackups = RecoveryFirmwareJournalPolicy.root.deletingLastPathComponent()
        guard backup.standardizedFileURL.deletingLastPathComponent() == fixedBackups else {
            throw SyncPlanError.invalidInput("Use a verified backup in the private NES Backups folder.")
        }
        let plan = try makePlan(code: code, backup: backup)
        try FileManager.default.createDirectory(at: stages, withIntermediateDirectories: true)
        let manifest = try LegacyMenuStage.build(plan: plan, in: stages, verifiedBackup: backup)
        let id = UUID()
        let recipe = Recipe(operationID: id, importedCode: code,
            backupDirectory: backup.standardizedFileURL, reviewSHA256: plan.reviewSHA256,
            treeSHA256: manifest.treeSHA256)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: manifest.menuDirectory.deletingLastPathComponent()
            .appendingPathComponent("structure-trial.json"), options: .atomic)
        return try json(["mode": "prepare-structure-trial", "USBOpened": false,
            "gamesChanged": false, "operationID": id.uuidString, "importedCode": code,
            "selectedGames": plan.selectedGames.count, "screenCount": plan.menuGraph.screens.count,
            "rootEntries": plan.menuGraph.screens[0].gameCodes.count + plan.menuGraph.screens[0].links.count,
            "requiredStagingBytes": plan.requiredStagingBytes,
            "freeBytesAtBackup": plan.freeBytesAtReview,
            "reviewSHA256": plan.reviewSHA256, "treeSHA256": manifest.treeSHA256,
            "archiveSHA256": manifest.archiveSHA256, "archiveBytes": manifest.archiveBytes,
            "stageDirectory": manifest.menuDirectory.deletingLastPathComponent().path])
    }

    static func stage(operationID: UUID) async throws -> String {
        let (recipe, plan, manifest) = try load(operationID)
        try await withDevice { device in
            try await LegacySyncTransaction(store: LegacySyncJournalStore(directory: workspace.journals),
                workspace: workspace).stage(operationID: operationID, plan: plan, manifest: manifest,
                    backup: recipe.backupDirectory, device: device)
        }
        return try json(["mode": "stage-structure-trial", "operationID": operationID.uuidString,
            "phase": "verified", "menuChanged": false, "treeSHA256": manifest.treeSHA256])
    }

    static func activate(operationID: UUID) async throws -> String {
        let (recipe, plan, manifest) = try load(operationID)
        let store = LegacySyncJournalStore(directory: workspace.journals)
        let journal = try await store.load(operationID)
        guard journal.phase == .verified, journal.treeSHA256 == recipe.treeSHA256 else {
            throw LegacySyncJournalError.invalidTransition
        }
        try await withDevice { device in
            try await LegacySyncTransaction(store: store, workspace: workspace).activate(
                operationID: operationID, plan: plan, manifest: manifest,
                backup: recipe.backupDirectory, device: device)
        }
        return try json(["mode": "activate-structure-trial", "operationID": operationID.uuidString,
            "phase": "activePendingAcceptance", "menuChanged": true,
            "rollbackAvailable": true, "treeSHA256": manifest.treeSHA256])
    }

    static func rollback(operationID: UUID) async throws -> String {
        try RecoveryFirmwareJournalPolicy.requireOwner()
        let store = LegacySyncJournalStore(directory: workspace.journals)
        let journal = try await store.load(operationID)
        let fixedBackups = RecoveryFirmwareJournalPolicy.root.deletingLastPathComponent()
        guard journal.resolvedScope == .full, journal.resolvedStructure == structure,
              journal.selectedCodes?.count == 31, journal.reviewedLocalCodes == [],
              journal.backupDirectory.deletingLastPathComponent() == fixedBackups,
              journal.stageDirectory.deletingLastPathComponent() == stages.standardizedFileURL,
              [.activationIntent, .uncertain, .activePendingAcceptance].contains(journal.phase) else {
            throw LegacySyncJournalError.invalidTransition
        }
        try await withDevice { device in
            try await LegacySyncTransaction(store: store, workspace: workspace).rollback(
                operationID: operationID, device: device)
        }
        return try json(["mode": "rollback-structure-trial", "operationID": operationID.uuidString,
            "phase": "rolledBack", "oldMenuRestored": true])
    }

    private static func makePlan(code: String, backup: URL) throws -> LegacySyncPlan {
        let library = try LegacyBackupLibrary.read(backup)
        let manager = GameManagerService()
        manager.loadGames()
        let local = manager.legacyLocalGames
        guard local.contains(where: { $0.code == code }) else { throw SyncPlanError.missingFile(code) }
        let selected = library.report.stockCodes.union([code])
        return try LegacySyncPlan.make(localGames: local, remoteGames: library.games,
            report: library.report, selectedCodes: selected,
            maximumGamesPerPage: structure.maximumGamesPerPage.rawValue, trialCode: nil,
            consoleOrder: .title, structure: structure)
    }

    private static func load(_ id: UUID) throws -> (Recipe, LegacySyncPlan, LegacyMenuStageManifest) {
        try RecoveryFirmwareJournalPolicy.requireOwner()
        let directories = try FileManager.default.contentsOfDirectory(at: stages,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let matches = try directories.compactMap { folder -> (Recipe, LegacyMenuStageManifest)? in
            guard folder.lastPathComponent.hasPrefix("LegacyMenuStage-"),
                  folder.standardizedFileURL.deletingLastPathComponent() == stages.standardizedFileURL,
                  (try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
                  (try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isSymbolicLink != true else { return nil }
            let recipeURL = folder.appendingPathComponent("structure-trial.json")
            guard FileManager.default.fileExists(atPath: recipeURL.path) else { return nil }
            let recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: recipeURL))
            guard recipe.operationID == id else { return nil }
            let manifest = try JSONDecoder().decode(LegacyMenuStageManifest.self,
                from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            guard manifest.menuDirectory.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                  manifest.archiveURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                  recipe.treeSHA256 == manifest.treeSHA256 else { throw LegacySyncJournalError.invalidRecord }
            return (recipe, manifest)
        }
        guard matches.count == 1, let (recipe, manifest) = matches.first else {
            throw LegacySyncJournalError.missingOperation
        }
        let fixedBackups = RecoveryFirmwareJournalPolicy.root.deletingLastPathComponent()
        guard recipe.backupDirectory.standardizedFileURL.deletingLastPathComponent() == fixedBackups else {
            throw LegacySyncJournalError.invalidRecord
        }
        let plan = try makePlan(code: recipe.importedCode, backup: recipe.backupDirectory)
        guard plan.reviewSHA256 == recipe.reviewSHA256,
              manifest.reviewSHA256 == recipe.reviewSHA256 else { throw LegacySyncJournalError.invalidRecord }
        return (recipe, plan, manifest)
    }

    private static func withDevice<T>(_ body: (LegacySyncLeaseDevice) async throws -> T) async throws -> T {
        try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
        let client = LegacyInspectionClient()
        try await client.connect(timeoutMilliseconds: 3000)
        do {
            let lease = try await client.reserveForChange()
            do {
                try LegacyDeviceIdentity.requireFirstNES(try await LegacyDeviceIdentity.read(client: lease))
                let value = try await body(LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                await client.disconnect()
                return value
            } catch { await lease.release(); throw error }
        } catch { await client.disconnect(); throw error }
    }

    private static func json(_ fields: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields,
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}

import Foundation
import SwiftHakchiCore

protocol LegacySavedMenuRestoreDevice: LegacySyncDevice {
    func chipID() async throws -> String
    func inventoryLive(operationID: UUID) async throws -> Data
}

/// Restores one selected device-bound Mac menu through the existing inactive-stage protocol.
actor LegacySavedMenuRestore {
    struct Preview: Sendable {
        let operationID: UUID
        let snapshotDirectory: URL
        let snapshotArchiveSHA256: String
        let chipID: String
        let previousOperationID: UUID
        let previousTreeSHA256: String
        let selectedCodes: [String]
        let freeBytes: Int64
        let requiredBytes: Int64
        let stage: LegacyMenuStageManifest
    }

    private let workspace: WorkspacePaths
    private let store: LegacySyncJournalStore
    private var working = false

    init(workspace: WorkspacePaths) {
        self.workspace = workspace
        store = LegacySyncJournalStore(directory: workspace.journals)
    }

    func prepare(snapshotDirectory: URL, device: any LegacySavedMenuRestoreDevice) async throws -> Preview {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        guard try await store.latestUnresolved() == nil,
              try LegacyGameChangeService.latest(workspace: workspace) == nil,
              workspace.containsBackup(snapshotDirectory) else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        try await device.requireIdentity()
        let chipID = try await device.chipID()
        let snapshot = try LegacyMenuSnapshot.verify(directory: snapshotDirectory,
                                                     expectedChipID: chipID)
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        guard snapshot.observedReport.stockCodes == report.stockCodes,
              snapshot.observedReport.bootVersion == report.bootVersion,
              snapshot.observedReport.kernelVersion == report.kernelVersion,
              snapshot.observedReport.scriptVersion == report.scriptVersion else {
            throw LegacyInspectionError.invalidBackup
        }
        let previous = try await currentMenu(report: report, device: device)
        try await requireSavedCurrentMenu(report: report, device: device)
        let stage = try LegacySavedMenuStage.build(snapshotDirectory: snapshotDirectory,
            expectedChipID: chipID, in: workspace.root.appendingPathComponent("Stages"))
        let (twice, overflow) = stage.archiveBytes.multipliedReportingOverflow(by: 2)
        let (required, extraOverflow) = twice.addingReportingOverflow(64 * 1024 * 1024)
        guard !overflow, !extraOverflow, required <= report.freeBytes else {
            try? FileManager.default.removeItem(at: stage.menuDirectory.deletingLastPathComponent())
            throw SyncPlanError.insufficientSpace(required: overflow || extraOverflow ? Int64.max : required,
                                                  available: report.freeBytes)
        }
        return Preview(operationID: UUID(), snapshotDirectory: snapshotDirectory,
            snapshotArchiveSHA256: snapshot.manifest.archiveSHA256, chipID: chipID,
            previousOperationID: previous.operationID, previousTreeSHA256: previous.treeSHA256,
            selectedCodes: LegacyMenuSnapshot.gameCodes(snapshot.entries).sorted(),
            freeBytes: report.freeBytes, requiredBytes: required, stage: stage)
    }

    func transfer(_ preview: Preview, device: any LegacySavedMenuRestoreDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        guard try await store.latestUnresolved() == nil,
              workspace.containsBackup(preview.snapshotDirectory),
              preview.stage.menuDirectory.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == workspace.root.appendingPathComponent("Stages"),
              try await device.chipID() == preview.chipID else {
            throw LegacySyncJournalError.invalidRecord
        }
        let snapshot = try LegacyMenuSnapshot.verify(directory: preview.snapshotDirectory,
                                                     expectedChipID: preview.chipID)
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        let previous = try await currentMenu(report: report, device: device)
        try await requireSavedCurrentMenu(report: report, device: device)
        guard previous.operationID == preview.previousOperationID,
              previous.treeSHA256 == preview.previousTreeSHA256,
              snapshot.manifest.archiveSHA256 == preview.snapshotArchiveSHA256,
              LegacyMenuSnapshot.gameCodes(snapshot.entries).sorted() == preview.selectedCodes,
              preview.stage.treeSHA256 == snapshot.menuTreeSHA256,
              try LegacySyncPlan.SourceFile.capture(preview.stage.archiveURL).sha256 == preview.stage.archiveSHA256,
              report.freeBytes >= preview.requiredBytes else {
            throw LegacySyncJournalError.invalidRecord
        }
        let record = try LegacySyncJournal(operationID: preview.operationID,
            snapshot: snapshot, backupDirectory: preview.snapshotDirectory,
            stage: preview.stage, previous: previous)
        try await store.begin(record)
        try await device.upload(preview.stage, operationID: preview.operationID)
        try await store.advance(preview.operationID, from: .prepared, to: .uploaded)
        try await device.verify(preview.stage, operationID: preview.operationID,
                                stageBudgetBytes: preview.stage.archiveBytes)
        try await store.advance(preview.operationID, from: .uploaded, to: .verified)
    }

    func activate(operationID: UUID, device: any LegacySavedMenuRestoreDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        let record = try await store.load(operationID)
        guard record.resolvedScope == .savedMenu, record.phase == .verified,
              let binding = record.savedMenuBinding else {
            throw LegacySyncJournalError.invalidTransition
        }
        try await device.requireIdentity()
        let chipID = try await device.chipID()
        guard LegacyDeviceIdentity.matches(chipID, fingerprint: binding.chipIDFingerprint) else {
            throw LegacyInspectionError.invalidBackup
        }
        let snapshot = try LegacyMenuSnapshot.verify(directory: record.backupDirectory,
                                                     expectedChipID: chipID)
        let stage = try stageManifest(for: record)
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        let previous = try await currentMenu(report: report, device: device)
        try await requireSavedCurrentMenu(report: report, device: device)
        guard previous.operationID == binding.previousOperationID,
              previous.treeSHA256 == binding.previousTreeSHA256,
              snapshot.manifest.archiveSHA256 == binding.snapshotArchiveSHA256,
              stage.treeSHA256 == snapshot.menuTreeSHA256,
              report.freeBytes >= 64 * 1024 * 1024 else {
            throw LegacySyncJournalError.invalidRecord
        }
        try await store.advance(operationID, from: .verified, to: .activationIntent)
        do {
            try await device.activate(stage, operationID: operationID)
            let state = try await device.inspectOperation(operationID: operationID,
                                                          treeSHA256: stage.treeSHA256)
            guard state.phase == .menuStarted, state.outcome == .newTreePresent,
                  state.lock else { throw LegacyInspectionError.invalidResponse }
            try await store.advance(operationID, from: .activationIntent,
                                    to: .activePendingAcceptance)
        } catch {
            try? await store.markUncertain(operationID)
            throw error
        }
    }

    func accept(operationID: UUID, mainMenuConfirmed: Bool,
                device: any LegacySavedMenuRestoreDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        let record = try await store.load(operationID)
        guard record.resolvedScope == .savedMenu, let binding = record.savedMenuBinding,
              LegacyDeviceIdentity.matches(try await device.chipID(),
                                           fingerprint: binding.chipIDFingerprint) else {
            throw LegacySyncJournalError.invalidRecord
        }
        let snapshot = try LegacyMenuSnapshot.verify(directory: record.backupDirectory,
                                                     expectedChipID: try await device.chipID())
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        guard report.visibleCodes == Set(record.selectedCodes ?? []),
              snapshot.manifest.archiveSHA256 == binding.snapshotArchiveSHA256 else {
            throw LegacyInspectionError.invalidBackup
        }
        let stage = try stageManifest(for: record)
        try await LegacySyncTransaction(store: store, workspace: workspace).accept(
            operationID: operationID, manifest: stage, mainMenuConfirmed: mainMenuConfirmed,
            device: device)
    }

    func inspectRecovery(operationID: UUID, device: any LegacySavedMenuRestoreDevice) async throws -> LegacySyncInspection {
        let record = try await store.load(operationID)
        guard record.resolvedScope == .savedMenu, let binding = record.savedMenuBinding,
              LegacyDeviceIdentity.matches(try await device.chipID(),
                                           fingerprint: binding.chipIDFingerprint) else {
            throw LegacySyncJournalError.invalidRecord
        }
        return try await LegacySyncTransaction(store: store, workspace: workspace)
            .inspectRecovery(operationID: operationID, device: device)
    }

    func reconcileUploaded(operationID: UUID,
                           device: any LegacySavedMenuRestoreDevice) async throws {
        let record = try await store.load(operationID)
        guard record.resolvedScope == .savedMenu, let binding = record.savedMenuBinding,
              LegacyDeviceIdentity.matches(try await device.chipID(),
                                           fingerprint: binding.chipIDFingerprint) else {
            throw LegacySyncJournalError.invalidRecord
        }
        let stage = try stageManifest(for: record)
        try await LegacySyncTransaction(store: store, workspace: workspace)
            .reconcileUploaded(operationID: operationID, manifest: stage, device: device)
    }

    func discardInactive(operationID: UUID, device: any LegacySavedMenuRestoreDevice) async throws {
        _ = try await inspectRecovery(operationID: operationID, device: device)
        try await LegacySyncTransaction(store: store, workspace: workspace)
            .discardInactive(operationID: operationID, device: device)
    }

    func rollback(operationID: UUID, device: any LegacySavedMenuRestoreDevice) async throws {
        _ = try await inspectRecovery(operationID: operationID, device: device)
        try await LegacySyncTransaction(store: store, workspace: workspace)
            .rollback(operationID: operationID, device: device)
    }

    func resumeAcceptance(operationID: UUID, mainMenuConfirmed: Bool,
                          device: any LegacySavedMenuRestoreDevice) async throws {
        _ = try await inspectRecovery(operationID: operationID, device: device)
        try await LegacySyncTransaction(store: store, workspace: workspace)
            .resumeAcceptance(operationID: operationID,
                              mainMenuConfirmed: mainMenuConfirmed, device: device)
    }

    func reconcileAccepted(operationID: UUID, mainMenuConfirmed: Bool,
                           device: any LegacySavedMenuRestoreDevice) async throws {
        _ = try await inspectRecovery(operationID: operationID, device: device)
        try await LegacySyncTransaction(store: store, workspace: workspace)
            .reconcileAccepted(operationID: operationID,
                               mainMenuConfirmed: mainMenuConfirmed, device: device)
    }

    private func currentMenu(report: LegacyConsoleReport,
                             device: any LegacySavedMenuRestoreDevice) async throws -> LegacySyncJournal {
        let chipID = try await device.chipID()
        guard let previous = try await store.latestAcceptedMenu(matchingChipID: chipID),
              previous.selectedCodes.map(Set.init) == report.visibleCodes,
              previous.stageDirectory.deletingLastPathComponent().standardizedFileURL
                == workspace.root.appendingPathComponent("Stages"),
              workspace.containsBackup(previous.backupDirectory) else {
            throw LegacySyncJournalError.invalidRecord
        }
        let state = try await device.inspectOperation(operationID: previous.operationID,
                                                      treeSHA256: previous.treeSHA256)
        let hasRollbackTree = state.outcome == .newTreePresent
        var reclaimedRollbackTree = false
        if !state.old, let cleanup = try? await LegacyOldMenuReclaimJournalStore(
            directory: workspace.journals).load(previous.operationID) {
            let chipID = try await device.chipID()
            reclaimedRollbackTree = cleanup.phase == .completed
                && cleanup.currentTreeSHA256 == previous.treeSHA256
                && LegacyDeviceIdentity.matches(chipID,
                                                fingerprint: cleanup.chipIDFingerprint)
        }
        if !state.old, !reclaimedRollbackTree,
           let proof = try LegacyHistoricalCleanup.formerMenuProof(operationID: previous.operationID, workspace: workspace) {
            let chipID = try await device.chipID()
            reclaimedRollbackTree = LegacyDeviceIdentity.matches(chipID, fingerprint: proof.chipIDFingerprint)
        }
        guard state.phase == .accepted, state.transaction,
              state.live, !state.stage, !state.lock, !state.failed,
              hasRollbackTree || reclaimedRollbackTree else {
            throw LegacySyncJournalError.invalidTransition
        }
        let manifest = try stageManifest(for: previous)
        let live = try await device.inventoryLive(operationID: previous.operationID)
        guard try LegacyStageVerification.compareInventory(live,
            operationID: previous.operationID, expected: manifest.entries,
            allowGeneratedPageFonts: true).isEmpty else {
            throw LegacyInspectionError.invalidResponse
        }
        return previous
    }

    private func stageManifest(for record: LegacySyncJournal) throws -> LegacyMenuStageManifest {
        let file = record.stageDirectory.appendingPathComponent("manifest.json")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 1024 * 1024 else {
            throw LegacySyncJournalError.invalidRecord
        }
        let stage = try JSONDecoder().decode(LegacyMenuStageManifest.self,
                                             from: Data(contentsOf: file))
        let source = try LegacySyncPlan.SourceFile.capture(stage.archiveURL)
        guard stage.menuDirectory.deletingLastPathComponent().standardizedFileURL == record.stageDirectory,
              stage.menuDirectory.standardizedFileURL == record.stageDirectory.appendingPathComponent("menu"),
              stage.archiveURL.standardizedFileURL == record.stageDirectory.appendingPathComponent("menu.tar"),
              stage.reviewSHA256 == record.reviewSHA256,
              stage.treeSHA256 == record.treeSHA256,
              stage.archiveSHA256 == record.archiveSHA256,
              stage.archiveBytes == record.archiveBytes,
              source.sha256 == record.archiveSHA256,
              source.byteCount == record.archiveBytes,
              LegacyMenuSnapshot.treeDigest(stage.entries) == record.treeSHA256 else {
            throw LegacySyncJournalError.invalidRecord
        }
        return stage
    }

    private func requireSavedCurrentMenu(report: LegacyConsoleReport,
                                         device: any LegacySavedMenuRestoreDevice) async throws {
        guard try await LegacyCurrentBackup.find(report: report, device: device,
                                                 workspace: workspace) != nil else {
            throw LegacyChangeError.refused("Back up the current NES menu first. A verified Mac copy of the menu you would replace is required before restoring an older snapshot.")
        }
    }
}

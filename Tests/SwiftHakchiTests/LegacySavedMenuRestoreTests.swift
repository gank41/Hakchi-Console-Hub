import Foundation
import SWCompression
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

private enum SavedMenuDeviceFailure: Error { case timedOut }

private actor SavedMenuDevice: LegacyOldMenuReclaimDevice {
    var report: LegacyConsoleReport
    var identity: String
    var identityReads = 0
    var changeIdentityAtRead: Int?
    let priorID: UUID
    let currentEntries: [LegacyMenuStageManifest.Entry]
    var newID: UUID?
    var activated = false
    var accepted = false
    var timeoutAfterActivate = false
    var changedInventory = false
    var changedOldInventory = false
    var formerEntries: [LegacyMenuStageManifest.Entry]?
    var formerPresent = true
    var removalTimesOut = false
    var writeCount = 0
    var allowLegacy = true
    var priorStateOverride: LegacySyncInspection?

    init(report: LegacyConsoleReport, identity: String, priorID: UUID,
         currentEntries: [LegacyMenuStageManifest.Entry]) {
        self.report = report; self.identity = identity; self.priorID = priorID
        self.currentEntries = currentEntries
    }
    func setFreeBytes(_ value: Int64) {
        report = LegacyConsoleReport(bootVersion: report.bootVersion,
            kernelVersion: report.kernelVersion, scriptVersion: report.scriptVersion,
            activePage: report.activePage, freeBytes: value, savesPath: report.savesPath,
            stockCodes: report.stockCodes, visibleCodes: report.visibleCodes)
    }
    func setTimeoutAfterActivate() { timeoutAfterActivate = true }
    func simulateAccepted() { accepted = true }
    func writes() -> Int { writeCount }
    func setChangedInventory() { changedInventory = true }
    func setChangedOldInventory() { changedOldInventory = true }
    func setPriorState(_ state: LegacySyncInspection) { priorStateOverride = state }
    func setFormerEntries(_ entries: [LegacyMenuStageManifest.Entry]) { formerEntries = entries }
    func setRemovalTimeout() { removalTimesOut = true }
    func inspect() async throws -> LegacyConsoleReport { report }
    func requireIdentity() async throws {}
    func refuseLegacy() { allowLegacy = false }
    func requireLegacyIdentity() async throws {
        if !allowLegacy { throw LegacyInspectionError.invalidBackup }
    }
    func changeIdentityAfterNextRead() { changeIdentityAtRead = identityReads + 2 }
    func chipID() async throws -> String {
        identityReads += 1
        if identityReads == changeIdentityAtRead { identity = String(repeating: "f", count: 32) }
        return identity
    }
    func inventoryLive(operationID: UUID) async throws -> Data {
        let rows = currentEntries.map { entry in
            [entry.relativePath, entry.kind.rawValue, String(entry.byteCount),
             entry.sha256 ?? "", entry.linkTarget ?? ""].joined(separator: "\t")
        }
        let body = changedInventory ? rows.dropLast().joined(separator: "\n") : rows.joined(separator: "\n")
        return Data("STAGE_INVENTORY:\(operationID.uuidString)\n\(body)\nEND_STAGE_INVENTORY\n".utf8)
    }
    func inventoryOld(operationID: UUID) async throws -> Data {
        guard formerPresent else { throw SavedMenuDeviceFailure.timedOut }
        let rows = (formerEntries ?? currentEntries).map { entry in
            [entry.relativePath, entry.kind.rawValue, String(entry.byteCount),
             entry.sha256 ?? "", entry.linkTarget ?? ""].joined(separator: "\t")
        }
        let body = changedOldInventory ? rows.dropLast().joined(separator: "\n")
                                       : rows.joined(separator: "\n")
        return Data("STAGE_INVENTORY:\(operationID.uuidString)\n\(body)\nEND_STAGE_INVENTORY\n".utf8)
    }
    func upload(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws { writeCount += 1; newID = operationID }
    func verify(_ manifest: LegacyMenuStageManifest, operationID: UUID,
                stageBudgetBytes: Int64) async throws { writeCount += 1 }
    func inventoryStage(operationID: UUID) async throws -> Data { Data() }
    func activate(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws {
        writeCount += 1
        activated = true
        if timeoutAfterActivate { throw SavedMenuDeviceFailure.timedOut }
    }
    func accept(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws { writeCount += 1; accepted = true }
    func inspectOperation(operationID: UUID, treeSHA256: String) async throws -> LegacySyncInspection {
        if operationID == priorID {
            if let priorStateOverride { return priorStateOverride }
            return LegacySyncInspection(phase: .accepted, live: true, old: formerPresent,
                stage: false, lock: false, archive: true)
        }
        return LegacySyncInspection(phase: accepted ? .accepted : activated ? .menuStarted : .missing,
            live: true, old: activated, stage: !activated,
            lock: activated && !accepted, archive: true)
    }
    func discard(operationID: UUID, treeSHA256: String) async throws { writeCount += 1 }
    func rollback(operationID: UUID, treeSHA256: String) async throws { writeCount += 1 }
    func removeOldMenu(operationID: UUID, liveTreeSHA256: String,
                       oldTreeSHA256: String) async throws {
        formerPresent = false
        if removalTimesOut { throw SavedMenuDeviceFailure.timedOut }
    }
    func inspectOldMenu(operationID: UUID, liveTreeSHA256: String,
                        oldTreeSHA256: String) async throws -> Int64 {
        guard formerPresent else { throw SavedMenuDeviceFailure.timedOut }
        return 42 * 1024 * 1024
    }
}

struct LegacySavedMenuRestoreTests {
    @Test func acceptedUnboundHistoryRequiresConfirmedFullProofAndDoesNotCreateIndex() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("accepted-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try await fixture(bindRecord: false, root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = context.backup.appendingPathComponent(LegacyMenuSnapshot.filename)
        try FileManager.default.removeItem(at: index)
        let binder = LegacyOldMenuBinding(workspace: context.workspace)
        let review = try await binder.preview(operationID: context.previous.operationID, device: context.device)
        await #expect(throws: (any Error).self) { _ = try await binder.bind(preview: review, device: context.device) }
        await #expect(throws: (any Error).self) {
            try await binder.bindReviewedAcceptedIdentity(preview: review, originalConsoleConfirmed: false,
                                                           device: context.device, isSessionCurrent: { true })
        }
        await #expect(throws: (any Error).self) {
            try await binder.bindReviewedAcceptedIdentity(preview: review, originalConsoleConfirmed: true,
                                                           device: context.device, isSessionCurrent: { false })
        }
        let store = LegacySyncJournalStore(directory: context.workspace.journals)
        #expect(try await store.load(context.previous.operationID).effectiveChipIDFingerprint == nil)
        #expect(!FileManager.default.fileExists(atPath: index.path))
        try await binder.bindReviewedAcceptedIdentity(preview: review, originalConsoleConfirmed: true,
                                                       device: context.device, isSessionCurrent: { true })
        #expect(try await store.load(context.previous.operationID).effectiveChipIDFingerprint == BackupManifest.digest(Data(chipID.utf8)))
        #expect(!FileManager.default.fileExists(atPath: index.path))
        #expect(await context.device.writes() == 0)
        await #expect(throws: (any Error).self) {
            try await binder.bindReviewedAcceptedIdentity(preview: review, originalConsoleConfirmed: true,
                                                           device: context.device, isSessionCurrent: { true })
        }
    }

    @Test func acceptedUnboundHistoryRefusesChangedFormerMenu() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("accepted-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try await fixture(bindRecord: false, root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let binder = LegacyOldMenuBinding(workspace: context.workspace)
        let review = try await binder.preview(operationID: context.previous.operationID, device: context.device)
        await context.device.setChangedOldInventory()
        await #expect(throws: (any Error).self) {
            try await binder.bindReviewedAcceptedIdentity(preview: review, originalConsoleConfirmed: true,
                                                           device: context.device, isSessionCurrent: { true })
        }
        #expect(try await LegacySyncJournalStore(directory: context.workspace.journals)
            .load(context.previous.operationID).effectiveChipIDFingerprint == nil)
        #expect(await context.device.writes() == 0)
    }

    @Test(arguments: ["live", "record", "marker", "identity", "stageArchive"])
    func acceptedUnboundHistoryRejectsChangedEvidence(_ change: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("accepted-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try await fixture(bindRecord: false, root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = context.backup.appendingPathComponent(LegacyMenuSnapshot.filename)
        try FileManager.default.removeItem(at: index)
        let binder = LegacyOldMenuBinding(workspace: context.workspace)
        let review = try await binder.preview(operationID: context.previous.operationID, device: context.device)
        switch change {
        case "live": await context.device.setChangedInventory()
        case "marker":
            await context.device.setPriorState(.init(phase: .accepted, transaction: false, live: true,
                                                      old: true, stage: false, lock: false))
        case "identity": await context.device.changeIdentityAfterNextRead()
        case "stageArchive": try Data("changed".utf8).write(to: context.stage.archiveURL)
        case "record":
            var changed = context.previous
            changed.chipIDFingerprint = String(repeating: "f", count: 64)
            let path = context.workspace.journals.appendingPathComponent("nes-sync-" + changed.operationID.uuidString + ".json")
            try JSONEncoder().encode(changed).write(to: path, options: .atomic)
        default: throw LegacyInspectionError.invalidResponse
        }
        await #expect(throws: (any Error).self) {
            try await binder.bindReviewedAcceptedIdentity(preview: review, originalConsoleConfirmed: true,
                                                           device: context.device, isSessionCurrent: { true })
        }
        let saved = try await LegacySyncJournalStore(directory: context.workspace.journals).load(context.previous.operationID)
        #expect(saved.effectiveChipIDFingerprint == (change == "record" ? String(repeating: "f", count: 64) : nil))
        #expect(!FileManager.default.fileExists(atPath: index.path))
        #expect(await context.device.writes() == 0)
    }

    @Test(arguments: [true, false])
    func acceptedUnboundTrialRequiresTrialGameInTheVerifiedLiveTree(_ matching: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("accepted-trial-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try await fixture(bindRecord: false, root: root,
                                        trialCode: matching ? "CLV-H-AAAAA" : "CLV-H-BBBBB")
        defer { try? FileManager.default.removeItem(at: root) }
        let binder = LegacyOldMenuBinding(workspace: context.workspace)
        if matching {
            let review = try await binder.preview(operationID: context.previous.operationID, device: context.device)
            try await binder.bindReviewedAcceptedIdentity(preview: review, originalConsoleConfirmed: true,
                                                           device: context.device, isSessionCurrent: { true })
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await binder.preview(operationID: context.previous.operationID, device: context.device)
            }
        }
        let saved = try await LegacySyncJournalStore(directory: context.workspace.journals).load(context.previous.operationID)
        #expect((saved.effectiveChipIDFingerprint != nil) == matching)
        #expect(await context.device.writes() == 0)
    }
    private let chipID = "0123456789abcdef0123456789abcdef"

    @Test func oldSavedMenuRecordUsesItsExistingDeviceBinding() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let snapshot = try LegacyMenuSnapshot.verify(directory: context.backup, expectedChipID: chipID)
        let journal = try LegacySyncJournal(operationID: UUID(), snapshot: snapshot,
            backupDirectory: context.backup, stage: context.stage, previous: context.previous)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        fields.removeValue(forKey: "chipIDFingerprint")
        let old = try JSONDecoder().decode(LegacySyncJournal.self, from: JSONSerialization.data(withJSONObject: fields))
        try old.validate()
        #expect(old.effectiveChipIDFingerprint == snapshot.manifest.chipIDFingerprint)
        fields["chipIDFingerprint"] = String(repeating: "f", count: 64)
        let conflicting = try JSONDecoder().decode(LegacySyncJournal.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(throws: (any Error).self) { try conflicting.validate() }
    }

    @Test func oldSavedMenuRecoveryUsesBindingWithoutFirstConsolePin() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let service = LegacySavedMenuRestore(workspace: context.workspace)
        let preview = try await service.prepare(snapshotDirectory: context.backup, device: context.device)
        try await service.transfer(preview, device: context.device)
        let path = context.workspace.journals.appendingPathComponent("nes-sync-" + preview.operationID.uuidString + ".json")
        var fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        fields.removeValue(forKey: "chipIDFingerprint")
        try JSONSerialization.data(withJSONObject: fields).write(to: path, options: .atomic)
        await context.device.refuseLegacy()
        _ = try await service.inspectRecovery(operationID: preview.operationID, device: context.device)
    }

    @Test func restoreUsesConnectedConsoleHistoryWhenAnotherConsoleWasSyncedLater() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let previous = context.previous
        let other = try LegacySyncJournal(operationID: UUID(), reviewSHA256: previous.reviewSHA256,
            archiveSHA256: previous.archiveSHA256, treeSHA256: previous.treeSHA256,
            backupSHA256: previous.backupSHA256, backupDirectory: previous.backupDirectory,
            stageDirectory: previous.stageDirectory, scope: .full,
            selectedCodes: try #require(previous.selectedCodes), consoleOrder: .title,
            maximumGamesPerPage: previous.maximumGamesPerPage, archiveBytes: previous.archiveBytes,
            chipIDFingerprint: BackupManifest.digest(Data(String(repeating: "f", count: 32).utf8)))
        let store = LegacySyncJournalStore(directory: context.workspace.journals)
        try await store.begin(other)
        try await store.advance(other.operationID, from: .prepared, to: .uploaded)
        try await store.advance(other.operationID, from: .uploaded, to: .verified)
        try await store.advance(other.operationID, from: .verified, to: .activationIntent)
        try await store.advance(other.operationID, from: .activationIntent, to: .activePendingAcceptance)
        try await store.advance(other.operationID, from: .activePendingAcceptance, to: .accepted)
        let preview = try await LegacySavedMenuRestore(workspace: context.workspace)
            .prepare(snapshotDirectory: context.backup, device: context.device)
        #expect(preview.previousOperationID == previous.operationID)
    }

    @Test func oldMenuBindingHonorsConsoleRecordedForTheOperation() async throws {
        let context = try await fixture(recordChipID: String(repeating: "f", count: 32))
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let index = context.backup.appendingPathComponent(LegacyMenuSnapshot.filename)
        try FileManager.default.removeItem(at: index)
        let binder = LegacyOldMenuBinding(workspace: context.workspace)
        await #expect(throws: (any Error).self) {
            _ = try await binder.preview(operationID: context.previous.operationID, device: context.device)
        }
        #expect(!FileManager.default.fileExists(atPath: index.path))
    }

    @Test func oldMenuBindingRejectsConsoleChangeAfterInspection() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let index = context.backup.appendingPathComponent(LegacyMenuSnapshot.filename)
        try FileManager.default.removeItem(at: index)
        let binder = LegacyOldMenuBinding(workspace: context.workspace)
        let preview = try await binder.preview(operationID: context.previous.operationID,
                                               device: context.device)
        await context.device.changeIdentityAfterNextRead()
        await #expect(throws: (any Error).self) {
            _ = try await binder.bind(preview: preview, device: context.device)
        }
        #expect(!FileManager.default.fileExists(atPath: index.path))
    }

    @Test func choosesEitherVerifiedSnapshotAndRejectsWrongConsole() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let second = try makeBackup(in: context.workspace.backups, custom: "CLV-H-BBBBB")
        let service = LegacySavedMenuRestore(workspace: context.workspace)
        let firstPreview = try await service.prepare(snapshotDirectory: context.backup,
                                                     device: context.device)
        let secondPreview = try await service.prepare(snapshotDirectory: second,
                                                      device: context.device)
        #expect(firstPreview.selectedCodes.contains("CLV-H-AAAAA"))
        #expect(secondPreview.selectedCodes.contains("CLV-H-BBBBB"))
        let other = SavedMenuDevice(report: context.report,
            identity: "fedcba9876543210fedcba9876543210",
            priorID: context.previous.operationID, currentEntries: context.stage.entries)
        await #expect(throws: (any Error).self) {
            try await service.prepare(snapshotDirectory: context.backup, device: other)
        }
    }

    @Test func currentBackupSelectionRequiresSameConsoleAndExactLiveMenu() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let matched = try await LegacyCurrentBackup.find(report: context.report,
            device: context.device, workspace: context.workspace)
        #expect(matched?.directory.path == context.backup.path)
        #expect(matched?.treeSHA256 == context.stage.treeSHA256)

        let other = SavedMenuDevice(report: context.report,
            identity: "fedcba9876543210fedcba9876543210",
            priorID: context.previous.operationID, currentEntries: context.stage.entries)
        let wrongConsole = try await LegacyCurrentBackup.find(report: context.report,
            device: other, workspace: context.workspace)
        #expect(wrongConsole == nil)

        await context.device.setChangedInventory()
        let changedMenu = try await LegacyCurrentBackup.find(report: context.report,
            device: context.device, workspace: context.workspace)
        #expect(changedMenu == nil)
    }

    @Test func soleRestorableSnapshotShowsWarningAndJournalDependency() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let preview = try await LegacyBackupDeletion(workspace: context.workspace)
            .preview(directory: context.backup)
        #expect(preview.isLastRestorable)
        #expect(!preview.isEligible)
        #expect(preview.dependencies.contains { $0.contains(context.previous.operationID.uuidString) })
    }

    @Test func oldMenuCanOnlyBeBoundAfterExactDeviceAndTreeProof() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        try FileManager.default.removeItem(at:
            context.backup.appendingPathComponent(LegacyMenuSnapshot.filename))
        let binder = LegacyOldMenuBinding(workspace: context.workspace)
        let preview = try await binder.preview(operationID: context.previous.operationID,
                                               device: context.device)
        #expect(preview.backupDirectory.path == context.backup.path)
        await context.device.setChangedOldInventory()
        do {
            _ = try await binder.bind(preview: preview, device: context.device)
            Issue.record("A changed former-menu inventory must be rejected")
        } catch {
            #expect(error.localizedDescription.contains("former-menu inventory"))
        }
        #expect(!FileManager.default.fileExists(atPath:
            context.backup.appendingPathComponent(LegacyMenuSnapshot.filename).path))
    }

    @Test func matchingOldMenuCreatesDeviceBoundMacRestoreIndex() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        try FileManager.default.removeItem(at:
            context.backup.appendingPathComponent(LegacyMenuSnapshot.filename))
        let binder = LegacyOldMenuBinding(workspace: context.workspace)

        let preview = try await binder.preview(operationID: context.previous.operationID,
                                               device: context.device)
        let verified = try await binder.bind(preview: preview, device: context.device)

        #expect(verified.menuTreeSHA256 == preview.oldTreeSHA256)
        #expect(try LegacyMenuSnapshot.verify(directory: context.backup,
            expectedChipID: chipID).menuTreeSHA256 == preview.oldTreeSHA256)
    }

    @Test func changedActiveInventoryReportsComparisonStage() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        await context.device.setChangedInventory()
        do {
            _ = try await LegacyOldMenuBinding(workspace: context.workspace)
                .preview(operationID: context.previous.operationID, device: context.device)
            Issue.record("A changed active-menu inventory must be rejected")
        } catch {
            #expect(error.localizedDescription.contains("comparing active-menu inventory"))
            #expect(error.localizedDescription.contains("missing on NES"))
        }
    }

    @Test func currentAndRestorableSnapshotsRemainUsableAfterChangingBackupsFolder() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let selectedFolder = context.workspace.root.appendingPathComponent("New Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: false)
        let movedWorkspace = WorkspacePaths(root: context.workspace.root,
            activeBackups: selectedFolder, previousBackups: [context.workspace.backups])
        let service = LegacySavedMenuRestore(workspace: movedWorkspace)

        let preview = try await service.prepare(snapshotDirectory: context.backup,
                                                device: context.device)

        #expect(preview.snapshotDirectory == context.backup)
        #expect(preview.previousOperationID == context.previous.operationID)
    }

    @Test func restorePreviewAcceptsPostBootFontsWithExactCurrentSnapshot() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let current = try makeBackup(in: context.workspace.backups, custom: "CLV-H-AAAAA",
                                     includeGeneratedFonts: true)
        let target = try makeBackup(in: context.workspace.backups, custom: "CLV-H-BBBBB")
        try FileManager.default.removeItem(at:
            context.backup.appendingPathComponent(LegacyMenuSnapshot.filename))
        let currentSnapshot = try LegacyMenuSnapshot.verify(directory: current, expectedChipID: chipID)
        let device = SavedMenuDevice(report: context.report, identity: chipID,
            priorID: context.previous.operationID, currentEntries: currentSnapshot.entries)
        let preview = try await LegacySavedMenuRestore(workspace: context.workspace)
            .prepare(snapshotDirectory: target, device: device)
        #expect(preview.previousOperationID == context.previous.operationID)
    }

    @Test func insufficientSpaceOrChangedLiveMenuLeavesNoSyncJournal() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let service = LegacySavedMenuRestore(workspace: context.workspace)
        await context.device.setFreeBytes(1_000)
        await #expect(throws: (any Error).self) {
            try await service.prepare(snapshotDirectory: context.backup, device: context.device)
        }
        await context.device.setFreeBytes(170_000_000)
        await context.device.setChangedInventory()
        await #expect(throws: (any Error).self) {
            try await service.prepare(snapshotDirectory: context.backup, device: context.device)
        }
        #expect(try await LegacySyncJournalStore(directory: context.workspace.journals).latestUnresolved() == nil)
    }

    @Test func lostAcceptanceCanBeReconciledForSavedMenu() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let service = LegacySavedMenuRestore(workspace: context.workspace)
        let preview = try await service.prepare(snapshotDirectory: context.backup, device: context.device)
        try await service.transfer(preview, device: context.device)
        try await service.activate(operationID: preview.operationID, device: context.device)
        await context.device.simulateAccepted()
        let writesBefore = await context.device.writes()
        await #expect(throws: (any Error).self) {
            try await service.reconcileAccepted(operationID: preview.operationID, mainMenuConfirmed: false, device: context.device)
        }
        try await service.reconcileAccepted(operationID: preview.operationID, mainMenuConfirmed: true, device: context.device)
        #expect(try await LegacySyncJournalStore(directory: context.workspace.journals).load(preview.operationID).phase == .accepted)
        await #expect(throws: (any Error).self) {
            try await service.reconcileAccepted(operationID: preview.operationID, mainMenuConfirmed: true, device: context.device)
        }
        #expect(await context.device.writes() == writesBefore)
    }

    @Test func interruptedMenuSwitchRetainsARecoverableJournal() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let service = LegacySavedMenuRestore(workspace: context.workspace)
        let preview = try await service.prepare(snapshotDirectory: context.backup, device: context.device)
        try await service.transfer(preview, device: context.device)
        let store = LegacySyncJournalStore(directory: context.workspace.journals)
        #expect(try await store.load(preview.operationID).phase == .verified)
        await context.device.setTimeoutAfterActivate()
        await #expect(throws: (any Error).self) {
            try await service.activate(operationID: preview.operationID, device: context.device)
        }
        #expect(try await store.load(preview.operationID).phase == .uncertain)
        let state = try await service.inspectRecovery(operationID: preview.operationID,
                                                      device: context.device)
        #expect(state.outcome == .newTreePresent)
    }

    @Test func formerMenuPreviewRequiresAcceptedReturnAndExactMacSnapshot() async throws {
        let (workspace, alternateBackup, returned, device) = try await returnTrialFixture()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        await #expect(throws: (any Error).self) {
            try await LegacyOldMenuReclaim.preview(operationID: returned.operationID,
                workspace: workspace, confirmedTestedMenus: false, device: device)
        }

        let preview = try await LegacyOldMenuReclaim.preview(operationID: returned.operationID,
            workspace: workspace, confirmedTestedMenus: true, device: device)
        #expect(preview.previousGameCount == 31)
        #expect(preview.previousSnapshotDirectory.path == alternateBackup.path)
        #expect(preview.currentGameCount == 31)

        await device.setChangedOldInventory()
        await #expect(throws: (any Error).self) {
            try await LegacyOldMenuReclaim.preview(operationID: returned.operationID,
                workspace: workspace, confirmedTestedMenus: true, device: device)
        }
    }

    @Test func completedFormerMenuRemovalLeavesCurrentSnapshotAndRecoversLostReceipt() async throws {
        let (workspace, _, returned, device) = try await returnTrialFixture()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let archives = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        try await archives.begin(LegacyArchiveReclaimJournal(operationID: returned.operationID,
            archiveSHA256: returned.archiveSHA256, treeSHA256: returned.treeSHA256,
            archiveBytes: returned.archiveBytes, createdAt: Date(), phase: .prepared))
        try await archives.advance(returned.operationID, from: .prepared, to: .removalIntent)
        try await archives.advance(returned.operationID, from: .removalIntent, to: .completed)
        let transaction = LegacyOldMenuReclaimTransaction(workspace: workspace)
        let preview = try await transaction.prepare(operationID: returned.operationID,
            confirmedTestedMenus: true, device: device)
        await device.setRemovalTimeout()
        await #expect(throws: (any Error).self) {
            try await transaction.remove(preview: preview, device: device)
        }
        let journal = LegacyOldMenuReclaimJournalStore(directory: workspace.journals)
        #expect(try await journal.load(returned.operationID).phase == .uncertain)
        try await transaction.reconcile(operationID: returned.operationID, device: device)
        #expect(try await journal.load(returned.operationID).phase == .completed)
        #expect((try await device.inspect()).visibleCodes.count == 31)
    }

    @Test func futureRestoreRecognizesAcceptedMenuAfterItsFormerTreeWasReclaimed() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let alternate = try makeBackup(in: context.workspace.backups, custom: "CLV-H-BBBBB")
        try await context.device.removeOldMenu(operationID: context.previous.operationID,
            liveTreeSHA256: context.previous.treeSHA256,
            oldTreeSHA256: String(repeating: "b", count: 64))
        await #expect(throws: (any Error).self) {
            try await LegacySavedMenuRestore(workspace: context.workspace)
                .prepare(snapshotDirectory: alternate, device: context.device)
        }
        let journal = LegacyOldMenuReclaimJournal(operationID: context.previous.operationID,
            currentTreeSHA256: context.previous.treeSHA256,
            previousTreeSHA256: String(repeating: "b", count: 64),
            previousSnapshotSHA256: String(repeating: "c", count: 64),
            chipIDFingerprint: BackupManifest.digest(Data(chipID.utf8)),
            createdAt: Date(), phase: .prepared)
        let store = LegacyOldMenuReclaimJournalStore(directory: context.workspace.journals)
        try await store.begin(journal)
        try await store.advance(journal.operationID, from: .prepared, to: .removalIntent)
        try await store.advance(journal.operationID, from: .removalIntent, to: .completed)
        let preview = try await LegacySavedMenuRestore(workspace: context.workspace)
            .prepare(snapshotDirectory: alternate, device: context.device)
        #expect(preview.previousOperationID == context.previous.operationID)
    }

    private func returnTrialFixture() async throws -> (WorkspacePaths, URL, LegacySyncJournal, SavedMenuDevice) {
        let context = try await fixture()
        let alternateBackup = try makeBackup(in: context.workspace.backups, custom: "CLV-H-BBBBB")
        let alternateSnapshot = try LegacyMenuSnapshot.verify(directory: alternateBackup,
                                                               expectedChipID: chipID)
        let alternateStage = try LegacySavedMenuStage.build(snapshotDirectory: alternateBackup,
            expectedChipID: chipID, in: context.workspace.root.appendingPathComponent("Stages"))
        let store = LegacySyncJournalStore(directory: context.workspace.journals)
        let outgoing = try LegacySyncJournal(operationID: UUID(), snapshot: alternateSnapshot,
            backupDirectory: alternateBackup, stage: alternateStage, previous: context.previous)
        try await acceptTestRecord(outgoing, in: store)
        let currentSnapshot = try LegacyMenuSnapshot.verify(directory: context.backup,
                                                            expectedChipID: chipID)
        let returnStage = try LegacySavedMenuStage.build(snapshotDirectory: context.backup,
            expectedChipID: chipID, in: context.workspace.root.appendingPathComponent("Stages"))
        let returned = try LegacySyncJournal(operationID: UUID(), snapshot: currentSnapshot,
            backupDirectory: context.backup, stage: returnStage, previous: outgoing)
        try await acceptTestRecord(returned, in: store)
        let device = SavedMenuDevice(report: context.report, identity: chipID,
            priorID: returned.operationID, currentEntries: currentSnapshot.entries)
        await device.setFormerEntries(alternateSnapshot.entries)
        return (context.workspace, alternateBackup, returned, device)
    }

    @Test func historicalRemovalProofSurvivesNewPreviewAndOlderPreparedJournal() async throws {
        let context = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.workspace.root) }
        let oldPath = LegacySyncCommands.oldPath(for: context.previous.operationID)
        try await context.device.removeOldMenu(operationID: context.previous.operationID,
            liveTreeSHA256: context.previous.treeSHA256, oldTreeSHA256: String(repeating: "b", count: 64))
        let record = LegacyHistoricalCleanup.Record(id: UUID(), operationID: context.previous.operationID,
            backupDirectory: context.backup, backupSHA256: context.previous.backupSHA256,
            chipIDFingerprint: BackupManifest.digest(Data(chipID.utf8)), liveTreeSHA256: context.previous.treeSHA256,
            items: [.init(target: try .init(path: oldPath), treeSHA256: String(repeating: "b", count: 64), allocatedBytes: 4096)],
            removedPaths: [oldPath], phase: .completed)
        try LegacyHistoricalCleanup.preserveFormerMenuProof(record, workspace: context.workspace)
        var newer = record; newer.removedPaths = []; newer.phase = .prepared
        try LegacyHistoricalCleanup.persist(newer, workspace: context.workspace)
        let oldJournal = LegacyOldMenuReclaimJournal(operationID: context.previous.operationID,
            currentTreeSHA256: context.previous.treeSHA256, previousTreeSHA256: String(repeating: "b", count: 64),
            previousSnapshotSHA256: String(repeating: "c", count: 64),
            chipIDFingerprint: record.chipIDFingerprint, createdAt: Date(), phase: .prepared)
        try await LegacyOldMenuReclaimJournalStore(directory: context.workspace.journals).begin(oldJournal)
        let alternate = try makeBackup(in: context.workspace.backups, custom: "CLV-H-BBBBB")
        let preview = try await LegacySavedMenuRestore(workspace: context.workspace)
            .prepare(snapshotDirectory: alternate, device: context.device)
        #expect(preview.previousOperationID == context.previous.operationID)
    }

    private func acceptTestRecord(_ record: LegacySyncJournal,
                                  in store: LegacySyncJournalStore) async throws {
        try await store.begin(record)
        try await store.advance(record.operationID, from: .prepared, to: .uploaded)
        try await store.advance(record.operationID, from: .uploaded, to: .verified)
        try await store.advance(record.operationID, from: .verified, to: .activationIntent)
        try await store.advance(record.operationID, from: .activationIntent,
                                to: .activePendingAcceptance)
        try await store.advance(record.operationID, from: .activePendingAcceptance, to: .accepted)
    }

    private func fixture(recordChipID: String? = nil, bindRecord: Bool = true, root suppliedRoot: URL? = nil,
                         trialCode: String? = nil) async throws -> (workspace: WorkspacePaths, backup: URL,
        stage: LegacyMenuStageManifest, previous: LegacySyncJournal,
        report: LegacyConsoleReport, device: SavedMenuDevice) {
        let root = try suppliedRoot ?? testDirectory()
        let workspace = WorkspacePaths(root: root)
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let backup = try makeBackup(in: workspace.backups, custom: "CLV-H-AAAAA")
        let snapshot = try LegacyMenuSnapshot.verify(directory: backup, expectedChipID: chipID)
        let stage = try LegacySavedMenuStage.build(snapshotDirectory: backup,
            expectedChipID: chipID, in: root.appendingPathComponent("Stages"))
        let previous: LegacySyncJournal
        if let trialCode {
            previous = try LegacySyncJournal(operationID: UUID(),
                reviewSHA256: stage.reviewSHA256, archiveSHA256: stage.archiveSHA256,
                treeSHA256: stage.treeSHA256, backupSHA256: snapshot.manifest.archiveSHA256,
                backupDirectory: backup, stageDirectory: stage.menuDirectory.deletingLastPathComponent(),
                trialCode: trialCode, maximumGamesPerPage: 30, archiveBytes: stage.archiveBytes,
                chipIDFingerprint: bindRecord ? BackupManifest.digest(Data((recordChipID ?? chipID).utf8)) : nil)
        } else {
        previous = try LegacySyncJournal(operationID: UUID(),
            reviewSHA256: stage.reviewSHA256, archiveSHA256: stage.archiveSHA256,
            treeSHA256: stage.treeSHA256, backupSHA256: snapshot.manifest.archiveSHA256,
            backupDirectory: backup, stageDirectory: stage.menuDirectory.deletingLastPathComponent(),
            scope: .full, selectedCodes: LegacyMenuSnapshot.gameCodes(snapshot.entries).sorted(),
            consoleOrder: .title, maximumGamesPerPage: 30, archiveBytes: stage.archiveBytes,
            chipIDFingerprint: bindRecord ? BackupManifest.digest(Data((recordChipID ?? chipID).utf8)) : nil)
        }
        let store = LegacySyncJournalStore(directory: workspace.journals)
        try await store.begin(previous)
        try await store.advance(previous.operationID, from: .prepared, to: .uploaded)
        try await store.advance(previous.operationID, from: .uploaded, to: .verified)
        try await store.advance(previous.operationID, from: .verified, to: .activationIntent)
        try await store.advance(previous.operationID, from: .activationIntent,
                                to: .activePendingAcceptance)
        try await store.advance(previous.operationID, from: .activePendingAcceptance, to: .accepted)
        let report = snapshot.observedReport
        let device = SavedMenuDevice(report: report, identity: chipID,
            priorID: previous.operationID, currentEntries: stage.entries)
        return (workspace, backup, stage, previous, report, device)
    }

    private func makeBackup(in backups: URL, custom: String,
                            includeGeneratedFonts: Bool = false) throws -> URL {
        let directory = backups.appendingPathComponent("LegacyInspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("console.tar")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        var writer = SWCompression.TarWriter(fileHandle: handle, force: .ustar)
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        for code in (stock.union([custom])).sorted() {
            for name in ["var/lib/hakchi/games/nes/000", "var/lib/hakchi/games/nes/000/\(code)"] {
                if name.hasSuffix("/000") && code != stock.sorted().first { continue }
                var info = TarEntryInfo(name: name, type: .directory)
                info.permissions = Permissions(rawValue: 0o755)
                try writer.append(TarEntry(info: info, data: nil))
            }
            var info = TarEntryInfo(name: "var/lib/hakchi/games/nes/000/\(code)/\(code).desktop",
                                    type: .regular)
            info.permissions = Permissions(rawValue: 0o644)
            try writer.append(TarEntry(info: info,
                data: Data("[Desktop Entry]\nName=\(code)\n".utf8)))
        }
        if includeGeneratedFonts {
            for font in ["copyright.fnt", "title.fnt"] {
                var info = TarEntryInfo(name: "var/lib/hakchi/games/nes/000/" + font,
                                        type: .regular)
                info.permissions = Permissions(rawValue: 0o644)
                try writer.append(TarEntry(info: info, data: Data("font".utf8)))
            }
        }
        try writer.finalize(); try handle.close()
        let bytes = try Data(contentsOf: archive)
        let report = LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
            scriptVersion: "[master]v1.0.3-110(7f31082)",
            activePage: LegacyConsoleReport.gameRoot + "/000", freeBytes: 170_000_000,
            savesPath: "/var/lib/clover/profiles/0", stockCodes: stock,
            visibleCodes: stock.union([custom]))
        let object: [String: Any] = ["formatVersion": 1, "createdAt": "2026-10-19T12:00:00Z",
            "byteCount": bytes.count, "sha256": BackupManifest.digest(bytes),
            "scope": "Console inspection", "eligibleForAutomaticRestore": false,
            "deviceIdentityVerified": false, "archiveFilename": "console.tar",
            "observedReport": try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))]
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("manifest.json"))
        _ = try LegacyMenuSnapshot.record(directory: directory, chipID: chipID)
        return directory
    }
}

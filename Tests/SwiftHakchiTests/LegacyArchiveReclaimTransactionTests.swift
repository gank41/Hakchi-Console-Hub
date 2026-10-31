import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

private enum ReclaimTestFailure: Error { case disconnected }

private actor ReclaimMutableDevice: LegacyArchiveReclaimDevice {
    let report: LegacyConsoleReport
    var archivePresent = true
    var timeoutAfterDelete = false
    var timeoutBeforeDelete = false

    init() {
        report = LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
            scriptVersion: "[master]v1.0.3-110(7f31082)",
            activePage: "/var/lib/hakchi/games/nes/000", freeBytes: 170_000_000,
            savesPath: "/var/lib/clover/profiles/0",
            stockCodes: Set((0..<30).map { String(format: "CLV-P-%05d", $0) }),
            visibleCodes: ["CLV-H-ABCDE"])
    }
    func setTimeoutAfterDelete() { timeoutAfterDelete = true }
    func setTimeoutBeforeDelete() { timeoutBeforeDelete = true }
    func setArchivePresent(_ present: Bool) { archivePresent = present }
    func inspect() async throws -> LegacyConsoleReport { report }
    func requireIdentity() async throws {}
    func inventoryLive(operationID: UUID) async throws -> Data { Data() }
    func inspectOperation(operationID: UUID, treeSHA256: String) async throws -> LegacySyncInspection {
        LegacySyncInspection(phase: .accepted, live: true, old: true,
                             stage: false, lock: false, archive: archivePresent)
    }
    func inspectArchive(operationID: UUID, treeSHA256: String,
                        archiveSHA256: String, archiveBytes: Int64) async throws -> LegacyArchiveReclaimCommands.Inspection {
        .init(archivePresent: archivePresent, archiveBytes: archivePresent ? archiveBytes : 0)
    }
    func removeArchive(operationID: UUID, treeSHA256: String,
                       archiveSHA256: String, archiveBytes: Int64) async throws {
        if timeoutBeforeDelete { throw ReclaimTestFailure.disconnected }
        archivePresent = false
        if timeoutAfterDelete { throw ReclaimTestFailure.disconnected }
    }
}

struct LegacyArchiveReclaimTransactionTests {
    @Test func journalRefusesSymlinkedDirectory() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        let store = LegacyArchiveReclaimJournalStore(directory: linked)
        let record = LegacyArchiveReclaimJournal(operationID: UUID(),
            archiveSHA256: String(repeating: "a", count: 64),
            treeSHA256: String(repeating: "b", count: 64),
            archiveBytes: 1024, createdAt: Date(), phase: .prepared)
        await #expect(throws: (any Error).self) { try await store.begin(record) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
    }

    @Test func crashAfterDurableIntentCanBeReconciledWithoutRetryingDeletion() async throws {
        let (workspace, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try await persistAccepted(record, in: workspace)
        let device = ReclaimMutableDevice()
        let transaction = LegacyArchiveReclaimTransaction(workspace: workspace)
        _ = try await transaction.prepare(operationID: record.operationID, device: device)
        let store = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        try await store.advance(record.operationID, from: .prepared, to: .removalIntent)

        try await transaction.reconcile(operationID: record.operationID, device: device)
        #expect(try await store.load(record.operationID).phase == .prepared)
    }

    @Test func crashAfterDeletionCanBeReconciledWithoutRetryingDeletion() async throws {
        let (workspace, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try await persistAccepted(record, in: workspace)
        let device = ReclaimMutableDevice()
        let transaction = LegacyArchiveReclaimTransaction(workspace: workspace)
        _ = try await transaction.prepare(operationID: record.operationID, device: device)
        let store = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        try await store.advance(record.operationID, from: .prepared, to: .removalIntent)
        await device.setArchivePresent(false)

        try await transaction.reconcile(operationID: record.operationID, device: device)
        #expect(try await store.load(record.operationID).phase == .completed)
    }

    @Test func unusedPreviewCanBeReplacedByNewerAcceptedSync() async throws {
        let (workspace, firstRecord) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try await persistAccepted(firstRecord, in: workspace)
        let device = ReclaimMutableDevice()
        let transaction = LegacyArchiveReclaimTransaction(workspace: workspace)
        _ = try await transaction.prepare(operationID: firstRecord.operationID, device: device)
        let secondRecord = try LegacySyncJournal(operationID: UUID(),
            reviewSHA256: firstRecord.reviewSHA256, archiveSHA256: firstRecord.archiveSHA256,
            treeSHA256: firstRecord.treeSHA256, backupSHA256: firstRecord.backupSHA256,
            backupDirectory: firstRecord.backupDirectory, stageDirectory: firstRecord.stageDirectory,
            trialCode: "CLV-H-ABCDE", maximumGamesPerPage: 30, archiveBytes: firstRecord.archiveBytes)
        try await persistAccepted(secondRecord, in: workspace)

        let newer = try await transaction.prepare(operationID: secondRecord.operationID, device: device)
        let store = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        #expect(newer.operationID == secondRecord.operationID)
        #expect(try await store.load(firstRecord.operationID).phase == .abandoned)
        #expect(try await store.load(secondRecord.operationID).phase == .prepared)
    }

    @Test func preparedPreviewCanBeReopenedAfterClosingSheet() async throws {
        let (workspace, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try await persistAccepted(record, in: workspace)
        let device = ReclaimMutableDevice()
        let first = LegacyArchiveReclaimTransaction(workspace: workspace)
        _ = try await first.prepare(operationID: record.operationID, device: device)

        let reopened = LegacyArchiveReclaimTransaction(workspace: workspace)
        let preview = try await reopened.prepare(operationID: record.operationID, device: device)
        #expect(preview.operationID == record.operationID)
    }

    @Test func timeoutBeforeRemovalRequiresReadOnlyCheckBeforeNewButtonPress() async throws {
        let (workspace, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        try await persistAccepted(record, in: workspace)
        let device = ReclaimMutableDevice()
        let transaction = LegacyArchiveReclaimTransaction(workspace: workspace)
        let preview = try await transaction.prepare(operationID: record.operationID, device: device)
        await device.setTimeoutBeforeDelete()

        await #expect(throws: (any Error).self) { try await transaction.remove(preview: preview, device: device) }
        let store = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        #expect(try await store.load(record.operationID).phase == .uncertain)
        try await transaction.reconcile(operationID: record.operationID, device: device)
        #expect(try await store.load(record.operationID).phase == .prepared)
    }

    @Test func timeoutAfterRemovalStaysUncertainUntilReadOnlyReconciliation() async throws {
        let (workspace, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let device = ReclaimMutableDevice()
        let transaction = LegacyArchiveReclaimTransaction(workspace: workspace)
        try await persistAccepted(record, in: workspace)
        let preview = try await transaction.prepare(operationID: record.operationID, device: device)
        await device.setTimeoutAfterDelete()

        await #expect(throws: (any Error).self) { try await transaction.remove(preview: preview, device: device) }
        let store = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        #expect(try await store.load(record.operationID).phase == .uncertain)
        try await transaction.reconcile(operationID: record.operationID, device: device)
        #expect(try await store.load(record.operationID).phase == .completed)
    }

    private func persistAccepted(_ record: LegacySyncJournal, in workspace: WorkspacePaths) async throws {
        let syncStore = LegacySyncJournalStore(directory: workspace.journals)
        var prepared = record; prepared.phase = .prepared
        try await syncStore.begin(prepared)
        try await syncStore.advance(record.operationID, from: .prepared, to: .uploaded)
        try await syncStore.advance(record.operationID, from: .uploaded, to: .verified)
        try await syncStore.advance(record.operationID, from: .verified, to: .activationIntent)
        try await syncStore.advance(record.operationID, from: .activationIntent, to: .activePendingAcceptance)
        try await syncStore.advance(record.operationID, from: .activePendingAcceptance, to: .accepted)
    }

    private func fixture() throws -> (WorkspacePaths, LegacySyncJournal) {
        let root = try testDirectory()
        let workspace = WorkspacePaths(root: root)
        let stage = root.appendingPathComponent("Stages/LegacyMenuStage-" + UUID().uuidString)
        let backup = workspace.backups.appendingPathComponent("LegacyInspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0, count: 1024)
        let digest = BackupManifest.digest(bytes)
        try bytes.write(to: stage.appendingPathComponent("menu.tar"))
        try bytes.write(to: backup.appendingPathComponent("console.tar"))
        try JSONSerialization.data(withJSONObject: ["sha256": digest, "byteCount": 1024])
            .write(to: backup.appendingPathComponent("manifest.json"))
        var record = try LegacySyncJournal(operationID: UUID(), reviewSHA256: digest,
            archiveSHA256: digest, treeSHA256: digest, backupSHA256: digest,
            backupDirectory: backup, stageDirectory: stage, trialCode: "CLV-H-ABCDE",
            maximumGamesPerPage: 30, archiveBytes: 1024)
        record.phase = .accepted
        return (workspace, record)
    }
}

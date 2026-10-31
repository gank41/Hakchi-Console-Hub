import Foundation
import SWCompression
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

private actor FakeLegacySyncDevice: LegacySavedMenuRestoreDevice {
    enum Fault: Sendable { case none, upload, verify, activate, accept, inspectOperation }
    var report: LegacyConsoleReport
    var fault: Fault = .none
    var calls: [String] = []
    var accepted = false
    var forcedInspection: LegacySyncInspection?
    var inventoryData: Data?
    var identity = "0123456789abcdef0123456789abcdef"
    var liveMismatch = false
    let currentEntries: [LegacyMenuStageManifest.Entry]
    init(report: LegacyConsoleReport, backup: URL) throws {
        self.report = report
        currentEntries = try LegacyMenuSnapshot.verify(directory: backup).entries
    }
    func setFault(_ fault: Fault) { self.fault = fault }
    func setReport(_ report: LegacyConsoleReport) { self.report = report }
    func setInspection(_ observation: LegacySyncInspection) { forcedInspection = observation }
    func setInventory(_ data: Data) { inventoryData = data }
    func setIdentity(_ value: String) { identity = value }
    func setLiveMismatch() { liveMismatch = true }
    func snapshot() -> [String] { calls }
    func inspect() throws -> LegacyConsoleReport { calls.append("inspect"); return report }
    func requireIdentity() throws { calls.append("identity") }
    func chipID() throws -> String {
        calls.append("chipID")
        return identity
    }
    func inventoryLive(operationID: UUID) throws -> Data {
        calls.append("inventoryLive")
        let rows = currentEntries.map { entry in
            [entry.relativePath, entry.kind.rawValue, String(entry.byteCount),
             entry.sha256 ?? "", entry.linkTarget ?? ""].joined(separator: "\t")
        }
        let body = liveMismatch ? rows.dropLast().joined(separator: "\n") : rows.joined(separator: "\n")
        return Data("STAGE_INVENTORY:\(operationID.uuidString)\n\(body)\nEND_STAGE_INVENTORY\n".utf8)
    }
    func upload(_ manifest: LegacyMenuStageManifest, operationID: UUID) throws {
        calls.append("upload")
        if fault == .upload { throw LegacyInspectionError.disconnected }
    }
    func verify(_ manifest: LegacyMenuStageManifest, operationID: UUID, stageBudgetBytes: Int64) throws {
        calls.append("verify")
        if fault == .verify { throw LegacyInspectionError.invalidResponse }
    }
    func activate(_ manifest: LegacyMenuStageManifest, operationID: UUID) throws {
        calls.append("activate")
        if fault == .activate { throw LegacyInspectionError.disconnected }
    }
    func inspectOperation(operationID: UUID, treeSHA256: String) throws -> LegacySyncInspection {
        calls.append("inspectOperation")
        if fault == .inspectOperation { throw LegacyInspectionError.disconnected }
        if let forcedInspection { return forcedInspection }
        return LegacySyncInspection(phase: accepted ? .accepted : .menuStarted,
                                    live: true, old: true, stage: false, lock: !accepted)
    }
    func inventoryStage(operationID: UUID) throws -> Data {
        calls.append("inventoryStage")
        return inventoryData ?? Data()
    }
    func accept(_ manifest: LegacyMenuStageManifest, operationID: UUID) throws {
        calls.append("accept")
        if fault == .accept { throw LegacyInspectionError.disconnected }
        accepted = true
    }
    func discard(operationID: UUID, treeSHA256: String) {
        calls.append("discard")
        forcedInspection = LegacySyncInspection(phase: .missing, transaction: false,
                                                live: true, old: false, stage: false, lock: false)
    }
    func rollback(operationID: UUID, treeSHA256: String) {
        calls.append("rollback")
        forcedInspection = LegacySyncInspection(phase: .rolledBack, live: true,
                                                old: false, stage: true, lock: false)
    }
}

@MainActor
struct LegacySyncTransactionTests {
    private func fixture() throws -> (URL, LegacySyncPlan, LegacyMenuStageManifest, URL, LegacyConsoleReport) {
        let root = try testDirectory()
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let report = LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
                                         scriptVersion: "[master]v1.0.3-110(7f31082)",
                                         activePage: LegacyConsoleReport.gameRoot + "/000",
                                         freeBytes: 300 * 1024 * 1024,
                                         savesPath: "/var/lib/clover/profiles/0", stockCodes: stock,
                                         visibleCodes: stock)
        let review = String(repeating: "a", count: 64)
        let tar = root.appendingPathComponent("menu.tar")
        try Data(repeating: 7, count: 8192).write(to: tar)
        let archive = try LegacySyncPlan.SourceFile.capture(tar)
        let manifest = LegacyMenuStageManifest(reviewSHA256: review, menuDirectory: root,
                                               archiveURL: tar, entries: [],
                                               treeSHA256: String(repeating: "b", count: 64),
                                               archiveSHA256: archive.sha256, archiveBytes: archive.byteCount)
        let backup = root.appendingPathComponent("Backups/LegacyInspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let backupArchive = backup.appendingPathComponent("console.tar")
        FileManager.default.createFile(atPath: backupArchive.path, contents: nil)
        let backupHandle = try FileHandle(forWritingTo: backupArchive)
        var writer = SWCompression.TarWriter(fileHandle: backupHandle, force: .ustar)
        for code in stock.sorted() {
            if code == stock.sorted().first {
                var page = TarEntryInfo(name: "var/lib/hakchi/games/nes/000", type: .directory)
                page.permissions = Permissions(rawValue: 0o755)
                try writer.append(TarEntry(info: page, data: nil))
            }
            var folder = TarEntryInfo(name: "var/lib/hakchi/games/nes/000/\(code)", type: .directory)
            folder.permissions = Permissions(rawValue: 0o755)
            try writer.append(TarEntry(info: folder, data: nil))
            var item = TarEntryInfo(name: "var/lib/hakchi/games/nes/000/\(code)/\(code).desktop",
                                    type: .regular)
            item.permissions = Permissions(rawValue: 0o644)
            try writer.append(TarEntry(info: item,
                data: Data("[Desktop Entry]\nName=\(code)\n".utf8)))
        }
        try writer.finalize(); try backupHandle.close()
        let backupData = try Data(contentsOf: backupArchive)
        let observed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
        let backupManifest: [String: Any] = [
            "formatVersion": 1, "scope": "Console inspection",
            "eligibleForAutomaticRestore": false, "deviceIdentityVerified": false,
            "archiveFilename": "console.tar",
            "sha256": BackupManifest.digest(backupData), "byteCount": backupData.count,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "observedReport": observed
        ]
        try JSONSerialization.data(withJSONObject: backupManifest).write(to: backup.appendingPathComponent("manifest.json"))
        _ = try LegacyMenuSnapshot.record(directory: backup,
            chipID: "0123456789abcdef0123456789abcdef")
        let plan = LegacySyncPlan(selectedGames: [], pages: [], structure: .init(maximumGamesPerPage: .twentyFive),
                                  menuGraph: .init(screens: [], warnings: []), folderArtworkSources: [:],
                                  addedCodes: [], keptCodes: [],
                                  removedCodes: [], requiredStagingBytes: 80 * 1024 * 1024,
                                  stageBytes: 8 * 1024 * 1024, freeBytesAtReview: report.freeBytes,
                                  maximumGamesPerPage: 25, trialCode: "CLV-H-AAAAA", consoleOrder: .title,
                                  reviewedLocalCodes: [], report: report,
                                  reviewSHA256: review)
        return (root, plan, manifest, backup, report)
    }

    @Test func uploadAndVerificationStopBeforeActivation() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        #expect(try await store.load(id).phase == .verified)
        let calls = await device.snapshot()
        #expect(calls.contains("chipID") && calls.contains("inventoryLive"))
        #expect(calls.suffix(2) == ["upload", "verify"])
    }

    @Test func uploadFailureLeavesPreparedJournalAndNeverActivates() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        await device.setFault(.upload)
        let id = UUID()
        await #expect(throws: (any Error).self) {
            try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                        backup: backup, device: device)
        }
        #expect(try await store.load(id).phase == .prepared)
        #expect(!(await device.snapshot()).contains("activate"))
    }

    @Test func olderExactBackupCanBeReusedWithoutAnotherCapture() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = backup.appendingPathComponent("manifest.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object["createdAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -86_400))
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        #expect(try await store.load(id).phase == .verified)
        #expect((await device.snapshot()).contains("inventoryLive"))
    }

    @Test func missingMenuSidecarOrWrongDeviceRefusesBeforeUpload() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        await device.setIdentity("fedcba9876543210fedcba9876543210")
        await #expect(throws: (any Error).self) {
            try await transaction.stage(operationID: UUID(), plan: plan, manifest: manifest,
                                        backup: backup, device: device)
        }
        #expect(!(await device.snapshot()).contains("upload"))

        let another = try FakeLegacySyncDevice(report: report, backup: backup)
        try FileManager.default.removeItem(at: backup.appendingPathComponent(LegacyMenuSnapshot.filename))
        await #expect(throws: (any Error).self) {
            try await transaction.stage(operationID: UUID(), plan: plan, manifest: manifest,
                                        backup: backup, device: another)
        }
        #expect((await another.snapshot()).isEmpty)
    }

    @Test func changedLiveMenuRefusesBeforeUploadOrJournal() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        await device.setLiveMismatch()
        let id = UUID()
        await #expect(throws: (any Error).self) {
            try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                        backup: backup, device: device)
        }
        #expect(!(await device.snapshot()).contains("upload"))
        await #expect(throws: (any Error).self) { try await store.load(id) }
    }

    @Test func unresolvedLegacyChangeRefusesBeforeUpload() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        try FileManager.default.createDirectory(at: workspace.journals, withIntermediateDirectories: true)
        try Data("unresolved".utf8).write(to: workspace.journals.appendingPathComponent("legacy-\(UUID().uuidString).json"))
        let store = LegacySyncJournalStore(directory: workspace.journals)
        let transaction = LegacySyncTransaction(store: store, workspace: workspace)
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        await #expect(throws: (any Error).self) {
            try await transaction.stage(operationID: UUID(), plan: plan, manifest: manifest,
                                        backup: backup, device: device)
        }
        #expect(await device.snapshot().isEmpty)
    }

    @Test func activationDisconnectBecomesUncertainAndCannotRetry() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        await device.setFault(.activate)
        await #expect(throws: (any Error).self) {
            try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                           backup: backup, device: device)
        }
        #expect(try await store.load(id).phase == .uncertain)
        await #expect(throws: (any Error).self) {
            try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                           backup: backup, device: device)
        }
        #expect((await device.snapshot()).filter { $0 == "activate" }.count == 1)
    }

    @Test func exactActiveInspectionWaitsForMenuAcceptance() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                       backup: backup, device: device)
        #expect(try await store.load(id).phase == .activePendingAcceptance)
        #expect((await device.snapshot()).suffix(4) == ["inspect", "identity", "activate", "inspectOperation"])
    }

    @Test func activationUsesPostTransferFreeSpaceRatherThanPreUploadBudget() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        let afterUpload = LegacyConsoleReport(bootVersion: report.bootVersion,
            kernelVersion: report.kernelVersion, scriptVersion: report.scriptVersion,
            activePage: report.activePage, freeBytes: 70 * 1024 * 1024,
            savesPath: report.savesPath, stockCodes: report.stockCodes,
            visibleCodes: report.visibleCodes)
        await device.setReport(afterUpload)
        try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                       backup: backup, device: device)
        #expect(try await store.load(id).phase == .activePendingAcceptance)
        #expect((await device.snapshot()).contains("activate"))
    }

    @Test func lostVerificationReceiptCanBeReconciledWithoutReupload() async throws {
        let (root, plan, sourceManifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyTree = BackupManifest.digest(Data("\n".utf8))
        let manifest = LegacyMenuStageManifest(reviewSHA256: sourceManifest.reviewSHA256,
            menuDirectory: sourceManifest.menuDirectory, archiveURL: sourceManifest.archiveURL,
            entries: [], treeSHA256: emptyTree,
            archiveSHA256: sourceManifest.archiveSHA256, archiveBytes: sourceManifest.archiveBytes)
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        await device.setFault(.verify)
        await #expect(throws: (any Error).self) {
            try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                        backup: backup, device: device)
        }
        #expect(try await store.load(id).phase == .uploaded)
        await device.setFault(.none)
        await device.setInventory(Data("STAGE_INVENTORY:\(id.uuidString)\nEND_STAGE_INVENTORY\n".utf8))
        await device.setInspection(LegacySyncInspection(phase: .missing, live: true,
            old: false, stage: true, lock: false, archive: true, verified: true))
        try await transaction.reconcileUploaded(operationID: id, manifest: manifest, device: device)
        #expect(try await store.load(id).phase == .verified)
        #expect((await device.snapshot()).filter { $0 == "upload" }.count == 1)
        #expect(!(await device.snapshot()).contains("activate"))
    }

    @Test func mismatchKeepsUploadedJournalAndOldMenu() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        await device.setFault(.verify)
        await #expect(throws: (any Error).self) {
            try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                        backup: backup, device: device)
        }
        await device.setFault(.none)
        await device.setInventory(Data("STAGE_INVENTORY:\(id.uuidString)\nEND_STAGE_INVENTORY\n".utf8))
        await device.setInspection(LegacySyncInspection(phase: .missing, live: true,
            old: false, stage: true, lock: false, archive: true, verified: true))
        await #expect(throws: (any Error).self) {
            try await transaction.reconcileUploaded(operationID: id, manifest: manifest, device: device)
        }
        #expect(try await store.load(id).phase == .uploaded)
        #expect(!(await device.snapshot()).contains("activate"))
    }

    @Test func acceptanceRequiresMenuConfirmationAndKeepsOldTree() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        let store = LegacySyncJournalStore(directory: workspace.journals)
        let transaction = LegacySyncTransaction(store: store, workspace: workspace)
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                       backup: backup, device: device)
        await #expect(throws: (any Error).self) {
            try await transaction.accept(operationID: id, manifest: manifest,
                                         mainMenuConfirmed: false, device: device)
        }
        #expect(!(await device.snapshot()).contains("accept"))
        try await transaction.accept(operationID: id, manifest: manifest,
                                     mainMenuConfirmed: true, device: device)
        #expect(try await store.load(id).phase == .accepted)
        #expect((await device.snapshot()).contains("accept"))
    }

    @Test func acceptanceOnLaterMenuPageDoesNotMakeJournalUncertain() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                       backup: backup, device: device)
        await device.setReport(LegacyConsoleReport(bootVersion: report.bootVersion,
            kernelVersion: report.kernelVersion, scriptVersion: report.scriptVersion,
            activePage: LegacyConsoleReport.gameRoot + "/006", freeBytes: report.freeBytes,
            savesPath: report.savesPath, stockCodes: report.stockCodes,
            visibleCodes: report.visibleCodes))
        await #expect(throws: (any Error).self) {
            try await transaction.accept(operationID: id, manifest: manifest,
                                         mainMenuConfirmed: true, device: device)
        }
        #expect(try await store.load(id).phase == .activePendingAcceptance)
        #expect(!(await device.snapshot()).contains("accept"))
    }

    @Test func acceptedMarkerWithOwnedLockCanResumeFinalization() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                       backup: backup, device: device)
        await device.setFault(.accept)
        await #expect(throws: (any Error).self) {
            try await transaction.accept(operationID: id, manifest: manifest,
                                         mainMenuConfirmed: true, device: device)
        }
        #expect(try await store.load(id).phase == .uncertain)
        await device.setFault(.none)
        await device.setInspection(LegacySyncInspection(phase: .accepted, live: true,
                                                        old: true, stage: false, lock: true))
        try await transaction.resumeAcceptance(operationID: id, mainMenuConfirmed: true,
                                               device: device)
        #expect(try await store.load(id).phase == .activePendingAcceptance)
    }

    @Test func newAppSessionCanInspectUncertainRemoteStateWithoutRetry() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        let store = LegacySyncJournalStore(directory: workspace.journals)
        let transaction = LegacySyncTransaction(store: store, workspace: workspace)
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        await device.setFault(.activate)
        await #expect(throws: (any Error).self) {
            try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                           backup: backup, device: device)
        }
        await device.setFault(.none)
        await device.setInspection(LegacySyncInspection(phase: .oldMoved, live: false,
                                                        old: true, stage: true, lock: true))
        let fresh = LegacySyncTransaction(store: LegacySyncJournalStore(directory: workspace.journals),
                                          workspace: workspace)
        let observation = try await fresh.inspectRecovery(operationID: id, device: device)
        #expect(observation.outcome == .firstRenameUncertain)
        #expect(try await store.load(id).phase == .uncertain)
        #expect((await device.snapshot()).filter { $0 == "activate" }.count == 1)
    }

    @Test func interruptedUploadWithoutConsoleTransactionCanBeDiscarded() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        await device.setFault(.upload)
        await #expect(throws: (any Error).self) {
            try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                        backup: backup, device: device)
        }
        await device.setInspection(LegacySyncInspection(phase: .missing, transaction: false,
                                                        live: true, old: false, stage: false, lock: false))
        try await transaction.discardInactive(operationID: id, device: device)
        #expect(try await store.load(id).phase == .discarded)
        #expect(try await store.latestUnresolved() == nil)
        #expect(!(await device.snapshot()).contains("discard"))
    }

    @Test func partialAndVerifiedInactiveTransfersRequireExplicitDiscard() async throws {
        for partial in [true, false] {
            let (root, plan, manifest, backup, report) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
            let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
            let device = try FakeLegacySyncDevice(report: report, backup: backup)
            let id = UUID()
            if partial {
                await device.setFault(.upload)
                await #expect(throws: (any Error).self) {
                    try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                                backup: backup, device: device)
                }
            } else {
                try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                            backup: backup, device: device)
            }
            await device.setInspection(LegacySyncInspection(phase: .missing, live: true,
                                                            old: false, stage: !partial, lock: false))
            try await transaction.discardInactive(operationID: id, device: device)
            #expect(try await store.load(id).phase == .discarded)
            #expect((await device.snapshot()).contains("discard"))
            #expect(!(await device.snapshot()).contains("activate"))
        }
    }

    @Test func postRenameRollbackRequiresOwnedInspectedLayout() async throws {
        for state in [
            LegacySyncInspection(phase: .oldMoved, live: false, old: true, stage: true, lock: true),
            LegacySyncInspection(phase: .newActive, live: true, old: true, stage: false, lock: true)
        ] {
            let (root, plan, manifest, backup, report) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
            let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
            let device = try FakeLegacySyncDevice(report: report, backup: backup)
            let id = UUID()
            try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                        backup: backup, device: device)
            await device.setFault(.activate)
            await #expect(throws: (any Error).self) {
                try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                               backup: backup, device: device)
            }
            await device.setFault(.none)
            await device.setInspection(state)
            try await transaction.rollback(operationID: id, device: device)
            #expect(try await store.load(id).phase == .rolledBack)
            #expect((await device.snapshot()).filter { $0 == "rollback" }.count == 1)
        }
    }

    @Test func uncertainWorkingMenuCanResumeAcceptanceWithoutSecondSwap() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        await device.setFault(.activate)
        await #expect(throws: (any Error).self) {
            try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                           backup: backup, device: device)
        }
        await device.setInspection(LegacySyncInspection(phase: .menuStarted, live: true,
                                                        old: true, stage: false, lock: true))
        await #expect(throws: (any Error).self) {
            try await transaction.resumeAcceptance(operationID: id, mainMenuConfirmed: false, device: device)
        }
        try await transaction.resumeAcceptance(operationID: id, mainMenuConfirmed: true, device: device)
        #expect(try await store.load(id).phase == .activePendingAcceptance)
        #expect((await device.snapshot()).filter { $0 == "activate" }.count == 1)
    }

    @Test func lostRollbackReceiptOnlyReconcilesJournal() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        await device.setFault(.activate)
        await #expect(throws: (any Error).self) {
            try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                           backup: backup, device: device)
        }
        await device.setInspection(LegacySyncInspection(phase: .rolledBack, live: true,
                                                        old: false, stage: false, failed: true, lock: false))
        try await transaction.rollback(operationID: id, device: device)
        #expect(try await store.load(id).phase == .rolledBack)
        #expect(!(await device.snapshot()).contains("rollback"))
    }

    @Test func lostAcceptanceReceiptOnlyReconcilesJournal() async throws {
        let (root, plan, manifest, backup, report) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root.appendingPathComponent("journals"))
        let transaction = LegacySyncTransaction(store: store, workspace: WorkspacePaths(root: root))
        let device = try FakeLegacySyncDevice(report: report, backup: backup)
        let id = UUID()
        try await transaction.stage(operationID: id, plan: plan, manifest: manifest,
                                    backup: backup, device: device)
        try await transaction.activate(operationID: id, plan: plan, manifest: manifest,
                                       backup: backup, device: device)
        try await store.markUncertain(id)
        await device.setInspection(LegacySyncInspection(phase: .accepted, live: true,
                                                        old: true, stage: false, lock: false))
        try await transaction.reconcileAccepted(operationID: id, mainMenuConfirmed: true,
                                                device: device)
        #expect(try await store.load(id).phase == .accepted)
        #expect(!(await device.snapshot()).contains("accept"))
    }
}

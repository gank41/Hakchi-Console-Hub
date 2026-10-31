import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryConnectionTests {
    @Test func connectionProgressIdentifiesTheSlowOwnerLookupAndFailureStillClosesUSB() async throws {
        let io = SNESConnectionFake(fault: "source-missing"), progress = SNESConnectionProgressLog()
        let session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        await #expect(throws: (any Error).self) {
            try await session.connect(sessionID: UUID(), progress: { await progress.append($0) },
                loadOwner: { _, _ in throw SNESLibraryInstallation.failure() })
        }
        #expect(await progress.values == [.openingUSB, .identifyingConsole, .checkingSetupFiles])
        #expect(await io.events.filter { $0 == "close" }.count == 1)
        #expect(!((await io.events).contains("report")))
    }
    @MainActor @Test func rollbackCannotUseAnInertPermitWithoutThePrivateNativeContext() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,_)=try await SNESLibraryColdCheckTests().saved(root)
        let permit=try await journal.beginRollback(current:SNESLibrarySelectionTransactionTests().active(plan),attachment:SNESLibraryContextTests.device())
        let io=SNESConnectionFake(fault:"source-missing"),session=SNESLibraryConnectionSession(attachment:SNESLibraryContextTests.device(),io:io)
        await #expect(throws:(any Error).self) {try await session.rollbackReady(plan:plan)}
        await #expect(throws:(any Error).self) {try await session.restorePrevious(plan:plan,permit:permit)}
        await #expect(throws:(any Error).self) {try await session.verifyRestarted(plan:plan,previousAttachment:SNESLibraryContextTests.device(),destination:.previous)}
        #expect(await io.events.isEmpty);try await journal.rollbackUncertain();try await journal.close()
    }
    @MainActor @Test func cancellationCannotReadOrDeleteWithoutThePrivateConnectedContext() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, _) = try await SNESLibrarySelectionJournalTests().copied(root)
        let live = try SNESLibraryCopyTransactionTests().after(plan)
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: live, upload: nil)
        let preview = try SNESLibraryDiscardJournalTests().preview(scope, context: live.contextSHA256)
        let permit = try await journal.beginDiscard(scope: scope, preview: preview, attachment: SNESLibraryContextTests.device())
        let io = SNESConnectionFake(fault: "source-missing"), session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        await #expect(throws: (any Error).self) { try await session.reviewDiscard(plan: plan, reconciliation: permit.reconciliation) }
        await #expect(throws: (any Error).self) { try await session.discardCopy(plan: plan, scope: scope, preview: preview, permit: permit) }
        #expect(await io.events.isEmpty)
        try await journal.discardUncertain(); try await journal.close()
    }

    @MainActor @Test func inertCleanupPermitCannotReachUSBWithoutTheLiveNativeContext() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, _, scope, live, _) = try await SNESLibraryCleanupJournalTests().accepted(root)
        let preview = try SNESLibraryCleanupJournalTests().preview(scope, context: live.contextSHA256)
        let permit = try await journal.beginCleanup(scope: scope, preview: preview)
        let io = SNESConnectionFake(fault: "source-missing"), session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        await #expect(throws: (any Error).self) { try await session.removeTemporary(plan: plan, scope: scope, preview: preview, permit: permit) }
        #expect(await io.events.isEmpty); try await journal.cleanupUncertain(); try await journal.close()
    }

    @MainActor @Test func cleanupPreviewNeedsThePrivateConnectedContextBeforeUSB() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, current, backup, originals) = try await SNESLibraryCleanupPlanTests().fixture(root, changedROM: true)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: current, backup: backup, originals: originals)
        let io = SNESConnectionFake(fault: "source-missing"), session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        await #expect(throws: (any Error).self) { try await session.previewCleanup(plan: plan, scope: scope) }
        #expect(await io.events.isEmpty)
    }
    @MainActor @Test func restartVerificationCannotUseAnUnconnectedDeviceOrInertReports() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, _) = try await SNESLibraryColdCheckTests().saved(root)
        let io = SNESConnectionFake(fault: "source-missing"), session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(id: 45), io: io)
        await #expect(throws: (any Error).self) { try await session.verifyRestarted(plan: plan, previousAttachment: SNESLibraryContextTests.device()) }
        #expect(await io.events.isEmpty); try await journal.close()
    }
    @MainActor @Test func savingAChoiceAlsoRequiresALiveNativeContextBeforeUSB() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, _) = try await SNESLibrarySelectionJournalTests().copied(root)
        let attachment = SNESLibraryContextTests.device(), permit = try await journal.beginShow(attachment: attachment)
        let io = SNESConnectionFake(fault: "source-missing"), session = SNESLibraryConnectionSession(attachment: attachment, io: io)
        await #expect(throws: (any Error).self) { try await session.selectionAttachment(plan: plan) }
        await #expect(throws: (any Error).self) { try await session.saveSelection(plan: plan, permit: permit) }
        #expect(await io.events.isEmpty)
        try await journal.selectionUncertain(); try await journal.close()
    }
    @MainActor @Test func inertPlanAndPermitCannotCopyWithoutALiveNativeContext() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        let permit = try await journal.beginCopy(), io = SNESConnectionFake(fault: "source-missing")
        let session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        await #expect(throws: (any Error).self) { try await session.copy(plan: plan, permit: permit) }
        #expect(await io.events.isEmpty)
        try await journal.copyUncertain(); try await journal.close()
    }
    @Test(arguments: ["source-missing", "identity", "attachment", "open"])
    func failedReadOnlyConnectionClosesOnceAndCannotReachReports(_ fault: String) async throws {
        let io = SNESConnectionFake(fault: fault), calls = SNESOwnerLoadCalls()
        let session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        await #expect(throws: (any Error).self) {
            try await session.connect(sessionID: UUID(), loadOwner: { hwid, version in
                await calls.record(hwid, version); throw SNESLibraryInstallation.failure()
            })
        }
        let events = await io.events
        #expect(events.filter { $0 == "open" }.count == 1)
        #expect(events.filter { $0 == "close" }.count == 1)
        #expect(!events.contains("report"))
        let rows = await calls.values
        #expect(rows.count == (fault == "source-missing" ? 1 : 0))
        if let first = rows.first { #expect(first.0 == String(repeating: "1", count: 32) && first.1 == 0x6a07) }
        await session.disconnect()
        #expect(await io.events.filter { $0 == "close" }.count == 1)
    }
    @Test func cancellationDuringDiscoveryClosesWithoutSourceLookup() async throws {
        let io = SNESConnectionFake(fault: "pause"), calls = SNESOwnerLoadCalls()
        let session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        let task = Task {
            try await session.connect(sessionID: UUID(), loadOwner: { hwid, version in
                await calls.record(hwid, version); throw SNESLibraryInstallation.failure()
            })
        }
        await io.waitUntilIdentity(); task.cancel(); await io.releaseIdentity()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.values.isEmpty)
        #expect(await io.events.filter { $0 == "close" }.count == 1)
    }
    @Test func recoveryDescriptorCannotOpenNormalConnection() async {
        let io = SNESConnectionFake(fault: "source-missing")
        let session = SNESLibraryConnectionSession(attachment: probeFEL(), io: io)
        await #expect(throws: (any Error).self) {
            try await session.connect(sessionID: UUID(), loadOwner: { _, _ in throw SNESLibraryInstallation.failure() })
        }
        #expect(await io.events.isEmpty)
    }
    @Test func disconnectDuringAwaitInvalidatesConnectionWithoutClosingAnotherOwner() async throws {
        let io = SNESConnectionFake(fault: "pause"), calls = SNESOwnerLoadCalls()
        let session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: io)
        let first = Task {
            try await session.connect(sessionID: UUID(), loadOwner: { hwid, version in
                await calls.record(hwid, version); throw SNESLibraryInstallation.failure()
            })
        }
        await io.waitUntilIdentity()
        await #expect(throws: (any Error).self) {
            try await session.connect(sessionID: UUID(), loadOwner: { _, _ in throw SNESLibraryInstallation.failure() })
        }
        #expect(!((await io.events).contains("close")))
        await session.disconnect(); await io.releaseIdentity()
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(await calls.values.isEmpty)
        #expect(await io.events.filter { $0 == "open" }.count == 1)
        #expect(await io.events.filter { $0 == "close" }.count == 1)
    }
}
private actor SNESConnectionProgressLog {
    private(set) var values: [ConsoleConnectionStage] = []
    func append(_ value: ConsoleConnectionStage) { values.append(value) }
}
private actor SNESOwnerLoadCalls {
    private(set) var values: [(String, UInt16)] = []
    func record(_ hwid: String, _ version: UInt16) { values.append((hwid, version)) }
}
private actor SNESConnectionFake: SNESLibraryConnectionIO {
    let fault: String
    private(set) var events: [String] = []
    private var identityRead = false
    private var entered = false
    private var gate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(fault: String) { self.fault = fault }
    func open() throws { events.append("open"); if fault == "open" { throw LegacyInspectionError.disconnected } }
    func inventory() -> [RecoveryProbeUSBDevice] {
        events.append("inventory")
        return [SNESLibraryContextTests.device(id: fault == "attachment" && identityRead ? 45 : 44)]
    }
    func identity(challenge: UUID) async -> Data {
        events.append("identity"); identityRead = true
        if fault == "pause" {
            entered = true; waiters.forEach { $0.resume() }; waiters.removeAll()
            await withCheckedContinuation { gate = $0 }
        }
        let region = fault == "identity" ? "EUR" : "USA"
        return Data("SWIFTHAKCHI_SNES_IDENTITY_V1\nCHALLENGE=\(challenge.uuidString)\nBOARD=dp-shvc\nREGION=\(region)\nKERNEL=3.4.113\nHWID=\(String(repeating: "1", count: 32))\nEND\n".utf8)
    }
    func report(installation: SNESLibraryInstallation, challenge: UUID) -> Data { events.append("report"); return Data() }
    func libraryInventory(context: SNESLibraryContext, challenge: UUID) throws -> Data { throw LegacyInspectionError.invalidReport }
    func librarySpace(context: SNESLibraryContext, selection: SNESLibraryInventory.Selection, challenge: UUID) throws -> Data { throw LegacyInspectionError.invalidReport }
    func libraryChunk(context: SNESLibraryContext, file: SNESLibraryInventory.File, offset: Int, challenge: UUID) throws -> Data { throw LegacyInspectionError.invalidReport }
    func disconnect() { events.append("close") }
    func waitUntilIdentity() async { if entered { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseIdentity() { gate?.resume(); gate = nil }
}

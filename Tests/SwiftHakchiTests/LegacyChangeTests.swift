import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct LegacyChangeTests {
    @Test func targetRejectsUnsafeNamesAndUnboundedSizes() throws {
        _ = try LegacyGameTarget(code: "CLV-H-ABCDE", page: "001", sha256: String(repeating: "a", count: 64), bytes: 4096)
        for code in ["CLV-P-NAAAE", "CLV-S-00000", "CLV-H-../xx", "CLV-H-ABCDEF", "clv-h-abcde"] {
            #expect(throws: (any Error).self) { try LegacyGameTarget(code: code, page: "001", sha256: String(repeating: "a", count: 64), bytes: 4096) }
        }
        #expect(throws: (any Error).self) { try LegacyGameTarget(code: "CLV-H-ABCDE", page: "../", sha256: String(repeating: "a", count: 64), bytes: 4096) }
        #expect(throws: (any Error).self) { try LegacyGameTarget(code: "CLV-H-ABCDE", page: "001", sha256: "bad", bytes: -1) }
    }
    @Test func leaseExcludesOrdinaryReadsAndInvalidatesOnReconnect() async throws {
        let usb = LegacyFakeUSB(); let client = LegacyInspectionClient(transport: usb)
        try await client.connect()
        let lease = try await client.reserveForChange()
        await #expect(throws: LegacyInspectionError.self) { try await client.execute(.report) }
        await #expect(throws: LegacyInspectionError.self) { try await client.reserveForChange() }
        #expect(try await lease.execute(.report, timeoutMilliseconds: 1000).succeeded)
        await client.disconnect(); try await client.connect()
        await #expect(throws: LegacyInspectionError.self) { try await lease.execute(.report, timeoutMilliseconds: 1000) }
        await lease.release()
        #expect(try await client.execute(.report).succeeded)
        await client.disconnect()
    }
    @Test func releaseAllowsOrdinaryReadButCannotAuthorizeAgain() async throws {
        let client = LegacyInspectionClient(transport: LegacyFakeUSB())
        try await client.connect(); let lease = try await client.reserveForChange()
        await lease.release()
        await #expect(throws: LegacyInspectionError.self) { try await lease.execute(.report, timeoutMilliseconds: 1000) }
        #expect(try await client.execute(.report).succeeded)
        await client.disconnect()
    }
}

extension LegacyChangeTests {
    @Test func missingOrChangedBackupCannotPassCommitReadiness() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { try LegacyGameChangeService.verifyBackup(dir) }
        try Data("{\"sha256\":\"bad\"}".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        try Data("incomplete".utf8).write(to: dir.appendingPathComponent("console.tar"))
        #expect(throws: (any Error).self) { try LegacyGameChangeService.verifyBackup(dir) }
    }
    @Test func applyWithoutPreparedSessionCannotWriteEvenWithConfirmation() async {
        let service = LegacyGameChangeService()
        await #expect(throws: (any Error).self) {
            try await service.apply(id: UUID(), mainMenuConfirmed: true, workspace: .init(root: URL(fileURLWithPath: "/private/tmp")))
        }
    }
}

extension LegacyChangeTests {
    @Test func reviewRequiresFreshPlanSameSessionAndExplicitMenuConfirmation() {
        let created = Date(timeIntervalSince1970: 1000)
        #expect(!LegacyChangeReviewPolicy.canApply(confirmed: false, busy: false, sameSession: true, createdAt: created, now: created))
        #expect(!LegacyChangeReviewPolicy.canApply(confirmed: true, busy: false, sameSession: false, createdAt: created, now: created))
        #expect(!LegacyChangeReviewPolicy.canApply(confirmed: true, busy: true, sameSession: true, createdAt: created, now: created))
        #expect(!LegacyChangeReviewPolicy.canApply(confirmed: true, busy: false, sameSession: true, createdAt: created, now: created.addingTimeInterval(300)))
        #expect(!LegacyChangeReviewPolicy.canApply(confirmed: true, busy: false, sameSession: true, createdAt: created, now: created.addingTimeInterval(-1)))
        #expect(LegacyChangeReviewPolicy.canApply(confirmed: true, busy: false, sameSession: true, createdAt: created, now: created.addingTimeInterval(299)))
    }
}


extension LegacyChangeTests {
    @Test func scriptsUseShortBootstrapAndCheckedInputInsteadOfOverflowingLegacyDaemon() async throws {
        let usb = LegacyFakeUSB(.stream); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(); let lease = try await client.reserveForChange()
        _ = try await lease.perform(.probe("CLV-H-ABCDE"))
        let commands = await usb.execPayloads
        #expect(commands.count == 1)
        #expect(commands[0].count < 1020)
        let expected = try LegacyChangeScripts.probe(code: "CLV-H-ABCDE").trimmingCharacters(in: .newlines)
        #expect(await usb.streamedInput == Data(expected.utf8))
        await lease.release(); await client.disconnect()
    }
}


extension LegacyChangeTests {
    @Test func framedPreflightRefusalFinalizesJournalAndAllowsRetry() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SwiftHakchiCore.WorkspacePaths(root: root)
        let usb = LegacyFakeUSB(.refusedBeforeMutation); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(); let lease = try await client.reserveForChange()
        let target = try LegacyGameTarget(code: "CLV-H-ABCDE", page: "001", sha256: String(repeating: "a", count: 64), bytes: 4096)
        let report = try LegacyConsoleReport.parse(Data(legacyReportFixture.utf8))
        let plan = LegacyChangePlan(id: UUID(), name: "Example", target: target, report: report, backup: root, recovery: root, createdAt: Date())
        await #expect(throws: (any Error).self) { try await LegacyGameChangeService.commit(plan: plan, lease: lease, workspace: workspace) }
        #expect(try LegacyGameChangeService.latest(workspace: workspace) == nil)
        await usb.setMode(.applied)
        let retry = LegacyChangePlan(id: UUID(), name: "Example", target: target, report: report, backup: root, recovery: root, createdAt: Date())
        #expect(try await LegacyGameChangeService.commit(plan: retry, lease: lease, workspace: workspace).phase == .applied)
        await lease.release(); await client.disconnect()
    }
}


extension LegacyChangeTests {
    @Test func longMutationScriptDrainsEachInputAcknowledgementBeforeSendingMore() async throws {
        let usb = LegacyFakeUSB(.backpressure); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(); let lease = try await client.reserveForChange()
        let target = try LegacyGameTarget(code: "CLV-H-ABCDE", page: "001", sha256: String(repeating: "a", count: 64), bytes: 4096)
        let id = UUID()
        #expect(try await lease.perform(.hide(id, target)).succeeded)
        let script = try LegacyChangeScripts.hide(id: id, target: target).trimmingCharacters(in: .newlines)
        #expect(await usb.streamedInput == Data(script.utf8))
        await lease.release(); await client.disconnect()
    }
}

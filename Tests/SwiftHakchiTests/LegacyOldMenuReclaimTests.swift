import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct LegacyOldMenuReclaimTests {
    private let id = UUID(uuidString: "4386FFF9-67E1-49C1-9A45-2023D58130A2")!
    private let live = String(repeating: "a", count: 64)
    private let former = String(repeating: "b", count: 64)

    @Test func intactTreeCanRecoverAfterDurableRemovalIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LegacyOldMenuReclaimJournalStore(directory: directory)
        try await store.begin(LegacyOldMenuReclaimJournal(operationID: id,
            currentTreeSHA256: live, previousTreeSHA256: former,
            previousSnapshotSHA256: former, chipIDFingerprint: live,
            createdAt: Date(), phase: .prepared))
        try await store.advance(id, from: .prepared, to: .removalIntent)
        try await store.advance(id, from: .removalIntent, to: .prepared)
        #expect(try await store.load(id).phase == .prepared)
    }

    @Test func newMenuWritesWaitForAnAmbiguousCleanup() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        let store = LegacyOldMenuReclaimJournalStore(directory: workspace.journals)
        try await store.begin(LegacyOldMenuReclaimJournal(operationID: id,
            currentTreeSHA256: live, previousTreeSHA256: former,
            previousSnapshotSHA256: former, chipIDFingerprint: live,
            createdAt: Date(), phase: .prepared))
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        try await store.advance(id, from: .prepared, to: .removalIntent)
        await #expect(throws: (any Error).self) {
            try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        }
        try await store.advance(id, from: .removalIntent, to: .uncertain)
        await #expect(throws: (any Error).self) {
            try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        }
        try await store.advance(id, from: .uncertain, to: .completed)
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
    }

    @Test func preparedPreviewCanBeSupersededByLaterAcceptedMenu() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LegacyOldMenuReclaimJournalStore(directory: directory)
        let first = LegacyOldMenuReclaimJournal(operationID: id,
            currentTreeSHA256: live, previousTreeSHA256: former,
            previousSnapshotSHA256: former, chipIDFingerprint: live,
            createdAt: Date(), phase: .prepared, testedMenus: true)
        try await store.begin(first)
        try await store.advance(id, from: .prepared, to: .abandoned)
        #expect(try await store.latestUnresolved() == nil)
        let laterID = UUID()
        try await store.begin(LegacyOldMenuReclaimJournal(operationID: laterID,
            currentTreeSHA256: former, previousTreeSHA256: live,
            previousSnapshotSHA256: live, chipIDFingerprint: live,
            createdAt: Date(), phase: .prepared, testedMenus: true))
        #expect(try await store.latestUnresolved()?.operationID == laterID)
        await #expect(throws: (any Error).self) {
            try await store.advance(id, from: .abandoned, to: .removalIntent)
        }
    }

    @Test func olderPreparedPreviewCanBeReplacedAfterExplicitTesting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LegacyOldMenuReclaimJournalStore(directory: directory)
        let old = LegacyOldMenuReclaimJournal(operationID: id,
            currentTreeSHA256: live, previousTreeSHA256: former,
            previousSnapshotSHA256: former, chipIDFingerprint: live,
            createdAt: Date(), phase: .prepared)
        try await store.begin(old)
        try await store.advance(id, from: .prepared, to: .abandoned)
        try await store.begin(LegacyOldMenuReclaimJournal(operationID: id,
            currentTreeSHA256: live, previousTreeSHA256: former,
            previousSnapshotSHA256: former, chipIDFingerprint: live,
            createdAt: Date(), phase: .prepared, testedMenus: true))
        #expect(try await store.load(id).testedMenus == true)
    }

    @Test func removalCommandIsFixedToOneOldTreeAndRequiresBothDigests() throws {
        let command = try LegacyOldMenuReclaimCommands.remove(operationID: id,
            liveTreeSHA256: live, oldTreeSHA256: former)
        #expect(command.contains("/var/lib/hakchi/games/nes.swift-old-" + id.uuidString))
        #expect(command.contains("tree_digest \"$live\""))
        #expect(command.contains("tree_digest \"$old\" include"))
        #expect(command.contains("= '\(former)'"))
        #expect(command.contains("$tx/old.identity"))
        #expect(command.contains("rm -r -- \"$old\""))
        #expect(!command.contains("rm -rf"))
        #expect(!command.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "sync"
        })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        let input = Pipe(); process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(command.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func receiptRequiresExactOperationAndFormerDigest() {
        let expected = "RECLAIMED_OLD_MENU:\(id.uuidString):\(former)\n"
        let good = SSHResult(stdout: expected, stderr: "", stdoutData: Data(expected.utf8), exitCode: 0)
        #expect(throws: Never.self) {
            try LegacyOldMenuReclaimCommands.requireRemovedReceipt(good,
                operationID: id, oldTreeSHA256: former)
        }
        let changed = "RECLAIMED_OLD_MENU:\(id.uuidString):\(live)\n"
        let wrong = SSHResult(stdout: changed, stderr: "", stdoutData: Data(changed.utf8), exitCode: 0)
        #expect(throws: (any Error).self) {
            try LegacyOldMenuReclaimCommands.requireRemovedReceipt(wrong,
                operationID: id, oldTreeSHA256: former)
        }
    }

    @Test func readOnlyCommandChecksSameGuardsAndReportsAllocatedSpace() throws {
        let command = try LegacyOldMenuReclaimCommands.inspect(operationID: id,
            liveTreeSHA256: live, oldTreeSHA256: former)
        #expect(command.contains("tree_digest \"$old\" include"))
        #expect(command.contains("$tx/old.identity"))
        #expect(command.contains("du -sk \"$old\""))
        #expect(!command.contains("rm -r"))
        let response = "OLDMENU_RECLAIM_V1\nID=\(id.uuidString)\nOLD_SHA256=\(former)\nALLOCATED_KIB=41000\nEND\n"
        let bytes = try LegacyOldMenuReclaimCommands.parseInspection(Data(response.utf8),
            operationID: id, oldTreeSHA256: former)
        #expect(bytes == 41_000 * 1024)
        #expect(throws: (any Error).self) {
            try LegacyOldMenuReclaimCommands.parseInspection(Data(response.replacingOccurrences(
                of: "OLD_SHA256=\(former)", with: "OLD_SHA256=\(live)").utf8),
                operationID: id, oldTreeSHA256: former)
        }
    }
}

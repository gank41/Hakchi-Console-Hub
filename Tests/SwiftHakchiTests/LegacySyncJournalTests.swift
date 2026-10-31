import Foundation
import Testing
@testable import SwiftHakchi

struct LegacySyncJournalTests {
    private func record(_ id: UUID = UUID()) throws -> LegacySyncJournal {
        try LegacySyncJournal(operationID: id,
                              reviewSHA256: String(repeating: "a", count: 64),
                              archiveSHA256: String(repeating: "b", count: 64),
                              treeSHA256: String(repeating: "c", count: 64),
                              backupSHA256: String(repeating: "d", count: 64),
                              backupDirectory: URL(fileURLWithPath: "/tmp/verified-backup"),
                              stageDirectory: URL(fileURLWithPath: "/tmp/verified-stage"),
                              trialCode: "CLV-H-AAAAA", maximumGamesPerPage: 25,
                              archiveBytes: 8192)
    }

    @Test func journalPersistsEveryPhaseAndNeverRepeatsActivationIntent() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root)
        let first = try record()
        try await store.begin(first)
        #expect(try await store.load(first.operationID).phase == .prepared)
        try await store.advance(first.operationID, from: .prepared, to: .uploaded)
        try await store.advance(first.operationID, from: .uploaded, to: .verified)
        try await store.advance(first.operationID, from: .verified, to: .activationIntent)
        #expect(try await store.load(first.operationID).phase == .activationIntent)
        await #expect(throws: (any Error).self) {
            try await store.advance(first.operationID, from: .activationIntent, to: .activationIntent)
        }
        let reopened = LegacySyncJournalStore(directory: root)
        #expect(try await reopened.load(first.operationID).phase == .activationIntent)
        #expect(try await reopened.latestUnresolved()?.operationID == first.operationID)
        await #expect(throws: (any Error).self) { try await reopened.begin(try record()) }
    }

    @Test func uncertainStateBlocksNewWorkUntilReconciledTerminalState() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root)
        let first = try record()
        try await store.begin(first)
        try await store.advance(first.operationID, from: .prepared, to: .uploaded)
        try await store.advance(first.operationID, from: .uploaded, to: .verified)
        try await store.advance(first.operationID, from: .verified, to: .activationIntent)
        try await store.markUncertain(first.operationID)
        #expect(try await store.load(first.operationID).phase == .uncertain)
        await #expect(throws: (any Error).self) { try await store.begin(try record()) }
        try await store.advance(first.operationID, from: .uncertain, to: .accepted)
        #expect(try await store.latestUnresolved() == nil)
    }

    @Test func corruptedOrMismatchedJournalRefusesAllNewWork() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root)
        let first = try record()
        try await store.begin(first)
        let path = root.appendingPathComponent("nes-sync-\(first.operationID.uuidString).json")
        try Data("broken".utf8).write(to: path)
        await #expect(throws: (any Error).self) { try await store.begin(try record()) }
        await #expect(throws: (any Error).self) { try await store.load(first.operationID) }
    }

    @Test func malformedHashesNeverReachDisk() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try LegacySyncJournal(operationID: UUID(), reviewSHA256: "bad",
                                  archiveSHA256: String(repeating: "b", count: 64),
                                  treeSHA256: String(repeating: "c", count: 64),
                                  backupSHA256: String(repeating: "d", count: 64),
                                  backupDirectory: root, stageDirectory: root,
                                  trialCode: "CLV-H-AAAAA", maximumGamesPerPage: 25,
                                  archiveBytes: 8192)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func olderTrialRecordStillDecodesAndFullRecordReopensWithSelection() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try record()
        let legacyBytes = try JSONEncoder().encode(legacy)
        let oldObject = try #require(JSONSerialization.jsonObject(with: legacyBytes) as? [String: Any])
        #expect(oldObject["scope"] == nil)
        let decoded = try JSONDecoder().decode(LegacySyncJournal.self, from: legacyBytes)
        #expect(decoded.resolvedScope == .trial(code: "CLV-H-AAAAA"))

        let selected = ["CLV-H-AAAAA", "CLV-P-AAAAA"]
        let full = try LegacySyncJournal(operationID: UUID(),
            reviewSHA256: String(repeating: "a", count: 64),
            archiveSHA256: String(repeating: "b", count: 64),
            treeSHA256: String(repeating: "c", count: 64),
            backupSHA256: String(repeating: "d", count: 64),
            backupDirectory: URL(fileURLWithPath: "/tmp/verified-backup"),
            stageDirectory: URL(fileURLWithPath: "/tmp/verified-stage"),
            scope: .full, selectedCodes: selected,
            reviewedLocalCodes: ["CLV-H-AAAAA", "CLV-H-BBBBB"], consoleOrder: .releaseDate,
            maximumGamesPerPage: 25, archiveBytes: 8192)
        let fullObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        #expect(fullObject["trialCode"] == nil)
        let store = LegacySyncJournalStore(directory: root)
        try await store.begin(full)
        try await store.advance(full.operationID, from: .prepared, to: .uploaded)
        try await store.advance(full.operationID, from: .uploaded, to: .verified)
        let reopenedStore = LegacySyncJournalStore(directory: root)
        let reopened = try await reopenedStore.load(full.operationID)
        #expect(reopened.resolvedScope == .full)
        #expect(reopened.phase == .verified)
        #expect(reopened.selectedCodes == selected)
        #expect(reopened.reviewedLocalCodes == ["CLV-H-AAAAA", "CLV-H-BBBBB"])
        #expect(reopened.consoleOrder == .releaseDate)
        #expect(reopened.trialCode == nil)
        try await reopenedStore.advance(full.operationID, from: .verified, to: .activationIntent)
        try await reopenedStore.advance(full.operationID, from: .activationIntent, to: .activePendingAcceptance)
        try await reopenedStore.advance(full.operationID, from: .activePendingAcceptance, to: .accepted)
        #expect(try await reopenedStore.latestAcceptedFull()?.operationID == full.operationID)
    }

    @Test func invalidFullScopeCannotMasqueradeAsTrial() throws {
        #expect(throws: LegacySyncJournalError.self) {
            try LegacySyncJournal(operationID: UUID(),
                reviewSHA256: String(repeating: "a", count: 64),
                archiveSHA256: String(repeating: "b", count: 64),
                treeSHA256: String(repeating: "c", count: 64),
                backupSHA256: String(repeating: "d", count: 64),
                backupDirectory: URL(fileURLWithPath: "/tmp/verified-backup"),
                stageDirectory: URL(fileURLWithPath: "/tmp/verified-stage"),
                scope: .full, selectedCodes: ["CLV-H-AAAAA", "CLV-H-AAAAA"],
                consoleOrder: .title, maximumGamesPerPage: 25, archiveBytes: 8192)
        }
    }
}

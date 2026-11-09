import Foundation
import Darwin
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

private func candidateTestRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

struct LegacySyncJournalTests {
    @Test func independentStoresSerializeCompetingBegins() async throws {
        let parent = candidateTestRoot().appendingPathComponent("sync-store-race-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for index in 0..<20 {
            let root = parent.appendingPathComponent("case-\(index)")
            let first = LegacySyncJournalStore(directory: root), second = LegacySyncJournalStore(directory: root)
            let a = try record(), b = try record()
            let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                group.addTask { do { try await first.begin(a); return true } catch { return false } }
                group.addTask { do { try await second.begin(b); return true } catch { return false } }
                var count = 0
                for await result in group { if result { count += 1 } }
                return count
            }
            #expect(successes == 1)
            #expect(try await first.allRecords().count == 1)
        }
    }

    @Test func independentStoresSerializeConflictingPhaseChanges() async throws {
        let root = candidateTestRoot().appendingPathComponent("sync-store-race-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LegacySyncJournalStore(directory: root), second = LegacySyncJournalStore(directory: root)
        let item = try record()
        try await first.begin(item)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask { do { try await first.advance(item.operationID, from: .prepared, to: .uploaded); return true } catch { return false } }
            group.addTask { do { try await second.advance(item.operationID, from: .prepared, to: .discarded); return true } catch { return false } }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        #expect(successes == 1)
        let saved = try await first.load(item.operationID)
        #expect(saved.phase == .uploaded || saved.phase == .discarded)
    }

    @Test func bindAndAdvanceCannotLoseEitherJournalChange() async throws {
        let root = candidateTestRoot().appendingPathComponent("sync-store-race-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LegacySyncJournalStore(directory: root), second = LegacySyncJournalStore(directory: root)
        let item = try record(), fingerprint = String(repeating: "a", count: 64)
        try await first.begin(item)
        let digest = try item.identityReviewDigest()
        async let bound: Bool = { do { try first.bindReviewedIdentity(item.operationID, fingerprint: fingerprint, expectedRecordDigest: digest); return true } catch { return false } }()
        async let advanced: Bool = { do { try await second.advance(item.operationID, from: .prepared, to: .uploaded); return true } catch { return false } }()
        let results = await (bound, advanced)
        #expect(results.1)
        let saved = try await first.load(item.operationID)
        #expect(saved.phase == .uploaded)
        #expect(saved.effectiveChipIDFingerprint == (results.0 ? fingerprint : nil))
    }

    @Test func journalRootReplacementDuringMutationDoesNotWriteToReplacement() async throws {
        let base = candidateTestRoot().appendingPathComponent("sync-store-replace-" + UUID().uuidString)
        let root = base.appendingPathComponent("journals"), moved = base.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let initial = LegacySyncJournalStore(directory: root), item = try record()
        try await initial.begin(item)
        let replacing = LegacySyncJournalStore(directory: root, synchronize: { fd in
            do {
                try FileManager.default.moveItem(at: root, to: moved)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                return Darwin.fsync(fd)
            } catch { return -1 }
        })
        await #expect(throws: (any Error).self) { try await replacing.advance(item.operationID, from: .prepared, to: .uploaded) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let preserved = LegacySyncJournalStore(directory: moved)
        #expect(try await preserved.load(item.operationID).phase == .prepared)
    }

    @Test func journalSyncFailurePreservesPriorPhase() async throws {
        let root = candidateTestRoot().appendingPathComponent("sync-store-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = LegacySyncJournalStore(directory: root), item = try record()
        try await good.begin(item)
        let failing = LegacySyncJournalStore(directory: root, synchronize: { _ in -1 })
        await #expect(throws: (any Error).self) { try await failing.advance(item.operationID, from: .prepared, to: .uploaded) }
        #expect(try await good.load(item.operationID).phase == .prepared)
    }

    @Test func journalCreationDoesNotFollowLinkedAncestor() async throws {
        let base = candidateTestRoot().appendingPathComponent("sync-store-link-" + UUID().uuidString)
        let outside = base.appendingPathComponent("outside"), link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = LegacySyncJournalStore(directory: link.appendingPathComponent("new/journals"))
        await #expect(throws: (any Error).self) { try await store.begin(try record()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func journalCreationRetrySynchronizesPreviouslyCreatedParent() async throws {
        let base = candidateTestRoot().appendingPathComponent("sync-store-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("new/journals"), marker = base.appendingPathComponent("parent-was-synced")
        let failing = LegacySyncJournalStore(directory: root, synchronize: { fd in
            var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &bytes) == 0 else { return -1 }
            if String(cString: bytes) == base.path { return -1 }
            return Darwin.fsync(fd)
        })
        let item = try record()
        await #expect(throws: (any Error).self) { try await failing.begin(item) }
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("new").path))
        let retry = LegacySyncJournalStore(directory: root, synchronize: { fd in
            var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &bytes) == 0 else { return -1 }
            if String(cString: bytes) == base.path {
                guard FileManager.default.createFile(atPath: marker.path, contents: Data()) else { return -1 }
            }
            return Darwin.fsync(fd)
        })
        try await retry.begin(item)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try await retry.load(item.operationID).phase == .prepared)
    }
    @Test func acceptedHistoryIsSelectedForTheConnectedConsole() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LegacySyncJournalStore(directory: root)
        let firstID = String(repeating: "1", count: 32)
        let secondID = String(repeating: "2", count: 32)
        func fullRecord(_ chipID: String?) throws -> LegacySyncJournal {
            try LegacySyncJournal(operationID: UUID(), reviewSHA256: String(repeating: "a", count: 64),
                archiveSHA256: String(repeating: "b", count: 64), treeSHA256: String(repeating: "c", count: 64),
                backupSHA256: String(repeating: "d", count: 64),
                backupDirectory: root.appendingPathComponent("backup"), stageDirectory: root.appendingPathComponent("stage"),
                scope: .full, selectedCodes: ["CLV-P-AAAAA"], consoleOrder: .title,
                maximumGamesPerPage: 25, archiveBytes: 8192,
                chipIDFingerprint: chipID.map { BackupManifest.digest(Data($0.utf8)) })
        }
        func accept(_ record: LegacySyncJournal) async throws {
            try await store.begin(record)
            try await store.advance(record.operationID, from: .prepared, to: .uploaded)
            try await store.advance(record.operationID, from: .uploaded, to: .verified)
            try await store.advance(record.operationID, from: .verified, to: .activationIntent)
            try await store.advance(record.operationID, from: .activationIntent, to: .activePendingAcceptance)
            try await store.advance(record.operationID, from: .activePendingAcceptance, to: .accepted)
        }
        let first = try fullRecord(firstID)
        try await accept(first)
        let second = try fullRecord(secondID)
        try await accept(second)
        let legacy = try fullRecord(nil)
        try await accept(legacy)
        #expect(try await store.latestAcceptedMenu(matchingChipID: firstID)?.operationID == first.operationID)
        #expect(try await store.latestAcceptedMenu(matchingChipID: secondID)?.operationID == second.operationID)
        #expect(try await store.latestAcceptedFull(matchingChipID: firstID)?.operationID == first.operationID)
        #expect(try await store.latestAcceptedFull(matchingFingerprint: BackupManifest.digest(Data(firstID.utf8)))?.operationID == first.operationID)
        #expect(try await store.latestAcceptedFull(matchingFingerprint: nil) == nil)
        #expect(try await store.latestAcceptedFull(matchingFingerprint: String(repeating: "f", count: 64)) == nil)
        #expect(try await store.latestAcceptedMenu(matchingChipID: String(repeating: "3", count: 32))?.operationID == nil)
        await #expect(throws: (any Error).self) { _ = try await store.latestAcceptedMenu(matchingChipID: "invalid") }
    }
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

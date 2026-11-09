import Foundation
import Darwin
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESDataRestoreJournalTests {
    @Test(arguments: ["SNESLibrarySync-", "SNESSaveTransfer-", "SNESDataRestore-", "unknown-"])
    func conflictCheckRunsWithoutAConsoleBackup(_ prefix: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RestoreJournalStorage(root: root)
        defer { try? storage.closeLease() }
        try SNESDataRestoreJournal.checkOthers(storage, excluding: nil)
        let operationName = prefix + UUID().uuidString
        try FileManager.default.createDirectory(at: root.appendingPathComponent(operationName), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try SNESDataRestoreJournal.checkOthers(storage, excluding: nil) }
        try SNESDataRestoreJournal.checkOthers(storage, excluding: operationName)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func intentSurvivesReopenAndCannotBeRepeated() async throws {
        let original = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        let backup = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: original, to: source)
        try FileManager.default.copyItem(at: original, to: backup)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["fixture"] = "independent test copy"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL)
        let binding = try JSONDecoder().decode(SNESDataSnapshotResult.Manifest.self, from: Data(contentsOf: manifestURL)).binding
        let a = try SNESDataSnapshotPackage.load(directory: source, expectedHWID: binding.expectedHWID)
        let b = try SNESDataSnapshotPackage.load(directory: backup, expectedHWID: binding.expectedHWID)
        let journalRoot = root.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let prepared = try SNESDataRestoreJournal.prepare(source: a, preWriteBackup: b, root: journalRoot)
        let journal = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        #expect(try await journal.phase() == .needsReview)
        try await journal.recordWriteIntent(capability: prepared.capability)
        try await journal.close()
        let reopened = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        #expect(try await reopened.phase() == .writeIntent)
        await #expect(throws: (any Error).self) { try await reopened.recordWriteIntent() }
        try await reopened.close()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil), arguments: ["sync", "wrongReview", "mutatedSnapshot", "sameSnapshot", "preparationSync", "finalDirectorySync", "finalRootSync", "intentDeletion", "mutatedPrepared", "mutatedIntent", "replacedOperation", "otherOperationBeforePrepare", "otherOperationBeforeIntent"])
    func refusalsKeepUncertainWorkFromBeingRetried(_ scenario: String) async throws {
        let original = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        let backup = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: original, to: source)
        try FileManager.default.copyItem(at: original, to: backup)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["fixture"] = "independent test copy"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL)
        let binding = try JSONDecoder().decode(SNESDataSnapshotResult.Manifest.self, from: Data(contentsOf: manifestURL)).binding
        let a = try SNESDataSnapshotPackage.load(directory: source, expectedHWID: binding.expectedHWID)
        let b = try SNESDataSnapshotPackage.load(directory: backup, expectedHWID: binding.expectedHWID)
        let journalRoot = root.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if scenario == "otherOperationBeforePrepare" {
            let other = journalRoot.appendingPathComponent("SNESLibrarySync-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try SNESDataRestoreJournal.prepare(source: a, preWriteBackup: b, root: journalRoot) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: journalRoot.path).filter { $0.hasPrefix("SNESDataRestore-") }.isEmpty)
            return
        }
        if scenario == "sameSnapshot" {
            #expect(throws: (any Error).self) { try SNESDataRestoreJournal.prepare(source: a, preWriteBackup: a, root: journalRoot) }
            return
        }
        if scenario == "preparationSync" {
            #expect(throws: (any Error).self) {
                try SNESDataRestoreJournal.prepare(source: a, preWriteBackup: b, root: journalRoot, synchronize: { fd in
                    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    guard fcntl(fd, F_GETPATH, &path) == 0 else { return -1 }
                    return String(cString: path).hasSuffix("/0000.json") ? -1 : Darwin.fsync(fd)
                })
            }
            let name = try #require(FileManager.default.contentsOfDirectory(atPath: journalRoot.path).first { $0.hasPrefix("SNESDataRestore-") })
            let operation = journalRoot.appendingPathComponent(name)
            let review = BackupManifest.digest(try Data(contentsOf: operation.appendingPathComponent("plan.json")))
            #expect(throws: (any Error).self) { try SNESDataRestoreJournal(operation: operation, reviewSHA256: review) }
            return
        }
        if scenario == "finalDirectorySync" || scenario == "finalRootSync" {
            #expect(throws: (any Error).self) {
                try SNESDataRestoreJournal.prepare(source: a, preWriteBackup: b, root: journalRoot, synchronize: { fd in
                    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    guard fcntl(fd, F_GETPATH, &path) == 0 else { return -1 }
                    let current = String(cString: path)
                    let operations = (try? FileManager.default.contentsOfDirectory(atPath: journalRoot.path)) ?? []
                    let published = operations.contains { name in
                        FileManager.default.fileExists(atPath: journalRoot.appendingPathComponent(name).appendingPathComponent("preparation.complete").path)
                    }
                    var info = stat()
                    guard fstat(fd, &info) == 0 else { return -1 }
                    let leaf = URL(fileURLWithPath: current).lastPathComponent
                    let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                    let isTarget = isDirectory && (scenario == "finalRootSync" ? leaf == "journals" : leaf.hasPrefix("SNESDataRestore-"))
                    return published && isTarget ? -1 : Darwin.fsync(fd)
                })
            }
            let name = try #require(FileManager.default.contentsOfDirectory(atPath: journalRoot.path).first { $0.hasPrefix("SNESDataRestore-") })
            let operation = journalRoot.appendingPathComponent(name)
            let review = BackupManifest.digest(try Data(contentsOf: operation.appendingPathComponent("plan.json")))
            let reopened = try SNESDataRestoreJournal(operation: operation, reviewSHA256: review)
            #expect(try await reopened.phase() == .needsReview)
            await #expect(throws: (any Error).self) { try await reopened.recordWriteIntent() }
            try await reopened.close()
            return
        }
        let prepared = try SNESDataRestoreJournal.prepare(source: a, preWriteBackup: b, root: journalRoot)
        if scenario == "otherOperationBeforeIntent" {
            let journal = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
            let other = journalRoot.appendingPathComponent("SNESSaveTransfer-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            await #expect(throws: (any Error).self) { try await journal.recordWriteIntent(capability: prepared.capability) }
            #expect(!FileManager.default.fileExists(atPath: prepared.operation.appendingPathComponent("0001.json").path))
            try FileManager.default.removeItem(at: other)
            await #expect(throws: (any Error).self) { try await journal.recordWriteIntent(capability: prepared.capability) }
            #expect(!FileManager.default.fileExists(atPath: prepared.operation.appendingPathComponent("0001.json").path))
            try await journal.close()
            return
        }
        if scenario == "replacedOperation" {
            let originalOperation = root.appendingPathComponent("displaced-operation")
            try FileManager.default.moveItem(at: prepared.operation, to: originalOperation)
            try FileManager.default.copyItem(at: originalOperation, to: prepared.operation)
            let reopened = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
            await #expect(throws: (any Error).self) { try await reopened.recordWriteIntent(capability: prepared.capability) }
            #expect(!FileManager.default.fileExists(atPath: prepared.operation.appendingPathComponent("0001.json").path))
            try await reopened.close()
            try FileManager.default.moveItem(at: prepared.operation, to: root.appendingPathComponent("replacement-copy"))
            try FileManager.default.moveItem(at: originalOperation, to: prepared.operation)
            let restored = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
            await #expect(throws: (any Error).self) { try await restored.recordWriteIntent(capability: prepared.capability) }
            #expect(!FileManager.default.fileExists(atPath: prepared.operation.appendingPathComponent("0001.json").path))
            try await restored.close()
            return
        }
        if scenario == "mutatedPrepared" || scenario == "mutatedIntent" {
            let journal = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
            if scenario == "mutatedIntent" { try await journal.recordWriteIntent(capability: prepared.capability) }
            let name = scenario == "mutatedPrepared" ? "0000.json" : "0001.json"
            let recordURL = prepared.operation.appendingPathComponent(name)
            var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            record["unexpectedField"] = "tampered"
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: recordURL)
            if scenario == "mutatedPrepared" {
                await #expect(throws: (any Error).self) { try await journal.recordWriteIntent(capability: prepared.capability) }
            }
            try await journal.close()
            #expect(throws: (any Error).self) { try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256) }
            return
        }
        if scenario == "intentDeletion" {
            let journal = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
            try await journal.recordWriteIntent(capability: prepared.capability)
            try await journal.close()
            try FileManager.default.removeItem(at: prepared.operation.appendingPathComponent("0001.json"))
            let reopened = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
            #expect(try await reopened.phase() == .needsReview)
            await #expect(throws: (any Error).self) { try await reopened.recordWriteIntent() }
            await #expect(throws: (any Error).self) { try await reopened.recordWriteIntent(capability: prepared.capability) }
            try await reopened.close()
            return
        }
        if scenario == "wrongReview" {
            #expect(throws: (any Error).self) { try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: String(repeating: "0", count: 64)) }
            return
        }
        if scenario == "mutatedSnapshot" {
            try Data("corrupted".utf8).write(to: manifestURL)
            #expect(throws: (any Error).self) { try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256) }
            return
        }
        let failing = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, synchronize: { _ in -1 })
        await #expect(throws: (any Error).self) { try await failing.recordWriteIntent(capability: prepared.capability) }
        try await failing.close()
        let reopened = try SNESDataRestoreJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        #expect(try await reopened.phase() == .writeIntent)
        await #expect(throws: (any Error).self) { try await reopened.recordWriteIntent() }
        await #expect(throws: (any Error).self) { try await reopened.recordWriteIntent(capability: prepared.capability) }
        try await reopened.close()
    }

}

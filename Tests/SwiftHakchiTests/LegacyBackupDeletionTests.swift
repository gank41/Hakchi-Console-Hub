import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

struct LegacyBackupDeletionTests {
    @Test func trashRemovesOnlyTheReviewedUnreferencedBackup() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let selected = try fixture(in: workspace.backups)
        let other = try fixture(in: workspace.backups)
        let service = LegacyBackupDeletion(workspace: workspace)

        let preview = try await service.preview(directory: selected)
        #expect(preview.isEligible)
        let trashed = try await service.moveToTrash(preview: preview)
        defer { try? FileManager.default.removeItem(at: trashed) }

        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func changedOrUnexpectedBackupCannotBeRemoved() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let selected = try fixture(in: workspace.backups)
        let service = LegacyBackupDeletion(workspace: workspace)
        let preview = try await service.preview(directory: selected)
        try Data("unexpected".utf8).write(to: selected.appendingPathComponent("notes.txt"))

        await #expect(throws: (any Error).self) {
            try await service.moveToTrash(preview: preview)
        }
        #expect(FileManager.default.fileExists(atPath: selected.path))
    }

    @Test func symlinkAndHardLinkAreRefused() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let target = try fixture(in: workspace.backups)
        let link = workspace.backups.appendingPathComponent("LegacyInspection-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let service = LegacyBackupDeletion(workspace: workspace)

        await #expect(throws: (any Error).self) {
            try await service.preview(directory: link)
        }
        let hardLink = root.appendingPathComponent("hard-linked.tar")
        try FileManager.default.linkItem(at: target.appendingPathComponent("console.tar"), to: hardLink)
        await #expect(throws: (any Error).self) {
            try await service.preview(directory: target)
        }
    }

    @Test func journalReferencedBackupCannotBeRemoved() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let selected = try fixture(in: workspace.backups)
        let hash = String(repeating: "a", count: 64)
        let record = try LegacySyncJournal(operationID: UUID(), reviewSHA256: hash,
            archiveSHA256: hash, treeSHA256: hash, backupSHA256: hash,
            backupDirectory: selected,
            stageDirectory: root.appendingPathComponent("Stages/Trial"),
            trialCode: "CLV-H-AAAAA", maximumGamesPerPage: 30, archiveBytes: 1024)
        try await LegacySyncJournalStore(directory: workspace.journals).begin(record)
        let service = LegacyBackupDeletion(workspace: workspace)

        let preview = try await service.preview(directory: selected)
        #expect(!preview.isEligible)
        await #expect(throws: (any Error).self) {
            try await service.deletePermanently(preview: preview)
        }
        #expect(FileManager.default.fileExists(atPath: selected.path))
    }

    @Test func permanentDeletionLeavesCompletedIntentAndOnlyRemovesSelectedFolder() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspacePaths(root: root)
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let selected = try fixture(in: workspace.backups)
        let other = try fixture(in: workspace.backups)
        let service = LegacyBackupDeletion(workspace: workspace)

        let preview = try await service.preview(directory: selected)
        try await service.deletePermanently(preview: preview)

        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        let files = try FileManager.default.contentsOfDirectory(at: workspace.journals,
            includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(String(data: try Data(contentsOf: files[0]), encoding: .utf8)?.contains("completed") == true)
    }

    private func fixture(in backups: URL) throws -> URL {
        let directory = backups.appendingPathComponent("LegacyInspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let archive = Data(repeating: 0, count: 1024)
        try archive.write(to: directory.appendingPathComponent("console.tar"))
        let manifest: [String: Any] = [
            "formatVersion": 1, "createdAt": "2026-10-19T12:00:00Z",
            "byteCount": archive.count, "sha256": BackupManifest.digest(archive),
            "scope": "Original games and saves", "eligibleForAutomaticRestore": false,
            "deviceIdentityVerified": false, "archiveFilename": "console.tar"
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}

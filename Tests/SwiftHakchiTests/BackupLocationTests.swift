import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

struct BackupLocationTests {
    @Test func backupCreationPreferencesMigrateAndRoundTrip() throws {
        let migrated = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(migrated.automaticallyCreateMissingBackup)
        #expect(migrated.showBackupExplanation)
        migrated.automaticallyCreateMissingBackup = false
        migrated.showBackupExplanation = false
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(migrated))
        #expect(!decoded.automaticallyCreateMissingBackup)
        #expect(!decoded.showBackupExplanation)
    }

    @Test func changingWorkspaceKeepsEarlierDefaultBackupFolderInHistory() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig()
        config.workspacePath = root.appendingPathComponent("First").path
        let previous = config.workspace.backups

        config.setWorkspace(root.appendingPathComponent("Second"))

        #expect(config.workspace.root.lastPathComponent == "Second")
        #expect(config.workspace.knownBackupRoots.map(\.path).contains(previous.path))
    }
    @Test func changingBackupFolderKeepsWorkspaceAndEarlierHistory() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Backups", isDirectory: true)
        let chosen = root.appendingPathComponent("Selected Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let config = AppConfig()
        config.workspacePath = root.path

        try config.setBackupDirectory(chosen)

        #expect(config.workspace.root.path == root.standardizedFileURL.path)
        #expect(config.workspace.backups.path == chosen.standardizedFileURL.path)
        #expect(config.workspace.knownBackupRoots.map(\.path).contains(original.standardizedFileURL.path))
        #expect(config.workspace.containsBackup(original.appendingPathComponent("LegacyInspection-old")))
        #expect(config.workspace.containsBackup(chosen.appendingPathComponent("LegacyInspection-new")))
    }

    @Test func absentOrSymlinkedDestinationIsRefused() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig()
        config.workspacePath = root.path
        let absent = root.appendingPathComponent("Missing")
        #expect(throws: (any Error).self) { try config.setBackupDirectory(absent) }
        let real = root.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: (any Error).self) { try config.setBackupDirectory(link) }
    }

    @Test func preferenceRoundTripPreservesOldFolders() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let config = AppConfig()
        config.workspacePath = root.path
        try config.setBackupDirectory(first)
        try config.setBackupDirectory(second)
        let file = root.appendingPathComponent("config.json")
        config.save(to: file)

        let loaded = AppConfig.load(from: file)

        #expect(loaded.workspace.backups.path == second.standardizedFileURL.path)
        #expect(loaded.workspace.knownBackupRoots.map(\.path).contains(first.standardizedFileURL.path))
        #expect(loaded.workspace.knownBackupRoots.map(\.path).contains(root.appendingPathComponent("Backups").path))
    }

    @Test func selectedFolderThatDisappearsDoesNotFallBackToWorkspace() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = root.appendingPathComponent("External Backups")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        let config = AppConfig()
        config.workspacePath = root.path
        try config.setBackupDirectory(chosen)
        try FileManager.default.removeItem(at: chosen)

        #expect(throws: (any Error).self) { try config.workspace.requireActiveBackupsAvailable() }
        #expect(config.workspace.backups.path == chosen.path)
    }
}

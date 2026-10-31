import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

struct LegacyBackupHistoryTests {
    @Test func verifiedInspectionBackupIsVisibleButNotRestorable() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = try fixture(in: root, name: "LegacyInspection-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")

        let entries = LegacyBackupHistory.scan(backups: root)

        #expect(entries.count == 1)
        #expect(entries[0].directory == backup)
        #expect(entries[0].status == .verifiedInspection)
        #expect(entries[0].byteCount == 1024)
    }

    @Test func changedArchiveAndSymlinkedDirectoryCannotLookVerified() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = try fixture(in: root, name: "LegacyInspection-BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        try Data(repeating: 1, count: 1024).write(to: changed.appendingPathComponent("console.tar"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("LegacyInspection-CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),
            withDestinationURL: changed)

        let entries = LegacyBackupHistory.scan(backups: root)

        #expect(entries.count == 2)
        #expect(entries.allSatisfy { if case .invalid = $0.status { return true }; return false })
    }

    @Test func scansCurrentAndPreviousLocationsWithoutCollapsingMatchingNames() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Current", isDirectory: true)
        let previous = root.appendingPathComponent("Previous", isDirectory: true)
        let absent = root.appendingPathComponent("Unmounted", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
        let name = "LegacyInspection-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let currentBackup = try fixture(in: current, name: name)
        let previousBackup = try fixture(in: previous, name: name)

        let entries = LegacyBackupHistory.scan(roots: [current, previous, absent, current])

        #expect(entries.count == 2)
        #expect(Set(entries.map(\.directory)) == Set([currentBackup, previousBackup]))
        #expect(entries.first(where: { $0.directory == currentBackup })?.sourceRoot == current)
        #expect(entries.first(where: { $0.directory == previousBackup })?.sourceRoot == previous)
    }

    private func fixture(in root: URL, name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let bytes = Data(repeating: 0, count: 1024)
        try bytes.write(to: directory.appendingPathComponent("console.tar"))
        let manifest: [String: Any] = [
            "formatVersion": 1,
            "createdAt": "2026-10-19T12:00:00Z",
            "byteCount": bytes.count,
            "sha256": BackupManifest.digest(bytes),
            "scope": "Original games and saves",
            "eligibleForAutomaticRestore": false,
            "deviceIdentityVerified": false,
            "archiveFilename": "console.tar"
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}

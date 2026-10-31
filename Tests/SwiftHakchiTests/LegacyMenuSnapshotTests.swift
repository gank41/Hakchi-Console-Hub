import Foundation
import SWCompression
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

struct LegacyMenuSnapshotTests {
    fileprivate let chipID = "0123456789abcdef0123456789abcdef"

    @Test func validSnapshotIsSelectableAndBoundToItsConsole() throws {
        let (root, backup) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try LegacyMenuSnapshot.record(directory: backup, chipID: chipID)
        let verified = try LegacyMenuSnapshot.verify(directory: backup, expectedChipID: chipID)
        #expect(verified.menuTreeSHA256 == saved.menuTreeSHA256)
        #expect(verified.entries.count == 3)
        #expect(LegacyBackupHistory.scan(backups: root).first?.status == .restorable)
        #expect(throws: (any Error).self) {
            try LegacyMenuSnapshot.verify(directory: backup,
                expectedChipID: "fedcba9876543210fedcba9876543210")
        }
    }

    @Test func changedArchiveOrFalseManifestClaimCannotRestore() throws {
        let (root, backup) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LegacyMenuSnapshot.record(directory: backup, chipID: chipID)
        let archive = backup.appendingPathComponent("console.tar")
        var bytes = try Data(contentsOf: archive)
        bytes[512] ^= 1
        try bytes.write(to: archive)
        #expect(throws: (any Error).self) {
            try LegacyMenuSnapshot.verify(directory: backup, expectedChipID: chipID)
        }
        #expect(LegacyBackupHistory.scan(backups: root).first?.status != .restorable)
    }

    @Test func oldInspectionBackupDoesNotBecomeSelectable() throws {
        let (root, backup) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try LegacyMenuSnapshot.verify(directory: backup, expectedChipID: chipID)
        }
        #expect(LegacyBackupHistory.scan(backups: root).first?.status == .verifiedInspection)
    }

    fileprivate func fixture() throws -> (URL, URL) {
        let root = try testDirectory()
        let backup = root.appendingPathComponent("LegacyInspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let archive = backup.appendingPathComponent("console.tar")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        var writer = SWCompression.TarWriter(fileHandle: handle, force: .ustar)
        for name in ["var/lib/hakchi/games/nes/000", "var/lib/hakchi/games/nes/000/CLV-H-AAAAA"] {
            var info = TarEntryInfo(name: name, type: .directory)
            info.permissions = Permissions(rawValue: 0o755)
            try writer.append(TarEntry(info: info, data: nil))
        }
        var info = TarEntryInfo(name: "var/lib/hakchi/games/nes/000/CLV-H-AAAAA/CLV-H-AAAAA.desktop", type: .regular)
        info.permissions = Permissions(rawValue: 0o644)
        try writer.append(TarEntry(info: info, data: Data("[Desktop Entry]\nName=Test\n".utf8)))
        try writer.finalize(); try handle.close()
        let bytes = try Data(contentsOf: archive)
        let report = LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
            scriptVersion: "[master]v1.0.3-110(7f31082)",
            activePage: LegacyConsoleReport.gameRoot + "/000", freeBytes: 170_000_000,
            savesPath: "/var/lib/clover/profiles/0", stockCodes: [], visibleCodes: ["CLV-H-AAAAA"])
        let object: [String: Any] = ["formatVersion": 1, "createdAt": "2026-10-19T12:00:00Z",
            "byteCount": bytes.count, "sha256": BackupManifest.digest(bytes),
            "scope": "Console inspection", "eligibleForAutomaticRestore": false,
            "deviceIdentityVerified": false, "archiveFilename": "console.tar",
            "observedReport": try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))]
        try JSONSerialization.data(withJSONObject: object).write(to: backup.appendingPathComponent("manifest.json"))
        return (root, backup)
    }
}

struct LegacySavedMenuStageTests {
    @Test func unsafeMenuPathsAndDuplicatesAreRejectedBeforeExtraction() throws {
        let prefix = LegacyMenuSnapshot.menuRoot + "/"
        var traversal = TarWriter()
        traversal.addDirectory(name: prefix + "000")
        traversal.addFile(name: prefix + "000/../escape", contents: Data([1]))
        #expect(throws: (any Error).self) {
            try LegacyMenuSnapshot.inventory(traversal.finalize())
        }

        var duplicates = TarWriter()
        duplicates.addDirectory(name: prefix + "000")
        duplicates.addDirectory(name: prefix + "000/CLV-H-AAAAA")
        duplicates.addFile(name: prefix + "000/CLV-H-AAAAA/game.nes", contents: Data([1]))
        duplicates.addFile(name: prefix + "000/CLV-H-AAAAA/GAME.nes", contents: Data([2]))
        #expect(throws: (any Error).self) {
            try LegacyMenuSnapshot.inventory(duplicates.finalize())
        }

        var missingFirstPage = TarWriter()
        missingFirstPage.addDirectory(name: prefix + "001")
        #expect(throws: (any Error).self) {
            try LegacyMenuSnapshot.inventory(missingFirstPage.finalize())
        }

        var absolute = TarWriter()
        absolute.addDirectory(name: "/" + prefix + "000")
        #expect(throws: (any Error).self) {
            try LegacyMenuSnapshot.inventory(absolute.finalize())
        }
    }

    @Test func escapingFactoryLinkIsRejectedBeforeExtraction() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("unsafe.tar")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        var writer = SWCompression.TarWriter(fileHandle: handle, force: .ustar)
        var page = TarEntryInfo(name: LegacyMenuSnapshot.menuRoot + "/000", type: .directory)
        page.permissions = Permissions(rawValue: 0o755)
        try writer.append(TarEntry(info: page, data: nil))
        var game = TarEntryInfo(name: LegacyMenuSnapshot.menuRoot + "/000/CLV-P-AAAAA", type: .directory)
        game.permissions = Permissions(rawValue: 0o755)
        try writer.append(TarEntry(info: game, data: nil))
        var link = TarEntryInfo(name: LegacyMenuSnapshot.menuRoot + "/000/CLV-P-AAAAA/CLV-P-AAAAA.nes", type: .symbolicLink)
        link.linkName = "/tmp/not-a-factory-game"
        try writer.append(TarEntry(info: link, data: nil))
        try writer.finalize(); try handle.close()
        #expect(throws: (any Error).self) {
            try LegacyMenuSnapshot.inventory(Data(contentsOf: archive))
        }
    }

    @Test func optionalCapturedArchiveInventory() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_ARCHIVE"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let entries = try LegacyMenuSnapshot.inventory(data)
        #expect(entries.count > 30)
        #expect(entries.contains { $0.relativePath == "000" })
    }

    @Test func savedArchiveBuildsAnExactInactiveMenu() throws {
        let fixtures = LegacyMenuSnapshotTests()
        let (root, backup) = try fixtures.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try LegacyMenuSnapshot.record(directory: backup, chipID: fixtures.chipID)
        let stages = root.appendingPathComponent("Stages")

        let stage = try LegacySavedMenuStage.build(snapshotDirectory: backup,
            expectedChipID: fixtures.chipID, in: stages)

        #expect(stage.treeSHA256 == saved.menuTreeSHA256)
        #expect(stage.entries.count == saved.entries.count)
        #expect(try Data(contentsOf: stage.menuDirectory.appendingPathComponent(
            "000/CLV-H-AAAAA/CLV-H-AAAAA.desktop")) == Data("[Desktop Entry]\nName=Test\n".utf8))
        #expect(stage.archiveBytes > 0)
        #expect(try LegacySyncPlan.SourceFile.capture(stage.archiveURL).sha256 == stage.archiveSHA256)
    }

    @Test func wrongConsoleAndChangedSnapshotNeverCreateStage() throws {
        let fixtures = LegacyMenuSnapshotTests()
        let (root, backup) = try fixtures.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LegacyMenuSnapshot.record(directory: backup, chipID: fixtures.chipID)
        let stages = root.appendingPathComponent("Stages")
        #expect(throws: (any Error).self) {
            try LegacySavedMenuStage.build(snapshotDirectory: backup,
                expectedChipID: "fedcba9876543210fedcba9876543210", in: stages)
        }
        #expect(!FileManager.default.fileExists(atPath: stages.path))
        var data = try Data(contentsOf: backup.appendingPathComponent("console.tar"))
        data[512] ^= 1
        try data.write(to: backup.appendingPathComponent("console.tar"))
        #expect(throws: (any Error).self) {
            try LegacySavedMenuStage.build(snapshotDirectory: backup,
                expectedChipID: fixtures.chipID, in: stages)
        }
    }
}

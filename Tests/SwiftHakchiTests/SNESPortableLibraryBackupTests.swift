import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct SNESPortableLibraryBackupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_PORTABLE_BACKUP"] != nil))
    func existingLibraryBackupCanBeCopiedAndReopenedWithoutAConsole() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_PORTABLE_BACKUP"])
        let source = try SNESLibraryBackup.open(directory: URL(fileURLWithPath: path))
        let destination = try testDirectory(); defer { try? FileManager.default.removeItem(at: destination) }
        let copy = try SNESPortableLibraryBackup.copy(source.directory, to: destination)
        let reopened = try SNESLibraryBackup.open(directory: copy)
        #expect(reopened.manifestSHA256 == source.manifestSHA256)
        #expect(reopened.inventory.snapshotSHA256 == source.inventory.snapshotSHA256)
        try source.validate(); try reopened.validate()
    }
    @Test func portableCopyKeepsAddedGameObjectsAndSavedProgress() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (library, originals) = try fixture.fixture(root)
        let menu = try fixture.menu(library, originals)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        for directory in [source, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let save = "clover/profiles/0/CLV-U-A0001/cartridge.sram"
        let backup = try await SNESLibraryRestoreTests().backup(source, originals: originals, menu: menu, profileFiles: [save: Data([1, 2, 3])])
        let objects = backup.inventory.files.filter { $0.path.hasPrefix("objects/") }
        #expect(!objects.isEmpty)
        let expected = try objects.map { ($0.path, try backup.read(path: $0.path)) }
        let copied = try SNESPortableLibraryBackup.copy(backup.directory, to: target)
        try FileManager.default.removeItem(at: source)
        let reopened = try SNESLibraryBackup.open(directory: copied)
        #expect(try reopened.read(path: save) == Data([1, 2, 3]))
        for (path, bytes) in expected { #expect(try reopened.read(path: path) == bytes) }
        let targetID = String(repeating: "2", count: 32), sourceBinding = originalGamesBinding()
        let targetBinding = SNESRuntimeBinding(sourceSnapshot: sourceBinding.sourceSnapshot,
            setupManifestSHA256: sourceBinding.setupManifestSHA256, expectedHWID: targetID)
        var frame = originalGamesFrameFixture()
        let sourceHeader = Data(("HWID " + sourceBinding.expectedHWID).utf8)
        frame.replaceSubrange(try #require(frame.range(of: sourceHeader)), with: Data(("HWID " + targetID).utf8))
        let targetOriginals = try SNESOriginalGamesFrame(frame, binding: targetBinding, challenge: originalGamesChallenge)
        let review = try SNESLibraryRestore.prepareReplacement(backup: reopened, originals: targetOriginals, destinationHWID: targetID)
        #expect(try #require(review.menu).objects == menu.objects)
        #expect(try review.readSave(path: save) == Data([1, 2, 3]))
    }
    @Test func copyCanBeImportedAndVerifiedOnAnotherMacWithoutTheOriginal() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source"), portableRoot = root.appendingPathComponent("portable"), targetRoot = root.appendingPathComponent("target")
        for dir in [sourceRoot, portableRoot, targetRoot] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let fixture = SNESLibraryInventoryTests(), challenge = UUID()
        let inventory = try fixture.parse(fixture.frame(challenge: challenge), challenge: challenge)
        let original = try await SNESLibraryBackup.capture(inventory: inventory, root: sourceRoot,
            read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        let exported = try SNESPortableLibraryBackup.copy(original.directory, to: portableRoot)
        // A file transfer may change permissions. The import recreates private
        // files on the destination and verifies their content again.
        for directory in [exported, exported.appendingPathComponent("data-0")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        for file in [exported.appendingPathComponent("manifest.json"), exported.appendingPathComponent("data-0/file-0000.bin")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        try FileManager.default.removeItem(at: sourceRoot)
        let imported = try SNESPortableLibraryBackup.copy(exported, to: targetRoot)
        let reopened = try SNESLibraryBackup.open(directory: imported)
        #expect(reopened.manifestSHA256 == original.manifestSHA256)
        #expect(try reopened.read(path: "clover/settings.json") == Data("{}".utf8))
    }

    @Test(arguments: ["changed", "link", "existing"])
    func refusesDamagedOrConflictingCopiesWithoutReplacingAnything(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source"), targetRoot = root.appendingPathComponent("target")
        for dir in [sourceRoot, targetRoot] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let fixture = SNESLibraryInventoryTests(), challenge = UUID()
        let inventory = try fixture.parse(fixture.frame(challenge: challenge), challenge: challenge)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: sourceRoot,
            read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        let payload = backup.directory.appendingPathComponent("data-0/file-0000.bin")
        if fault == "changed" { try Data("[]".utf8).write(to: payload) }
        if fault == "link" {
            try FileManager.default.removeItem(at: payload)
            try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: backup.directory.appendingPathComponent("manifest.json"))
        }
        let existing = targetRoot.appendingPathComponent(backup.directory.lastPathComponent)
        if fault == "existing" { try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true) }
        #expect(throws: (any Error).self) { try SNESPortableLibraryBackup.copy(backup.directory, to: targetRoot) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: targetRoot.path) == (fault == "existing" ? [existing.lastPathComponent] : []))
    }
}

import Foundation
import Darwin
import Testing
@testable import SwiftHakchi

@MainActor struct SNESPortableLibraryBackupTests {
    @Test(arguments: ["file", "group", "output", "staging", "destination"])
    func copyReportsFailedDurabilityWithoutDamagingTheOriginal(_ point: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        for directory in [sourceRoot, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let fixture = SNESLibraryInventoryTests(), challenge = UUID()
        let inventory = try fixture.parse(fixture.frame(challenge: challenge), challenge: challenge)
        let source = try await SNESLibraryBackup.capture(inventory: inventory, root: sourceRoot,
            read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        var injected = false
        do {
            _ = try SNESPortableLibraryBackup.copy(source.directory, to: target, synchronize: { fd, checkpoint in
                if String(describing: checkpoint) == point { injected = true; return -1 }
                return Darwin.fsync(fd)
            })
            Issue.record("The copy must not report success when its \(point) flush fails")
        } catch {
            if point == "destination" { #expect(error.localizedDescription.contains("copy was created")) }
            else { #expect(error.localizedDescription.contains(".portable-")) }
        }
        #expect(injected)
        try source.validate()
        let destination = target.appendingPathComponent(source.directory.lastPathComponent)
        if point == "destination" {
            let retained = try SNESLibraryBackup.open(directory: destination)
            #expect(retained.manifestSHA256 == source.manifestSHA256)
        } else {
            let remaining = try FileManager.default.contentsOfDirectory(atPath: target.path)
            #expect(remaining.count == 1 && remaining[0].hasPrefix(".portable-"))
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
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
        // Never create a temporary copy inside the original snapshot or one
        // of its data directories: that would make the backup invalid.
        #expect(throws: (any Error).self) { try SNESPortableLibraryBackup.copy(backup.directory, to: backup.directory) }
        #expect(throws: (any Error).self) { try SNESPortableLibraryBackup.copy(backup.directory, to: backup.directory.appendingPathComponent("data-0")) }
        try backup.validate()
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
    @Test func staleDestinationHandleCannotOverwriteAnotherFolder() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("stage"), moved = root.appendingPathComponent("held")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let victim = other.appendingPathComponent("manifest.json")
        try Data("do not replace".utf8).write(to: victim)
        let held = try RestoreDirectory(original)
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: other)
        #expect(throws: (any Error).self) {
            try SNESPortableLibraryBackup.writeForCopy(Data("wrong".utf8), name: "manifest.json", folder: held, synchronize: { Darwin.fsync($0) })
        }
        #expect(try Data(contentsOf: victim) == Data("do not replace".utf8))
    }
    @Test func substitutedStageIsNotRemovedOrOfferedAsTheUnfinishedCopy() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        for directory in [sourceRoot, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        let fixture = SNESLibraryInventoryTests(), challenge = UUID()
        let inventory = try fixture.parse(fixture.frame(challenge: challenge), challenge: challenge)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: sourceRoot,
            read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        var replaced: URL?
        do {
            _ = try SNESPortableLibraryBackup.copy(backup.directory, to: target, synchronize: { _, point in
                if case .file = point {
                    do {
                        let name = try #require(FileManager.default.contentsOfDirectory(atPath: target.path).first { $0.hasPrefix(".portable-") })
                        let oldPath = target.appendingPathComponent(name)
                        try FileManager.default.moveItem(at: oldPath, to: root.appendingPathComponent("moved-stage"))
                        try FileManager.default.createDirectory(at: oldPath, withIntermediateDirectories: false)
                        try Data("unrelated".utf8).write(to: oldPath.appendingPathComponent("keep"))
                        replaced = oldPath
                    } catch { Issue.record("Could not substitute the test stage: \(error)") }
                    return -1
                }
                return -1
            })
            Issue.record("A changed staging folder must not be accepted")
        } catch {
            #expect(error.localizedDescription.contains("folder moved or changed"))
        }
        let directory = try #require(replaced)
        #expect(try Data(contentsOf: directory.appendingPathComponent("keep")) == Data("unrelated".utf8))
        try backup.validate()
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
        for directory in [imported, imported.appendingPathComponent("data-0")] {
            let mode = try #require(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
            #expect(mode.intValue & 0o777 == 0o700)
        }
        for file in [imported.appendingPathComponent("manifest.json"), imported.appendingPathComponent("data-0/file-0000.bin")] {
            let mode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
            #expect(mode.intValue & 0o777 == 0o600)
        }
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
        let remaining = try FileManager.default.contentsOfDirectory(atPath: targetRoot.path)
        if fault == "existing" { #expect(remaining == [existing.lastPathComponent]) }
        else { #expect(remaining.count == 1 && remaining[0].hasPrefix(".portable-")) }
    }
}

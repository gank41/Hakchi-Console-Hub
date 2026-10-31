import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryBackupReuseTests {
    @Test func verifiedMacPayloadsReplaceDownloadsOnlyWhenTheirBytesMatchTheLiveInventory() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (material, before, _, _) = try await SNESLibrarySyncPlanTests().fixture(root)
        let source = SNESLibraryInventoryTests(), nonce = UUID()
        let text = String(decoding: try source.frame(challenge: nonce, menu: material.menu), as: UTF8.self)
            .replacingOccurrences(of: "CATALOG " + source.catalog, with: "CATALOG " + before.inventory.catalogSHA256)
        let inventory = try SNESLibraryInventory(raw: Data(text.utf8), challenge: nonce, contextSHA256: source.context, hwid: source.hwid, catalogSHA256: before.inventory.catalogSHA256)
        let reuse = try SNESLibraryBackupReuse.prepare(inventory: inventory, material: material, backups: [before])
        for file in inventory.files {
            let chunk = try #require(try reuse.chunk(file: file, offset: 0))
            #expect(chunk.count == min(file.byteCount, SNESLibraryBackupChunk.maximumBytes))
            if file.path == "clover/settings.json" { #expect(chunk == Data("{}".utf8)) }
        }
        let profile = try #require(inventory.files.first { $0.path == "clover/settings.json" })
        let changed = SNESLibraryInventory.File(path: profile.path, byteCount: profile.byteCount, sha256: BackupManifest.digest(Data("[]".utf8)), mode: profile.mode,
            modified: profile.modified, identity: profile.identity)
        #expect(try reuse.chunk(file: changed, offset: 0) == nil)
        #expect(throws: (any Error).self) { try reuse.chunk(file: profile, offset: 1) }
    }
    @Test func aNewSnapshotReusesUnchangedFilesButReadsChangedSaves() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root)
        let menu = try fixture.menu(review, originals)
        let saved = try await SNESLibraryRestoreTests().backup(root, originals: originals, menu: menu)
        let old = saved.inventory, changedBytes = Data("[]".utf8)
        let raw = Data(String(decoding: old.rawFrame, as: UTF8.self)
            .replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(changedBytes)).utf8)
        let current = try SNESLibraryInventory(raw: raw, challenge: old.challenge, contextSHA256: old.contextSHA256,
            hwid: old.hwid, catalogSHA256: old.catalogSHA256)
        #expect(try SNESLibraryBackup.matching(inventory: current, roots: [root]) == nil)
        let result = try await SNESLibraryBackup.capture(inventory: current, root: root, read: { file, offset in
            // Only changed bytes may be requested; unchanged ROM/art/menu downloads fail this regression.
            guard file.path == "clover/settings.json", offset == 0 else { throw SyncPlanError.invalidInput("Unchanged file was downloaded: \(file.path)") }
            return changedBytes
        }, refresh: { current })
        #expect(result.directory != saved.directory)
        #expect(result.inventory.snapshotSHA256 == current.snapshotSHA256)
        #expect(try result.read(path: "clover/settings.json") == changedBytes)
        for file in old.files where file.path != "clover/settings.json" {
            #expect(try result.read(path: file.path) == saved.read(path: file.path))
        }
        #expect(try saved.read(path: "clover/settings.json") == Data("{}".utf8))
    }

    @Test func reuseStillRequiresBackupCreationApprovalAndAnUnchangedFinalConsoleState() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root)
        let saved = try await SNESLibraryRestoreTests().backup(root, originals: originals, menu: fixture.menu(review, originals))
        let old = saved.inventory, changed = Data("[]".utf8)
        let raw = Data(String(decoding: old.rawFrame, as: UTF8.self)
            .replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(changed)).utf8)
        let current = try SNESLibraryInventory(raw: raw, challenge: old.challenge, contextSHA256: old.contextSHA256,
            hwid: old.hwid, catalogSHA256: old.catalogSHA256)
        await #expect(throws: SNESLibraryBackupCreationRequired.self) {
            try await SNESLibraryBackup.capture(inventory: current, root: root, read: { _, _ in
                Issue.record("Creation without approval must not start a USB read"); return changed
            }, refresh: { current }, allowCreation: false)
        }
        await #expect(throws: (any Error).self) {
            try await SNESLibraryBackup.capture(inventory: current, root: root, read: { _, _ in changed }, refresh: { old })
        }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("SNES-Library-") }
        #expect(folders == [saved.directory])
        #expect(try saved.read(path: "clover/settings.json") == Data("{}".utf8))
    }

    @Test(arguments: ["different-console", "different-catalog", "damaged-backup"])
    func unsuitableOldSnapshotsFallBackToFreshReads(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root)
        let saved = try await SNESLibraryRestoreTests().backup(root, originals: originals, menu: fixture.menu(review, originals))
        let old = saved.inventory, changed = Data("[]".utf8)
        var payloads = try Dictionary(uniqueKeysWithValues: old.files.map { ($0.path, try saved.read(path: $0.path)) })
        payloads["clover/settings.json"] = changed
        let hwid = fault == "different-console" ? String(repeating: "2", count: 32) : old.hwid
        let catalog = fault == "different-catalog" ? String(repeating: "e", count: 64) : old.catalogSHA256
        let raw = Data(String(decoding: old.rawFrame, as: UTF8.self)
            .replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(changed))
            .replacingOccurrences(of: "HWID " + old.hwid, with: "HWID " + hwid)
            .replacingOccurrences(of: "CATALOG " + old.catalogSHA256, with: "CATALOG " + catalog).utf8)
        let current = try SNESLibraryInventory(raw: raw, challenge: old.challenge, contextSHA256: old.contextSHA256, hwid: hwid, catalogSHA256: catalog)
        if fault == "damaged-backup" { try Data("changed".utf8).write(to: saved.directory.appendingPathComponent("data-0/file-0000.bin")) }
        let downloads = SNESBackupDownloadRecorder(), bytes = payloads
        let result = try await SNESLibraryBackup.capture(inventory: current, root: root, read: { file, offset in
            await downloads.note(file.path)
            let data = try #require(bytes[file.path])
            return Data(data[offset..<min(offset + SNESLibraryBackupChunk.maximumBytes, data.count)])
        }, refresh: { current })
        #expect(await downloads.paths == Set(current.files.map(\.path)))
        #expect(result.inventory.snapshotSHA256 == current.snapshotSHA256)
        #expect(try result.read(path: "clover/settings.json") == changed)
    }

    @Test func anEmptyCacheFallsBackToTheConsoleAndChangedMacPayloadsAreRefused() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (material, before, _, _) = try await SNESLibrarySyncPlanTests().fixture(root)
        let empty = try SNESLibraryBackupReuse.prepare(inventory: before.inventory, material: nil, backups: [])
        #expect(try empty.chunk(file: before.inventory.files[0], offset: 0) == nil)
        let name = try #require(material.menu.objectRecords.first).name
        try Data([0]).write(to: material.directory.appendingPathComponent("object-" + name))
        #expect(throws: (any Error).self) { try SNESLibraryBackupReuse.prepare(inventory: before.inventory, material: material, backups: [before]) }
    }
}

private actor SNESBackupDownloadRecorder {
    private(set) var paths = Set<String>()
    func note(_ path: String) { paths.insert(path) }
}

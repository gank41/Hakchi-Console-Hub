import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryBackupTests {
    @Test func finderMetadataDoesNotInvalidateOrDuplicateAnOtherwiseVerifiedBackup() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID()
        let inventory = try fixture.parse(fixture.frame(challenge: nonce), challenge: nonce)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root,
            read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        let manifest = try Data(contentsOf: backup.directory.appendingPathComponent("manifest.json"))
        for directory in [backup.directory, backup.directory.appendingPathComponent("data-0")] {
            try Data("Finder metadata".utf8).write(to: directory.appendingPathComponent(".DS_Store"))
        }
        try backup.validate()
        let reopened = try SNESLibraryBackup.open(directory: backup.directory)
        #expect(try reopened.read(path: "clover/settings.json") == Data("{}".utf8))
        let reused = try await SNESLibraryBackup.capture(inventory: inventory, root: root,
            read: { _, _ in Issue.record("Finder metadata must not force another USB backup"); return Data() }, refresh: { inventory })
        #expect(reused.directory == backup.directory)
        #expect(try Data(contentsOf: backup.directory.appendingPathComponent("manifest.json")) == manifest)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }
    @Test func finderMetadataAppearingDuringCaptureDoesNotPreventPublication() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID()
        let inventory = try fixture.parse(fixture.frame(challenge: nonce), challenge: nonce)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root,
            read: { _, _ in Data("{}".utf8) }, refresh: {
                let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                let directory = try #require(directories.first)
                try Data("Finder metadata".utf8).write(to: directory.appendingPathComponent(".DS_Store"))
                return inventory
            })
        #expect(try backup.read(path: "clover/settings.json") == Data("{}".utf8))
        #expect(try SNESLibraryBackup.open(directory: backup.directory).manifestSHA256 == backup.manifestSHA256)
    }
    @Test(arguments: ["symlink", "hardlink", "directory", "oversized"])
    func finderMetadataExceptionCannotHideUnsafeFilesystemEntries(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID()
        let inventory = try fixture.parse(fixture.frame(challenge: nonce), challenge: nonce)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root,
            read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        let target = backup.directory.appendingPathComponent(".DS_Store")
        let outside = root.appendingPathComponent("outside"); try Data([0]).write(to: outside)
        switch fault {
        case "symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        case "hardlink": try FileManager.default.linkItem(at: outside, to: target)
        case "directory": try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        default: try Data(repeating: 0, count: 2 * 1024 * 1024).write(to: target)
        }
        #expect(throws: (any Error).self) { try backup.validate() }
        #expect(throws: (any Error).self) { try SNESLibraryBackup.open(directory: backup.directory) }
    }
    @Test(arguments: ["valid", "truncated", "changed-save", "changed-after", "cancelled"])
    func capturePublishesOnlyCompleteCurrentSnapshots(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID()
        let raw = try fixture.frame(challenge: nonce), inventory = try fixture.parse(raw, challenge: nonce)
        let changedRaw = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8))).utf8)
        let changed = try fixture.parse(changedRaw, challenge: nonce)
        let reader: SNESLibraryBackup.Reader = { _, _ in
            if fault == "cancelled" { throw CancellationError() }
            return Data((fault == "truncated" ? "{" : fault == "changed-save" ? "[]" : "{}").utf8)
        }
        if fault == "valid" {
            let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: reader, refresh: { inventory })
            #expect(backup.inventory.snapshotSHA256 == inventory.snapshotSHA256)
            #expect(try backup.read(path: "clover/settings.json") == Data("{}".utf8))
            let reuse = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Issue.record("A current snapshot should be reused without another download"); return Data() }, refresh: { inventory })
            #expect(reuse.directory == backup.directory)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
            let opened = try SNESLibraryBackup.open(directory: backup.directory)
            #expect(opened.inventory.snapshotSHA256 == inventory.snapshotSHA256)
        } else {
            await #expect(throws: (any Error).self) {
                try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: reader, refresh: { fault == "changed-after" ? changed : inventory })
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    @Test func largeEmptyAndIdenticalFilesUseBoundedReadsAndOneBlobPerContent() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), payload = Data((0..<543210).map { UInt8($0 % 251) })
        let hash = BackupManifest.digest(payload), emptyHash = BackupManifest.digest(Data())
        var raw = String(decoding: try fixture.frame(challenge: nonce), as: UTF8.self)
            .replacingOccurrences(of: "2 " + BackupManifest.digest(Data("{}".utf8)), with: String(payload.count) + " " + hash)
        raw = raw.replacingOccurrences(of: "END\n", with: "FILE \(fixture.hex("clover/identical")) \(payload.count) \(hash) 384 0 1 9998 0\nFILE \(fixture.hex("clover/empty")) 0 \(emptyHash) 384 0 1 9997 0\nEND\n")
        let inventory = try fixture.parse(Data(raw.utf8), challenge: nonce), calls = SNESBackupReadCalls()
        let saved = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { file, offset in
            await calls.record(offset)
            #expect(file.byteCount == payload.count)
            return Data(payload[offset..<min(offset + SNESLibraryBackupChunk.maximumBytes, payload.count)])
        }, refresh: { inventory })
        #expect(await calls.offsets == [0, 262144, 524288])
        #expect(try saved.read(path: "clover/empty").isEmpty)
        #expect(try saved.read(path: "clover/identical") == payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: saved.directory.appendingPathComponent("data-0").path).count == 2)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_INVENTORY_ARM_RESULT"] != nil))
    func actualPinnedARMFramesPassTheProductionParsers() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_INVENTORY_ARM_RESULT"]))
        let raw = try Data(contentsOf: root.appendingPathComponent("inventory.frame")), nonce = try #require(UUID(uuidString: String(decoding: raw, as: UTF8.self).components(separatedBy: "\n")[0].components(separatedBy: " ")[1]))
        let inventory = try SNESLibraryInventoryTests().parse(raw, challenge: nonce)
        let chunk = try Data(contentsOf: root.appendingPathComponent("chunk.frame"))
        let chunkID = try #require(UUID(uuidString: String(decoding: chunk.prefix(256), as: UTF8.self).components(separatedBy: " ")[1]))
        let file = try #require(inventory.files.first)
        #expect(try SNESLibraryBackupChunk(raw: chunk, file: file, offset: 0, challenge: chunkID, contextSHA256: inventory.contextSHA256).bytes == Data("{\"language\":\"en\"}".utf8))
    }
    @Test func linkedChangedAndUnknownMacFilesCannotBecomeVerifiedBackups() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), inventory = try fixture.parse(fixture.frame(challenge: nonce), challenge: nonce)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        let group = backup.directory.appendingPathComponent("data-0")
        let file = group.appendingPathComponent("file-0000.bin"), original = try Data(contentsOf: file)
        try Data("[]".utf8).write(to: file)
        #expect(throws: (any Error).self) { try backup.read(path: "clover/settings.json") }
        #expect(throws: (any Error).self) { try SNESLibraryBackup.open(directory: backup.directory) }
        try original.write(to: file)
        let outside = root.appendingPathComponent("outside"); try original.write(to: outside)
        try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try SNESLibraryBackup.open(directory: backup.directory) }
        try FileManager.default.removeItem(at: file); try original.write(to: file)
        try Data([0]).write(to: group.appendingPathComponent("unexpected"))
        #expect(throws: (any Error).self) { try SNESLibraryBackup.open(directory: backup.directory) }
    }
    @Test(arguments: ["valid", "nonce", "offset", "path", "hash", "truncated", "extra"])
    func chunkEnvelopeBindsTheExactRead(_ fault: String) throws {
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), inventory = try fixture.parse(fixture.frame(challenge: nonce), challenge: nonce)
        let file = try #require(inventory.files.first), body = Data("{}".utf8), hash = BackupManifest.digest(body)
        var raw = Data("SWIFTHAKCHI_SNES_LIBRARY_CHUNK_V1 \(nonce.uuidString) \(fixture.context) \(fixture.hex(file.path)) 0 2 \(hash)\n".utf8)
        raw.append(body); raw.append(Data("\nSWIFTHAKCHI_SNES_LIBRARY_CHUNK_END_V1 \(nonce.uuidString) \(hash)\n".utf8))
        if fault == "hash" { raw[raw.firstIndex(of: 10)!+1] = 1 }
        if fault == "truncated" { raw.removeLast() }
        if fault == "extra" { raw.append(0) }
        if fault == "valid" {
            #expect(try SNESLibraryBackupChunk(raw: raw, file: file, offset: 0, challenge: nonce, contextSHA256: fixture.context).bytes == body)
        } else {
            do {
                #expect(throws: (any Error).self) { try SNESLibraryBackupChunk(raw: raw, file: file, offset: fault == "offset" ? 262144 : 0,
                    challenge: fault == "nonce" ? UUID() : nonce, contextSHA256: fault == "path" ? String(repeating: "c", count: 64) : fixture.context) }
            }
        }
    }
}

private actor SNESBackupReadCalls {
    private(set) var offsets: [Int] = []
    func record(_ offset: Int) { offsets.append(offset) }
}

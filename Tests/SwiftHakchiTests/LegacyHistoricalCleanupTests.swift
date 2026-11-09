import Foundation
import Testing
import SWCompression
import SwiftHakchiCore
@testable import SwiftHakchi

struct LegacyHistoricalCleanupTests {
    private let id = UUID(uuidString: "82DBB4BB-13E6-4159-9475-69AE54024531")!

    @Test func cleanupRecordIdentitySupportsDifferentConsolesAndRejectsMismatch() throws {
        let first = String(repeating: "1", count: 32)
        let second = String(repeating: "2", count: 32)
        for chip in [first, second] {
            try LegacyDeviceIdentity.requireOperationIdentity(chip,
                fingerprint: BackupManifest.digest(Data(chip.utf8)))
        }
        #expect(throws: (any Error).self) {
            try LegacyDeviceIdentity.requireOperationIdentity(second,
                fingerprint: BackupManifest.digest(Data(first.utf8)))
        }
        #expect(throws: (any Error).self) {
            try LegacyDeviceIdentity.requireOperationIdentity(second, fingerprint: nil)
        }
    }

    @Test func cleanupCanOnlyNameOwnedTemporaryDirectories() throws {
        for path in ["/var/lib/hakchi/games/nes", "/var/lib/hakchi/games/nes/000",
                     "/var/squashfs/usr/share/games/nes/kachikachi", "/var/lib/hakchi/.swift-hakchi-transactions",
                     "/var/lib/hakchi/games/nes.swift-old-../nes"] {
            #expect(throws: (any Error).self) { try LegacyHistoricalCleanup.Target(path: path) }
        }
        let target = try LegacyHistoricalCleanup.Target(path: LegacySyncCommands.oldPath(for: id))
        #expect(target.operationID == id)
        #expect(LegacyChangeRequest.inventoryHistorical(target).maximumOutputBytes == LegacyStageVerification.maximumInventoryBytes)
        let command = try LegacyHistoricalCleanupCommands.remove(target: target,
            currentTreeSHA256: String(repeating: "a", count: 64), targetTreeSHA256: String(repeating: "b", count: 64))
        #expect(command.contains("rm -r -- \"$target\""))
        #expect(!command.contains("rm -rf"))
        #expect(command.contains("tree_digest \"$live\""))
        #expect(command.contains("tree_digest \"$target\""))
        #expect(command.contains("pidof kachikachi canoe-shvc retroarch"))
        #expect(command.contains(".swift-hakchi-sync-lock"))
        #expect(command.contains("stat -c '%d:%i'"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        let input = Pipe(); process.standardInput = input
        try process.run(); input.fileHandleForWriting.write(Data(command.utf8))
        try input.fileHandleForWriting.close(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func backupInventorySeparatesTargetsAndPreservesExactBytes() throws {
        let target = try LegacyHistoricalCleanup.Target(path: LegacySyncCommands.oldPath(for: id))
        let root = String(target.path.dropFirst())
        var dir = TarEntryInfo(name: root, type: .directory); dir.permissions = Permissions(rawValue: 0o755)
        var file = TarEntryInfo(name: root + "/game.nes", type: .regular)
        file.permissions = Permissions(rawValue: 0o644)
        let data = TarContainer.create(from: [TarEntry(info: dir, data: nil), TarEntry(info: file, data: Data([1, 2, 3]))])
        let entries = try LegacyHistoricalCleanup.archiveEntries(data, target: target)
        #expect(entries.count == 1)
        #expect(entries[0].relativePath == "game.nes")
        #expect(entries[0].byteCount == 3)
        #expect(entries[0].sha256 == BackupManifest.digest(Data([1, 2, 3])))
        let emptyArchive = TarContainer.create(from: [TarEntry(info: dir, data: nil)])
        #expect(try LegacyHistoricalCleanup.archiveEntries(emptyArchive, target: target).isEmpty)
        let absent = try LegacyHistoricalCleanup.Target(path: LegacySyncCommands.oldPath(for: UUID()))
        #expect(throws: (any Error).self) { try LegacyHistoricalCleanup.archiveEntries(data, target: absent) }
    }

    @Test func interruptedRemovalMayOnlyResumeWithUnchangedRemainingFiles() throws {
        let hash = BackupManifest.digest(Data([1]))
        let expected = [LegacyMenuStageManifest.Entry(relativePath: "game.nes", kind: .regular,
            byteCount: 1, sha256: hash, linkTarget: nil),
            .init(relativePath: "cover.png", kind: .regular, byteCount: 1, sha256: hash, linkTarget: nil)]
        let line = "game.nes\tregular\t1\t\(hash)\t\n"
        let inventory = Data(("STAGE_INVENTORY:\(id.uuidString)\n" + line + "END_STAGE_INVENTORY\n").utf8)
        #expect(try LegacyHistoricalCleanup.remainingTreeDigest(inventory, operationID: id,
            original: expected) == BackupManifest.digest(Data(line.utf8)))
        let changed = Data(String(decoding: inventory, as: UTF8.self).replacingOccurrences(of: hash,
            with: String(repeating: "0", count: 64)).utf8)
        #expect(throws: (any Error).self) {
            try LegacyHistoricalCleanup.remainingTreeDigest(changed, operationID: id, original: expected)
        }
    }
}

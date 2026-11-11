import Foundation
import Darwin
import CryptoKit
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESPortableDataSnapshotTests {
    @Test func checkingAnInvalidBackupDoesNotCreateOrChangeFiles() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let manifest = folder.appendingPathComponent("manifest.json")
        let original = Data("{}".utf8)
        try original.write(to: manifest)
        #expect(throws: (any Error).self) { _ = try SNESPortableDataSnapshot.inspect(directory: folder) }
        #expect(try Data(contentsOf: manifest) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["manifest.json"])
        #expect(throws: (any Error).self) { _ = try SNESPortableDataSnapshot.inspect(directory: root.appendingPathComponent("missing")) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func checksAnExistingBackupWithoutChangingIt() throws {
        let input = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"]))
        let manifestURL = input.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifestURL)
        let names = try FileManager.default.contentsOfDirectory(atPath: input.path).sorted()
        let checked = try SNESPortableDataSnapshot.inspect(directory: input)
        #expect(checked.byteCount > 0)
        #expect(checked.manifestSHA256 == BackupManifest.digest(before))
        #expect(try Data(contentsOf: manifestURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: input.path).sorted() == names)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func reconstructsTheEntireSnapshotInDisposableFileStorage() throws {
        let input = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"]))
        let manifest = try JSONDecoder().decode(SNESDataSnapshotResult.Manifest.self, from: Data(contentsOf: input.appendingPathComponent("manifest.json")))
        let source = try SNESDataSnapshotPackage.load(directory: input, expectedHWID: manifest.binding.expectedHWID)
        let plan = try SNESDataSnapshotPlan(partitionSectors: UInt64(source.byteCount / 512))
        #expect(plan.chunkCount > 2)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        enum SimulationError: Error { case interrupted, invalidTarget }
        func reconstruct(_ file: URL, interruptAt: Int?) throws {
            try source.revalidate()
            // This simulation can create only a new regular file in its test
            // directory. It has no console or block-device write path.
            guard file.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { throw SimulationError.invalidTarget }
            let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw SimulationError.invalidTarget }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw SimulationError.invalidTarget }
            try source.streamVerifiedChunks { index, bytes in
                if index == interruptAt { throw SimulationError.interrupted }
                try handle.write(contentsOf: bytes)
            }
            try handle.synchronize(); try source.revalidate()
            try handle.seek(toOffset: 0)
            var digest = SHA256(), total = 0
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                total += bytes.count; digest.update(data: bytes)
            }
            #expect(total == source.byteCount)
            #expect(digest.finalize().map { String(format: "%02x", $0) }.joined() == source.sha256)
        }
        let partial = root.appendingPathComponent("interrupted-image")
        #expect(throws: SimulationError.interrupted) { try reconstruct(partial, interruptAt: 2) }
        let partialSize = try #require(FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)
        #expect(partialSize.intValue == 2 * SNESDataSnapshotPlan.maximumChunkBytes)
        #expect(throws: SimulationError.invalidTarget) { try reconstruct(partial, interruptAt: nil) }
        let completed = root.appendingPathComponent("completed-image")
        try reconstruct(completed, interruptAt: nil)
        try source.revalidate()
    }

    @Test func refusesMissingBackupWithoutCreatingACopy() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("missing")
        #expect(throws: (any Error).self) { try SNESPortableDataSnapshot.copy(directory: input, to: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let invalid = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: invalid.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try SNESPortableDataSnapshot.copy(directory: invalid, to: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [invalid.lastPathComponent])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func copiesVerifiedSnapshotWithoutReplacingExistingBackup() throws {
        let input = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"]))
        let manifest = try JSONDecoder().decode(SNESDataSnapshotResult.Manifest.self, from: Data(contentsOf: input.appendingPathComponent("manifest.json")))
        let source = try SNESDataSnapshotPackage.load(directory: input, expectedHWID: manifest.binding.expectedHWID)
        let plan = try SNESDataSnapshotPlan(partitionSectors: UInt64(source.byteCount / 512))
        let first = try source.readVerifiedChunk(0)
        let last = try source.readVerifiedChunk(plan.chunkCount - 1)
        #expect(first.count == (try plan.range(0)).count)
        #expect(last.count == (try plan.range(plan.chunkCount - 1)).count)
        #expect(throws: (any Error).self) { try source.readVerifiedChunk(-1) }
        #expect(throws: (any Error).self) { try source.readVerifiedChunk(plan.chunkCount) }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copied = try SNESPortableDataSnapshot.copy(directory: input, to: root)
        let reopened = try SNESDataSnapshotPackage.load(directory: copied, expectedHWID: manifest.binding.expectedHWID)
        #expect(reopened.sha256 == source.sha256 && reopened.manifestSHA256 == source.manifestSHA256)
        let file = copied.appendingPathComponent("manifest.json")
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)
        #expect(throws: (any Error).self) { try SNESPortableDataSnapshot.copy(source, to: root) }
        #expect(throws: (any Error).self) { try SNESPortableDataSnapshot.copy(source, to: source.directory) }
        try reopened.revalidate(); try source.revalidate()

        // Damage only a temporary copy of the source, never the real backup.
        let damagedSource = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source.directory, to: damagedSource)
        let reviewedCopy = try SNESDataSnapshotPackage.load(directory: damagedSource, expectedHWID: manifest.binding.expectedHWID)
        let copiedManifest = damagedSource.appendingPathComponent("manifest.json")
        let originalManifest = try Data(contentsOf: copiedManifest)
        try (originalManifest + Data(" ".utf8)).write(to: copiedManifest)
        #expect(throws: (any Error).self) { try reviewedCopy.readVerifiedChunk(0) }
        try originalManifest.write(to: copiedManifest)
        var delivered = 0
        #expect(throws: (any Error).self) {
            try reviewedCopy.streamVerifiedChunks { index, _ in
                delivered += 1
                if index == 0 {
                    // Mutate the already-delivered piece. Only final whole
                    // backup revalidation can notice this later change.
                    let damagedChunk = try FileHandle(forUpdating: damagedSource.appendingPathComponent("data-0000.bin"))
                    let firstByte = try #require(try damagedChunk.read(upToCount: 1)?.first)
                    try damagedChunk.seek(toOffset: 0); try damagedChunk.write(contentsOf: Data([firstByte ^ 0xff])); try damagedChunk.close()
                }
            }
        }
        #expect(delivered == plan.chunkCount)
        #expect(throws: (any Error).self) { try reviewedCopy.readVerifiedChunk(0) }
        #expect(throws: (any Error).self) { _ = try SNESPortableDataSnapshot.inspect(directory: damagedSource) }
        let rejectedRoot = root.appendingPathComponent("rejected")
        try FileManager.default.createDirectory(at: rejectedRoot, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try SNESPortableDataSnapshot.copy(directory: damagedSource, to: rejectedRoot) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: rejectedRoot.path).isEmpty)
        try source.revalidate()

        // A source piece changed during copying is rejected before publication.
        let changingSource = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source.directory, to: changingSource)
        let changing = try SNESDataSnapshotPackage.load(directory: changingSource, expectedHWID: manifest.binding.expectedHWID)
        let lastPath = changingSource.appendingPathComponent(SNESDataSnapshotPlan.name(plan.chunkCount - 1)).path
        var changedDuringCopy = false
        #expect(throws: (any Error).self) {
            try SNESPortableDataSnapshot.copy(changing, to: rejectedRoot, synchronize: { fd, point in
                if case .file = point, !changedDuringCopy {
                    let changed = open(lastPath, O_RDWR | O_NOFOLLOW)
                    guard changed >= 0 else { return -1 }
                    var byte: UInt8 = 0
                    guard pread(changed, &byte, 1, 0) == 1 else { close(changed); return -1 }
                    byte ^= 0xff
                    guard pwrite(changed, &byte, 1, 0) == 1 else { close(changed); return -1 }
                    close(changed); changedDuringCopy = true
                }
                return fsync(fd)
            })
        }
        #expect(changedDuringCopy)
        let interruptedNames = try FileManager.default.contentsOfDirectory(atPath: rejectedRoot.path)
        #expect(interruptedNames.count == 1 && interruptedNames[0].hasPrefix(".data-copy-"))
        #expect(!FileManager.default.fileExists(atPath: rejectedRoot.appendingPathComponent(source.directory.lastPathComponent).path))
        try source.revalidate()

        let failedRoot = root.appendingPathComponent("failed")
        try FileManager.default.createDirectory(at: failedRoot, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try SNESPortableDataSnapshot.copy(source, to: failedRoot, synchronize: { _, _ in -1 })
        }
        let firstFailureNames = try FileManager.default.contentsOfDirectory(atPath: failedRoot.path)
        #expect(firstFailureNames.count == 1 && firstFailureNames[0].hasPrefix(".data-copy-"))

        // A damaged staged copy never becomes the visible backup.
        var damagedCopy = false
        #expect(throws: (any Error).self) {
            try SNESPortableDataSnapshot.copy(source, to: failedRoot, synchronize: { fd, point in
                if case .output = point {
                    damagedCopy = true
                    let damaged = openat(fd, "data-0000.bin", O_WRONLY | O_TRUNC | O_NOFOLLOW)
                    guard damaged >= 0 else { return -1 }
                    close(damaged)
                }
                return fsync(fd)
            })
        }
        #expect(damagedCopy)
        let secondFailureNames = try FileManager.default.contentsOfDirectory(atPath: failedRoot.path)
        #expect(secondFailureNames.count == 2 && secondFailureNames.allSatisfy { $0.hasPrefix(".data-copy-") })
        #expect(!FileManager.default.fileExists(atPath: failedRoot.appendingPathComponent(source.directory.lastPathComponent).path))

        // If final folder synchronization fails, the published copy is kept
        // for inspection, and the operation does not report success.
        var failedDestination = false
        #expect(throws: (any Error).self) {
            try SNESPortableDataSnapshot.copy(source, to: failedRoot, synchronize: { fd, point in
                if case .destination = point { failedDestination = true; return -1 }
                return fsync(fd)
            })
        }
        #expect(failedDestination)
        let retained = failedRoot.appendingPathComponent(source.directory.lastPathComponent)
        let retainedCopy = try SNESDataSnapshotPackage.load(directory: retained, expectedHWID: manifest.binding.expectedHWID)
        #expect(retainedCopy.manifestSHA256 == source.manifestSHA256)
        try source.revalidate()
    }
}

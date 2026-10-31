import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryOwnerCacheTests {
    private func key(_ root: URL, version: UInt16 = 0x6a0b, suffix: String = "a") -> SNESLibraryOwnerCacheKey {
        .init(reference: SNESLibraryInstallationReference(
            hwid: String(repeating: "1", count: 32),
            operationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            reviewSHA256: String(repeating: "a", count: 64),
            catalog: root.appendingPathComponent("SNES-Original-Games-11111111-1111-4111-8111-111111111111"),
            catalogSHA256: String(repeating: "b", count: 64)),
            deviceVersion: version, workspaceRoot: root.appendingPathComponent(suffix),
            backupRoots: [root.appendingPathComponent("Backups")], journalRoot: root.appendingPathComponent("Firmware"))
    }

    @Test(arguments: [false, true])
    func cachedEvidenceStillRejectsNewOrChangedUnfinishedFirmwareWork(_ existingSibling: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let journals = key(root).journalRoot
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
        let sibling = journals.appendingPathComponent("SNESFirmware-" + UUID().uuidString)
        if existingSibling { try writeSibling(sibling, unfinished: false) }
        let cache = SNESLibraryOwnerCache<Int>(), cacheKey = key(root)
        let validate: @Sendable (Int) throws -> Void = { _ in
            try SNESFirmwareJournal.validateSiblingHistory(root: journals, excluding: cacheKey.reference.operationID, recoveryParent: nil)
        }
        _ = try await cache.value(for: cacheKey, validate: validate, load: { 1 })
        try writeSibling(sibling, unfinished: true)
        await #expect(throws: SNESFirmwareJournalError.unresolved) {
            try await cache.value(for: cacheKey, validate: validate, load: { 2 })
        }
    }

    private func writeSibling(_ folder: URL, unfinished: Bool) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID(uuidString: String(folder.lastPathComponent.dropFirst(13)))!
        let geometry = Data(repeating: 0, count: 24), image = Data(repeating: 0, count: 7340032)
        let digest = BackupManifest.digest(image), pin = String(repeating: "a", count: 64)
        let plan = SNESFirmwarePlan(schemaVersion: 1, scope: "snes-physical-active-boot2", id: id, direction: .install,
            paths: .init(candidate: "/test", preflight: "/test", started: "/test", played: "/test", original: "/test", reader: "/test", writer: "/test"),
            binding: .init(sourceSnapshot: "SNES-US-Setup-" + UUID().uuidString, setupManifestSHA256: pin, expectedHWID: String(repeating: "1", count: 32)),
            originalManifestSHA256: pin, preimageSHA256: digest, targetSHA256: digest, geometrySHA256: BackupManifest.digest(geometry),
            inputSHA256: BackupManifest.digest(geometry + image + image), candidateSHA256: pin, startedSHA256: pin, playedSHA256: pin, readerSHA256: pin, writerSHA256: pin,
            offsetBytes: 0x600000, byteCount: 7340032, unitBytes: 131072, parentReviewSHA256: nil, parentOperationID: nil, originalRangeSHA256: nil)
        // Preserve the initial plan when advancing an existing sibling's records.
        let file = folder.appendingPathComponent("plan.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try JSONEncoder().encode(plan).write(to: file)
            try (geometry + image + image).write(to: folder.appendingPathComponent("input.bin"))
        }
        let review = BackupManifest.digest(try Data(contentsOf: file))
        var previous: String?
        let phases: [String] = unfinished ? ["prepared", "preflightVerified", "writeIntent"] : ["prepared"]
        for (index, phase) in phases.enumerated() {
            var record = ["phase": phase, "planSHA256": review]
            record["previousSHA256"] = previous
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try bytes.write(to: folder.appendingPathComponent(String(format: "%04d.json", index)))
            previous = BackupManifest.digest(bytes)
        }
    }

    @Test func unchangedSourceReusesValidatedEvidenceWithoutReconstructingIt() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source"); try Data("original".utf8).write(to: file)
        let cache = SNESLibraryOwnerCache<CacheTestOwner>(), loader = CacheTestOwnerLoader()
        let first = try await cache.value(for: key(root), validate: { try $0.validate() }, load: { try await loader.load(file) })
        let second = try await cache.value(for: key(root), validate: { try $0.validate() }, load: { try await loader.load(file) })
        #expect(first.bytes == Data("original".utf8) && second.bytes == first.bytes)
        #expect(await loader.calls == 1)
    }

    @Test func changedSourceFailsRatherThanSilentlyReloadingOrReusingOldEvidence() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source"); try Data("original".utf8).write(to: file)
        let cache = SNESLibraryOwnerCache<CacheTestOwner>(), loader = CacheTestOwnerLoader()
        _ = try await cache.value(for: key(root), validate: { try $0.validate() }, load: { try await loader.load(file) })
        try Data("changed!".utf8).write(to: file)
        await #expect(throws: (any Error).self) {
            try await cache.value(for: key(root), validate: { try $0.validate() }, load: { try await loader.load(file) })
        }
        #expect(await loader.calls == 1)
    }

    @Test func runtimeOrWorkspaceChangesDoNotShareEvidence() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source"); try Data("original".utf8).write(to: file)
        let cache = SNESLibraryOwnerCache<CacheTestOwner>(), loader = CacheTestOwnerLoader()
        for value in [key(root), key(root, version: 0x6a09), key(root, suffix: "other-workspace")] {
            _ = try await cache.value(for: value, validate: { try $0.validate() }, load: { try await loader.load(file) })
        }
        #expect(await loader.calls == 3)
    }

    @Test func failedAndCancelledLoadsAreNotCached() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source"), cache = SNESLibraryOwnerCache<CacheTestOwner>(), loader = CacheTestOwnerLoader()
        await #expect(throws: (any Error).self) {
            try await cache.value(for: key(root), validate: { try $0.validate() }, load: { try await loader.load(file) })
        }
        try Data("original".utf8).write(to: file)
        let cancelled = Task {
            try await cache.value(for: key(root), validate: { try $0.validate() }, load: {
                let owner = try await loader.load(file)
                withUnsafeCurrentTask { $0?.cancel() }
                return owner
            })
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let owner = try await cache.value(for: key(root), validate: { try $0.validate() }, load: { try await loader.load(file) })
        #expect(owner.bytes == Data("original".utf8))
        #expect(await loader.calls == 3)
    }

    @Test func aFifthSourceEvictsTheOldestEntryInsteadOfRetainingUnboundedHistory() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source"); try Data("original".utf8).write(to: file)
        let cache = SNESLibraryOwnerCache<CacheTestOwner>(), loader = CacheTestOwnerLoader()
        for suffix in ["a", "b", "c", "d", "e", "a"] {
            _ = try await cache.value(for: key(root, suffix: suffix), validate: { try $0.validate() }, load: { try await loader.load(file) })
        }
        #expect(await loader.calls == 6)
    }
}

private struct CacheTestOwner: Sendable {
    let bytes: Data, seal: SNESFirmwareSourceSeal
    func validate() throws { try seal.validate() }
}

private actor CacheTestOwnerLoader {
    private(set) var calls = 0
    func load(_ file: URL) throws -> CacheTestOwner {
        calls += 1
        let seal = try SNESFirmwareSourceSeal.capture(directories: [], files: [file])
        let bytes = try Data(contentsOf: file)
        try seal.validate()
        return CacheTestOwner(bytes: bytes, seal: seal)
    }
}

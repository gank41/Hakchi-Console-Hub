import Foundation
import Darwin
import SwiftHakchiCore

enum SNESLibrarySourcePolicy: Sendable { case live, frozenRecovery }

/// A Mac-only, manifest-last package. The expected review hash is supplied by its owner on reopen.
struct SNESLibraryMaterial: Sendable {
    private struct Plan: Codable {
        let version: Int, menu: SNESLibraryMenu.Manifest, sources: [SNESLibrarySourceFile]
    }
    let directory: URL, reviewSHA256: String, menu: SNESLibraryMenu
    static func freeze(menu: SNESLibraryMenu, in parent: URL) throws -> Self {
        try freeze(menu: menu, in: parent, candidateOnly: false)
    }
    /// Stores a mixed menu for Mac-side inspection only. It cannot be loaded
    /// by the transfer or restore paths, which use the native-only loader.
    static func freezeCompatibilityCandidate(menu: SNESLibraryMenu, in parent: URL) throws -> Self {
        try freeze(menu: menu, in: parent, candidateOnly: true)
    }
    private static func freeze(menu: SNESLibraryMenu, in parent: URL, candidateOnly: Bool) throws -> Self {
        guard candidateOnly ? [3,4].contains(menu.description.version) : [1, 2].contains(menu.description.version) else { throw SNESLibraryMenu.failure() }
        try menu.validate()
        for source in menu.sources { try source.verify() }
        let container = try RestoreDirectory(parent), name = "SNES-Library-" + menu.id.uuidString
        guard mkdirat(container.fd, name, 0o700) == 0 else { throw RestoreDirectory.failure() }
        let folder = try RestoreDirectory(container.url.appendingPathComponent(name))
        func write(_ name: String, _ data: Data) throws {
            try folder.check()
            let fd = openat(folder.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw RestoreDirectory.failure() }
            defer { close(fd) }
            var offset = 0
            try data.withUnsafeBytes { bytes in
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw RestoreDirectory.failure() }; offset += count
                }
            }
            var held = stat(), named = stat()
            guard fsync(fd) == 0, fstat(fd, &held) == 0,
                  fstatat(folder.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                  held.st_nlink == 1, named.st_nlink == 1, held.st_size == data.count else { throw RestoreDirectory.failure() }
            try folder.check()
        }
        let records = menu.description.files
        for record in menu.objectRecords { guard let data = menu.objects[record.name] else { throw SNESLibraryMenu.failure() }; try write("object-" + record.name, data) }
        // Menu entries sharing exact bytes share one ordinary package blob.
        var written = Set<String>()
        for record in records where written.insert(record.sha256).inserted {
            guard let data = menu.files[record.path] else { throw SNESLibraryMenu.failure() }; try write("file-" + record.sha256, data)
        }
        try write("menu.json", menu.manifest)
        for source in menu.sources { try source.verify() }
        let plan = try SNESLibraryMenu.encode(Plan(version: 1, menu: menu.description, sources: menu.sources))
        guard plan.count <= 2 * 1024 * 1024 else { throw SNESLibraryMenu.failure() }
        try write("manifest.json", plan)
        guard fsync(folder.fd) == 0, fsync(container.fd) == 0 else { throw RestoreDirectory.failure() }
        try container.check(); try folder.check()
        return try load(directory: folder.url, expectedReviewSHA256: BackupManifest.digest(plan), sourcePolicy: .live, candidateOnly: candidateOnly)
    }
    func validate(sourcePolicy: SNESLibrarySourcePolicy = .live) throws { _ = try Self.load(directory: directory, expectedReviewSHA256: reviewSHA256, sourcePolicy: sourcePolicy) }
    static func load(directory: URL, expectedReviewSHA256: String, sourcePolicy: SNESLibrarySourcePolicy = .live) throws -> Self {
        try load(directory: directory, expectedReviewSHA256: expectedReviewSHA256, sourcePolicy: sourcePolicy, candidateOnly: false)
    }
    static func loadCompatibilityCandidate(directory: URL, expectedReviewSHA256: String) throws -> Self {
        try load(directory: directory, expectedReviewSHA256: expectedReviewSHA256, sourcePolicy: .live, candidateOnly: true)
    }
    private static func load(directory: URL, expectedReviewSHA256: String, sourcePolicy: SNESLibrarySourcePolicy, candidateOnly: Bool) throws -> Self {
        try Task.checkCancellation()
        guard SNESDataSnapshotChunk.isDigest(expectedReviewSHA256) else { throw RestoreDirectory.failure() }
        let folder = try RestoreDirectory(directory), raw = try folder.read("manifest.json", maximum: 2 * 1024 * 1024)
        guard BackupManifest.digest(raw) == expectedReviewSHA256 else { throw RestoreDirectory.failure() }
        let plan = try JSONDecoder().decode(Plan.self, from: raw), m = plan.menu
        guard try SNESLibraryMenu.encode(plan) == raw, plan.version == 1, (candidateOnly ? [3,4].contains(m.version) : [1,2].contains(m.version)),
              folder.url.lastPathComponent == "SNES-Library-" + m.id.uuidString,
              m.graph.screens.count <= 32, m.files.count <= 2048, m.objects.count <= 1024,
              plan.sources.count <= 768, SNESDataSnapshotChunk.isDigest(m.catalogSHA256),
              Set(m.files.map(\.path)).count == m.files.count, Set(m.objects.map(\.name)).count == m.objects.count else { throw SNESLibraryMenu.failure() }
        try m.structure.validate()
        try m.graph.validate(selectedCodes: Set(m.graph.screens.flatMap(\.gameCodes)))
        let manifest = try SNESLibraryMenu.encode(m)
        guard manifest.count <= 1024 * 1024, try folder.read("menu.json", maximum: 1024 * 1024) == manifest else { throw SNESLibraryMenu.failure() }
        var names: Set<String> = ["manifest.json", "menu.json"], files: [String: Data] = [:], objects: [String: Data] = [:]
        var total = 0
        for record in m.objects {
            try record.validate(allowCompatibility: candidateOnly)
            let name = "object-" + record.name, data = try folder.read(name, maximum: 4 * 1024 * 1024 + (candidateOnly ? 512 : 96))
            guard data.count == record.byteCount, BackupManifest.digest(data) == record.sha256 else { throw SNESLibraryMenu.failure() }
            total += data.count; guard total <= 128 * 1024 * 1024 else { throw SNESLibraryMenu.failure() }
            objects[record.name] = data; names.insert(name)
        }
        for record in m.files {
            let maximum=try SNESLibraryMenu.fileLimit(record.path,version:m.version)
            guard (1...maximum).contains(record.byteCount), SNESDataSnapshotChunk.isDigest(record.sha256) else { throw SNESLibraryMenu.failure() }
            let name = "file-" + record.sha256, data = try folder.read(name, maximum: maximum)
            guard data.count == record.byteCount, BackupManifest.digest(data) == record.sha256 else { throw SNESLibraryMenu.failure() }
            if m.version >= 2 {total+=data.count};guard total<=128*1024*1024 else {throw SNESLibraryMenu.failure()}
            files[record.path] = data; names.insert(name)
        }
        guard Set(try folder.names()) == names else { throw SNESLibraryMenu.failure() }
        if sourcePolicy == .live { for source in plan.sources { try source.verify() } }
        try folder.check()
        let menu = SNESLibraryMenu(description: m, files: files, objects: objects, sources: plan.sources,
                                   manifest: manifest, sourceSHA256: BackupManifest.digest(try SNESLibraryMenu.encode(plan.sources)))
        try menu.validate()
        return .init(directory: folder.url, reviewSHA256: expectedReviewSHA256, menu: menu)
    }
}

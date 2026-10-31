import Foundation
import Darwin
import ImageIO
import SwiftHakchiCore

/// A local source seal, not console authority. Replacement is rejected even with identical bytes.
struct SNESLibrarySourceFile: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let device: Int32, inode: UInt64, mode: UInt16, links: UInt64, size: Int64
        let modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
        init(_ s: stat) {
            device = s.st_dev; inode = UInt64(s.st_ino); mode = s.st_mode; links = UInt64(s.st_nlink); size = s.st_size
            modified = Int64(s.st_mtimespec.tv_sec); modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
            changed = Int64(s.st_ctimespec.tv_sec); changedNanos = Int64(s.st_ctimespec.tv_nsec)
        }
    }
    let directory: String, name: String, sha256: String, byteCount: Int
    let parentDevice: Int32, parentInode: UInt64, identity: Identity
    static func capture(directory: URL, name: String, maximum: Int) throws -> (Self, Data) {
        guard maximum > 0, maximum <= 8 * 1024 * 1024, !name.isEmpty, name.utf8.count <= 255,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw RestoreDirectory.failure() }
        let parent = try RestoreDirectory(directory)
        var before = stat(), after = stat(), p = stat()
        guard fstat(parent.fd, &p) == 0, fstatat(parent.fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw RestoreDirectory.failure() }
        let data = try parent.read(name, maximum: maximum)
        guard fstatat(parent.fd, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(before) == Identity(after), data.count == before.st_size else { throw RestoreDirectory.failure() }
        try parent.check()
        return (.init(directory: parent.url.path, name: name, sha256: BackupManifest.digest(data), byteCount: data.count,
                      parentDevice: p.st_dev, parentInode: UInt64(p.st_ino), identity: Identity(before)), data)
    }
    func verify() throws {
        guard directory.hasPrefix("/"), directory.utf8.count <= 4096, !directory.contains("\0"),
              (0...8 * 1024 * 1024).contains(byteCount), SNESDataSnapshotChunk.isDigest(sha256) else { throw RestoreDirectory.failure() }
        guard try Self.capture(directory: URL(fileURLWithPath: directory), name: name, maximum: max(1, byteCount)).0 == self else {
            throw SNESLibraryCompatibility.failure("A game file changed. Prepare a new sync review.")
        }
    }
}

/// Deduplicates bytes by content identity; never creates hardlinks or contacts a console.
struct SNESLibraryObjects: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let name: String, byteCount: Int, sha256: String
        func validate(allowCompatibility: Bool = false) throws {
            let native = name == sha256 + ".sfrom"
            let compatibility = allowCompatibility && (name == sha256 + ".sfc" || name == sha256 + ".smc")
            let image = name.range(of: #"^[0-9a-f]{64}(_small)?\.png$"#, options: .regularExpression) != nil
            let maximum = native ? 4 * 1024 * 1024 + 96 : compatibility ? 4 * 1024 * 1024 + 512 : 262144
            guard SNESDataSnapshotChunk.isDigest(sha256), (native || compatibility || image),
                  byteCount > 0, byteCount <= maximum else { throw SNESLibraryMenu.failure() }
        }
    }
    struct Item: Sendable {
        let game: Game, rom: String, artwork: String, smallArtwork: String
        let saveCount: Int
    }
    let items: [String: Item], objects: [String: Data], sources: [SNESLibrarySourceFile]
    @MainActor static func prepare(review: SNESLibraryCompatibility, resolvedCodes: Set<String>) throws -> Self {
        guard resolvedCodes.isSubset(of: review.stockCodes.union(review.rows.map { $0.game.code })) else { throw SNESLibraryMenu.failure() }
        var items: [String: Item] = [:], objects: [String: Data] = [:], sources: [SNESLibrarySourceFile] = []
        var cache: [String: (large: Data, small: Data)] = [:]
        func object(_ data: Data, _ type: String) -> String {
            let name = BackupManifest.digest(data) + "." + type; objects[name] = data; return name
        }
        for row in review.rows.sorted(by: { $0.game.code < $1.game.code }) where resolvedCodes.contains(row.game.code) {
            try Task.checkCancellation()
            guard row.issue == nil, let prepared = row.prepared, let rom = row.source else { throw SNESLibraryMenu.failure() }
            try rom.verify()
            let game = row.game, directory = URL(fileURLWithPath: game.romPath)
            let sourceROM = try SNESLibrarySourceFile.capture(directory: directory, name: rom.filename, maximum: 4 * 1024 * 1024 + 512)
            guard sourceROM.0.sha256 == rom.sha256, sourceROM.0.byteCount == rom.byteCount else { throw SNESLibraryMenu.failure() }
            let metadata = try SNESLibrarySourceFile.capture(directory: directory, name: game.code + ".desktop", maximum: 16384)
            _ = try SNESOneGameMenu.fields(metadata.1)
            let disk = Game(code: game.code, desktopContent: String(decoding: metadata.1, as: UTF8.self), consoleType: .snesUsa, source: .local)
            guard disk.code == game.code, disk.name == game.name, disk.sortName == game.sortName, disk.publisher == game.publisher,
                  disk.releaseDate == game.releaseDate, disk.players == game.players, disk.saveCount == game.saveCount,
                  disk.simultaneous == game.simultaneous, disk.copyright == game.copyright else {
                throw SNESLibraryCompatibility.failure("Game details changed. Save your edits and prepare a new review.")
            }
            let art = try SNESLibrarySourceFile.capture(directory: directory, name: game.code + ".png", maximum: 8 * 1024 * 1024)
            let rendered: (large: Data, small: Data)
            if let hit = cache[art.0.sha256] { rendered = hit }
            else { rendered = try images(from: art.1); cache[art.0.sha256] = rendered }
            let names = storeImages(rendered, in: &objects)
            items[game.code] = .init(game: game, rom: object(prepared.data, "sfrom"), artwork: names.large,
                                     smallArtwork: names.small, saveCount: prepared.saveCount)
            sources += [sourceROM.0, metadata.0, art.0]
        }
        for source in sources { try source.verify() }
        return .init(items: items, objects: objects, sources: sources)
    }
    static func storeImages(_ images: (large: Data, small: Data), in objects: inout [String: Data]) -> (large: String, small: String) {
        // The pair address keeps the native Icon/_small naming convention without links.
        let address = BackupManifest.digest(Data((BackupManifest.digest(images.large) + ":" + BackupManifest.digest(images.small)).utf8))
        let large = address + ".png", small = address + "_small.png"
        objects[large] = images.large; objects[small] = images.small
        return (large, small)
    }
    static func images(from artwork: Data) throws -> (large: Data, small: Data) {
        let png = try GameArtworkStore.png(from: artwork)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SNESLibraryMenu.failure() }
        func scaled(_ width: Int, _ height: Int) throws -> Data {
            let ratio = min(1, min(Double(width) / Double(image.width), Double(height) / Double(image.height)))
            let w = max(1, Int(Double(image.width) * ratio)), h = max(1, Int(Double(image.height) * ratio))
            let data = resizeCoverArt(data: png, width: w, height: h)
            guard data.count <= 262144, let check = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil), decoded.width == w, decoded.height == h else { throw SNESLibraryMenu.failure() }
            return data
        }
        return (try scaled(228, 204), try scaled(40, 40))
    }
}

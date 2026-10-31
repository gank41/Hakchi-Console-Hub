import Foundation
import Darwin
import SwiftHakchiCore

struct StockRestorePlan: Codable, Sendable {
    let id: UUID
    let expectedHWID: String
    let preimageSHA256: String
    let preimageBytes: Int
    let stockSHA256: String
    let stockBytes: Int
    var schemaVersion = 1
    var scope = "Western-NES-boot2-hex30"
}
struct StockRestoreMaterial: Sendable {
    let plan: StockRestorePlan
    var stock: Data
    let preimage: Data

    func validateIntegrity() throws {
        guard plan.schemaVersion == 1, plan.scope == "Western-NES-boot2-hex30",
              plan.expectedHWID.count == 32, Self.hex(plan.expectedHWID),
              plan.expectedHWID.contains(where: { $0 != "0" }),
              stock.count == plan.stockBytes, preimage.count == plan.preimageBytes,
              BackupManifest.digest(stock) == plan.stockSHA256,
              BackupManifest.digest(preimage) == plan.preimageSHA256 else {
            throw RecoveryProbeError.refused("Restore plan identity, scope or frozen image digests did not verify.")
        }
        _ = try LegacyAndroidBootImage(data: stock)
        _ = try LegacyAndroidBootImage(data: preimage)
    }
    func validateForRestore() throws {
        try validateIntegrity()
        _ = try StockKernelEvidence(data: stock)
    }
    static func hex(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func load(snapshot: URL, stock: URL) throws -> Self {
        let directory = try RestoreDirectory(snapshot)
        struct Manifest: Decodable {
            let schemaVersion: Int
            let complete: Bool
            let probe: Probe
            struct Probe: Decodable {
                let observation: RecoveryProbeObservation
                let bootSnapshot: Snapshot
            }
            struct Snapshot: Decodable { let active: Image }
            struct Image: Decodable { let status: String; let byteCount: Int; let sha256: String }
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: directory.read("manifest.json", maximum: 65536))
        let image = try directory.read("active-boot2.img")
        guard manifest.schemaVersion == 1, manifest.complete,
              manifest.probe.observation.board == "dp-nes",
              manifest.probe.observation.kernel == "3.4.113.29-madmonkey",
              manifest.probe.bootSnapshot.active.status == "valid-boot-image",
              manifest.probe.bootSnapshot.active.byteCount == image.count,
              manifest.probe.bootSnapshot.active.sha256 == BackupManifest.digest(image) else {
            throw RecoveryProbeError.refused("A completed, matching Western NES snapshot is required.")
        }
        let stockDirectory = try RestoreDirectory(stock.deletingLastPathComponent())
        let stockBytes = try stockDirectory.read(stock.lastPathComponent)
        try directory.check(); try stockDirectory.check()
        let result = Self(plan: .init(id: UUID(), expectedHWID: manifest.probe.observation.hwid,
            preimageSHA256: BackupManifest.digest(image), preimageBytes: image.count,
            stockSHA256: BackupManifest.digest(stockBytes), stockBytes: stockBytes.count), stock: stockBytes, preimage: image)
        try result.validateForRestore()
        return result
    }
}

/// Descriptor ownership remains confined to a single actor or synchronous call.
final class RestoreDirectory {
    let url: URL
    private let handle: FileHandle
    var fd: Int32 { handle.fileDescriptor }
    init(_ url: URL) throws {
        let canonical = url.standardizedFileURL
        guard canonical == canonical.resolvingSymlinksInPath() else { throw Self.failure() }
        let opened = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard opened >= 0 else { throw Self.failure() }
        self.url = canonical; self.handle = FileHandle(fileDescriptor:opened,closeOnDealloc:true)
        do { try check() } catch { try? handle.close(); throw error }
    }
    deinit { try? handle.close() }
    func check() throws {
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, lstat(url.path, &named) == 0,
              named.st_mode & S_IFMT == S_IFDIR, held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              url == url.resolvingSymlinksInPath() else { throw Self.failure() }
    }
    func read(_ name: String, maximum: Int = LegacyAndroidBootImage.maximumSize) throws -> Data {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw Self.failure() }
        try check()
        let data = try RecoveryMaterialReader.readFile(directory: fd, name: name, maximumBytes: maximum)
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG else { throw Self.failure() }
        try check()
        return data
    }
    func names() throws -> [String] {
        // A new open description avoids shared readdir offsets when inspecting repeatedly.
        try check()
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard copy >= 0 else { throw Self.failure() }
        guard let stream = fdopendir(copy) else { close(copy); throw Self.failure() }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else { throw Self.failure() }; break
            }
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 4096 else { throw Self.failure() }
        }
        try check()
        return result.sorted()
    }
    static func failure() -> RecoveryProbeError {
        .refused("Restore operation storage is missing, linked, moved, corrupt, busy or not durably verified. Preserve it for inspection; do not retry a write.")
    }
}

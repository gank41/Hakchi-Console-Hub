import Foundation
import SwiftHakchiCore

struct SNESDataSnapshotPlan: Sendable {
    static let unit = 1024*1024, maximumChunkBytes = 8*unit
    let byteCount: Int, chunkCount: Int
    init(partitionSectors: UInt64) throws {
        guard partitionSectors >= 2048, partitionSectors <= 1048576, partitionSectors % 2048 == 0 else { throw SNESDataSnapshotError.refused }
        byteCount = Int(partitionSectors)*512
        chunkCount = (byteCount+Self.maximumChunkBytes-1)/Self.maximumChunkBytes
    }
    func range(_ index: Int) throws -> Range<Int> {
        guard (0..<chunkCount).contains(index) else { throw SNESDataSnapshotError.refused }
        let start = index*Self.maximumChunkBytes
        return start..<min(start+Self.maximumChunkBytes, byteCount)
    }
    static func name(_ index: Int) -> String { String(format: "data-%04d.bin", index) }
}
enum SNESDataSnapshotError: Error, LocalizedError {
    case refused
    var errorDescription: String? { "The console data backup did not pass its checks. Nothing was installed or changed." }
}
struct SNESDataSnapshotChunk: Sendable {
    let bytes: Data, sha256: String
    init(frame: Data, challenge: UUID, index: Int, count: Int) throws {
        guard (0..<64).contains(index), (1...SNESDataSnapshotPlan.maximumChunkBytes).contains(count),
              frame.count >= count, frame.count-count <= 512 else { throw SNESDataSnapshotError.refused }
        let raw = Data(frame) // Normalize potentially nonzero Data indices.
        guard let end = raw.prefix(256).firstIndex(of: 10),
              let header = String(data: raw[..<end], encoding: .ascii) else { throw SNESDataSnapshotError.refused }
        let fields = header.components(separatedBy: " ")
        guard fields.count == 5, fields[0] == "SWIFTHAKCHI_SNES_DATA_CHUNK_V1", fields[1] == challenge.uuidString,
              fields[2] == String(index), fields[3] == String(count), Self.isDigest(fields[4]),
              count <= raw.count-end-1 else { throw SNESDataSnapshotError.refused }
        let bodyEnd = end+1+count
        let footer = Data("\nSWIFTHAKCHI_SNES_DATA_END_V1 \(challenge.uuidString) \(index) \(fields[4])\n".utf8)
        guard raw.count-bodyEnd == footer.count, raw[bodyEnd...] == footer else { throw SNESDataSnapshotError.refused }
        let body = Data(raw[(end+1)..<bodyEnd])
        guard BackupManifest.digest(body) == fields[4] else { throw SNESDataSnapshotError.refused }
        bytes = body; sha256 = fields[4]
    }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func fullHash(_ raw: Data, challenge: UUID, count: Int) throws -> String {
        guard raw.count <= 256, let text = String(data: raw, encoding: .ascii) else { throw SNESDataSnapshotError.refused }
        let prefix = "SWIFTHAKCHI_SNES_DATA_HASH_V1 \(challenge.uuidString) \(count) "
        guard text.hasPrefix(prefix), text.hasSuffix("\n") else { throw SNESDataSnapshotError.refused }
        let hash = String(text.dropFirst(prefix.count).dropLast())
        guard isDigest(hash) else { throw SNESDataSnapshotError.refused }; return hash
    }
}

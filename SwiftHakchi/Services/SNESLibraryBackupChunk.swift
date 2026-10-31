import Foundation
import SwiftHakchiCore

/// One bounded binary reply, tied to a challenged file/offset. Capture also checks the complete file hash.
struct SNESLibraryBackupChunk: Sendable {
    static let maximumBytes = 256 * 1024
    let bytes: Data
    static func count(file: SNESLibraryInventory.File, offset: Int) throws -> Int {
        guard offset >= 0, offset % maximumBytes == 0, offset < file.byteCount,
              file.byteCount <= 16 * 1024 * 1024 else { throw SNESLibraryInventory.failure() }
        return min(maximumBytes, file.byteCount - offset)
    }
    init(raw: Data, file: SNESLibraryInventory.File, offset: Int, challenge: UUID, contextSHA256: String) throws {
        let count = try Self.count(file: file, offset: offset)
        guard raw.count <= count + 2048, SNESDataSnapshotChunk.isDigest(contextSHA256), SNESLibraryInventory.safePath(file.path) else { throw SNESLibraryInventory.failure() }
        let data = Data(raw)
        guard let end = data.prefix(1536).firstIndex(of: 10), let header = String(data: data[..<end], encoding: .ascii) else { throw SNESLibraryInventory.failure() }
        let fields = header.components(separatedBy: " "), path = Data(file.path.utf8).map { String(format: "%02x", $0) }.joined()
        guard fields.count == 7, fields[0] == "SWIFTHAKCHI_SNES_LIBRARY_CHUNK_V1", fields[1] == challenge.uuidString,
              fields[2] == contextSHA256, fields[3] == path, fields[4] == String(offset), fields[5] == String(count),
              SNESDataSnapshotChunk.isDigest(fields[6]), data.count >= end + 1 + count else { throw SNESLibraryInventory.failure() }
        let bodyEnd = end + 1 + count, footer = Data("\nSWIFTHAKCHI_SNES_LIBRARY_CHUNK_END_V1 \(challenge.uuidString) \(fields[6])\n".utf8)
        guard data.count - bodyEnd == footer.count, data[bodyEnd...] == footer else { throw SNESLibraryInventory.failure() }
        let body = Data(data[(end+1)..<bodyEnd])
        guard BackupManifest.digest(body) == fields[6] else { throw SNESLibraryInventory.failure() }; bytes = body
    }
}

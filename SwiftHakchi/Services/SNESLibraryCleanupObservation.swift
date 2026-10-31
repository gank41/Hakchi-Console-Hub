import Foundation
import SwiftHakchiCore

/// Inert read-only preview. Physical removal additionally needs its journal permit and fresh native checks.
struct SNESLibraryCleanupObservation: Sendable {
    struct Directory: Equatable, Sendable { let path: String, mode: Int, device: UInt64, inode: UInt64 }
    let raw: Data, challenge: UUID, contextSHA256: String, scopeSHA256: String, tokensSHA256: String
    let files: [SNESLibraryInventory.File?], directories: [Directory?], freeBytes: Int64, device: UInt64, measuredAt: Date
    var allGone: Bool { files.allSatisfy { $0 == nil } && directories.allSatisfy { $0 == nil } }
    var presentFileBytes: Int64 { files.compactMap { $0 }.reduce(0) { $0 + Int64($1.byteCount) } }
    init<Scope: SNESLibraryRetirementScope>(_ raw: Data, scope: Scope, challenge: UUID, contextSHA256: String, measuredAt: Date = Date()) throws {
        guard raw.count <= 2 * 1024 * 1024, SNESDataSnapshotChunk.isDigest(contextSHA256), let text = String(data: raw, encoding: .ascii),
              text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else { throw SNESLibraryInventory.failure() }
        let rows = text.components(separatedBy: "\n"), count = scope.fileTargets.count + scope.directories.count
        guard rows.count == 13 + count, rows[0] == "SWIFTHAKCHI_SNES_CLEANUP_PREVIEW_V1", rows[1] == "CHALLENGE=" + challenge.uuidString,
              rows[2] == "SCOPE=" + scope.reviewSHA256, rows[3] == "CONTEXT=" + contextSHA256, rows[4] == "HWID=" + scope.hwid,
              rows[5] == "SELECTOR=" + scope.selection.selectorSHA256, rows[6].hasPrefix("DEVICE="), rows[7].hasPrefix("FREE_BYTES="),
              rows[8] == "FILES=" + String(scope.fileTargets.count), rows[9] == "DIRS=" + String(scope.directories.count),
              rows[rows.count-2] == "END", rows.last == "" else { throw SNESLibraryInventory.failure() }
        func integer(_ text: String, maximum: Int64) throws -> Int64 {
            guard let number = Int64(text), number >= 0, number <= maximum, String(number) == text else { throw SNESLibraryInventory.failure() };return number
        }
        let device = UInt64(try integer(String(rows[6].dropFirst(7)), maximum: Int64(UInt32.max)))
        let free = try integer(String(rows[7].dropFirst(11)), maximum: scope.totalBytes)
        var files: [SNESLibraryInventory.File?] = [], directories: [Directory?] = [], seen = Set<String>()
        for (index, source) in scope.fileTargets.enumerated() {
            let fields = rows[10+index].components(separatedBy: " ")
            if fields == ["MISSING_FILE", String(index)] { files.append(nil);continue }
            guard fields.count == 9, fields[0] == "FILE", fields[1] == String(index), fields[2] == String(source.byteCount), fields[3] == source.sha256 else { throw SNESLibraryInventory.failure() }
            let mode = try integer(fields[4], maximum: 511), modified = try integer(fields[5], maximum: 4102444800)
            let dev = UInt64(try integer(fields[6], maximum: Int64(UInt32.max))), inode = UInt64(try integer(fields[7], maximum: Int64.max))
            let changed = try integer(fields[8], maximum: 4102444800)
            guard dev == device, inode > 0, seen.insert("\(dev):\(inode)").inserted else { throw SNESLibraryInventory.failure() }
            files.append(.init(path: source.path, byteCount: source.byteCount, sha256: source.sha256, mode: Int(mode), modified: modified,
                identity: .init(device: dev, inode: inode, changed: changed)))
        }
        for (index, path) in scope.directories.enumerated() {
            let fields = rows[10+scope.fileTargets.count+index].components(separatedBy: " ")
            if fields == ["MISSING_DIR", String(index)] { directories.append(nil);continue }
            guard fields.count == 5, fields[0] == "DIR", fields[1] == String(index) else { throw SNESLibraryInventory.failure() }
            let mode = try integer(fields[2], maximum: 511), dev = UInt64(try integer(fields[3], maximum: Int64(UInt32.max)))
            let inode = UInt64(try integer(fields[4], maximum: Int64.max))
            guard dev == device, inode > 0, seen.insert("\(dev):\(inode)").inserted else { throw SNESLibraryInventory.failure() }
            directories.append(.init(path: path, mode: Int(mode), device: dev, inode: inode))
        }
        let tokens = BackupManifest.digest(Data(rows[10..<10+count].joined(separator: "\n").utf8))
        guard rows[rows.count-3] == "TOKENS_SHA=" + tokens else { throw SNESLibraryInventory.failure() }
        self.raw = raw; self.challenge = challenge; self.contextSHA256 = contextSHA256; scopeSHA256 = scope.reviewSHA256; tokensSHA256 = tokens
        self.files = files; self.directories = directories; freeBytes = free; self.device = device; self.measuredAt = measuredAt
    }
}

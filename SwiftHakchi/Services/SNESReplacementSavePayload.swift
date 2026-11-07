import Foundation
import SwiftHakchiCore

/// Bounded transfer material for one complete native save set. Building this
/// value only reads verified Mac backups; it grants no console-write authority.
struct SNESReplacementSavePayload: Sendable {
    let table: Data, body: Data, tableSHA256: String, bodySHA256: String
    let challenge: UUID, reviewSHA256: String, destinationHWID: String
    let fileCount: Int, largestFileBytes: Int
    private static let maximumGroupBytes = 128 * 1024 * 1024

    static func prepare(review: SNESReplacementSaveEnvelope, group: Int, challenge: UUID) throws -> Self {
        let groups = try review.plan.protectedGroups()
        guard groups.indices.contains(group) else { throw SNESLibraryInventory.failure() }
        return try prepare(review: review, selectedPaths: groups[group].paths, challenge: challenge)
    }

    /// Prepare all complete new sets for one game as one bounded Mac-side
    /// payload. This does not authorize staging or publication on a console.
    static func prepareGame(review: SNESReplacementSaveEnvelope, gameCode: String, challenge: UUID) throws -> Self {
        let groups = try review.plan.protectedGroups().filter { $0.gameCode == gameCode }
        guard !groups.isEmpty, review.plan.gameCodes.contains(gameCode) else { throw SNESLibraryInventory.failure() }
        return try prepare(review: review, selectedPaths: groups.flatMap(\.paths), challenge: challenge)
    }

    private static func prepare(review: SNESReplacementSaveEnvelope, selectedPaths: [String], challenge: UUID) throws -> Self {
        try Task.checkCancellation(); try review.validate()
        let groups = try review.plan.protectedGroups(), files = review.plan.files
        guard !files.isEmpty, Set(files.map(\.path)).count == files.count else { throw SNESLibraryInventory.failure() }
        let groupedPaths = groups.flatMap(\.paths)
        guard groupedPaths.count == files.count, Set(groupedPaths) == Set(files.map(\.path)) else {
            throw SNESLibraryInventory.failure()
        }
        let entries = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let selected = selectedPaths.sorted()
        guard !selected.isEmpty, Set(selected).count == selected.count,
              Set(selected).isSubset(of: Set(groupedPaths)) else { throw SNESLibraryInventory.failure() }
        let hwid = review.plan.destinationInventory.hwid
        guard hwid.count == 32, SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else {
            throw SNESLibraryInventory.failure()
        }
        var lines = ["SWIFTHAKCHI_SNES_SAVE_GROUP_V1", "CHALLENGE \(challenge.uuidString)",
                     "HWID \(hwid)", "REVIEW \(review.sha256)", "FILES \(selected.count)"]
        var body = Data(), largest = 0
        for path in selected {
            try Task.checkCancellation()
            guard let entry = entries[path], (0...16 * 1024 * 1024).contains(entry.byteCount),
                  (0...511).contains(entry.sourceMode), (0...4102444800).contains(entry.sourceModified),
                  entry.byteCount <= Self.maximumGroupBytes - body.count else { throw SNESLibraryInventory.failure() }
            let bytes = try review.plan.read(path: path)
            guard bytes.count == entry.byteCount, BackupManifest.digest(bytes) == entry.sourceSHA256 else {
                throw SNESLibraryInventory.failure()
            }
            let encoded = path.utf8.map { String(format: "%02x", $0) }.joined()
            lines.append("FILE \(encoded) \(entry.byteCount) \(entry.sourceSHA256) \(entry.sourceMode) \(entry.sourceModified)")
            body.append(bytes)
            largest = max(largest, bytes.count)
        }
        lines.append("END")
        let table = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard table.count <= 4 * 1024 * 1024 else { throw SNESLibraryInventory.failure() }
        try review.validate()
        return .init(table: table, body: body, tableSHA256: BackupManifest.digest(table), bodySHA256: BackupManifest.digest(body),
                     challenge: challenge, reviewSHA256: review.sha256, destinationHWID: hwid,
                     fileCount: selected.count, largestFileBytes: largest)
    }
}

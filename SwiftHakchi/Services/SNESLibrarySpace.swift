import Foundation

/// Final metric from a separate fresh read, after potentially long inventory hashing.
struct SNESLibrarySpace: Sendable {
    let contextSHA256: String, hwid: String, measuredAt: Date, blockSize: Int64, totalBytes: Int64, freeBytes: Int64
    init(_ raw: Data, challenge: UUID, contextSHA256: String, hwid: String, measuredAt: Date = Date()) throws {
        guard raw.count <= 1024, let text = String(data: raw, encoding: .ascii), SNESDataSnapshotChunk.isDigest(contextSHA256),
              hwid.count == 32, SNESRuntimeBinding.hex(hwid) else { throw SNESLibraryInventory.failure() }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 6, lines[0] == "SWIFTHAKCHI_SNES_SPACE_V1 " + challenge.uuidString,
              lines[1] == "CONTEXT=" + contextSHA256, lines[2] == "HWID=" + hwid, lines[3].hasPrefix("SPACE="), lines[4] == "END", lines[5].isEmpty else { throw SNESLibraryInventory.failure() }
        let numbers = lines[3].dropFirst(6).components(separatedBy: " ")
        guard numbers.count == 3, let block = Int64(numbers[0]), let total = Int64(numbers[1]), let available = Int64(numbers[2]),
              numbers == [String(block), String(total), String(available)], (512...65536).contains(block), block.nonzeroBitCount == 1,
              total > 0, available >= 0, available <= total else { throw SNESLibraryInventory.failure() }
        let (bytes, overflow) = block.multipliedReportingOverflow(by: total)
        guard !overflow, bytes <= 512 * 1024 * 1024 else { throw SNESLibraryInventory.failure() }
        self.contextSHA256 = contextSHA256; self.hwid = hwid; self.measuredAt = measuredAt
        blockSize = block; totalBytes = bytes; freeBytes = available * block
    }
    func capacity(for inventory: SNESLibraryInventory) throws -> SNESLibraryCapacity.Inventory {
        guard inventory.contextSHA256 == contextSHA256, inventory.hwid == hwid, inventory.capacity.blockSize == blockSize,
              inventory.totalBytes == totalBytes else { throw SNESLibraryInventory.failure() }
        return .init(measuredAt: measuredAt, contextSHA256: contextSHA256, freeBytes: freeBytes, blockSize: blockSize,
            objects: inventory.capacity.objects, namespaceReady: inventory.capacity.namespaceReady,
            descriptionStoreReady: inventory.capacity.descriptionStoreReady)
    }
}

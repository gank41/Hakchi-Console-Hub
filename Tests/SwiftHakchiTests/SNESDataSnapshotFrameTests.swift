import Foundation
import SwiftHakchiCore
import Testing
@testable import SwiftHakchi

func snesDataFrame(_ body: Data, challenge: UUID, index: Int) -> Data {
    let hash = BackupManifest.digest(body)
    return Data("SWIFTHAKCHI_SNES_DATA_CHUNK_V1 \(challenge.uuidString) \(index) \(body.count) \(hash)\n".utf8) + body +
        Data("\nSWIFTHAKCHI_SNES_DATA_END_V1 \(challenge.uuidString) \(index) \(hash)\n".utf8)
}
struct SNESDataSnapshotFrameTests {
    @Test func plansTheEntirePartitionWithoutGaps() throws {
        let plan = try SNESDataSnapshotPlan(partitionSectors: 614400)
        #expect(plan.byteCount == 300*1024*1024)
        #expect(plan.chunkCount == 38)
        var end = 0
        for i in 0..<plan.chunkCount {
            let r = try plan.range(i)
            #expect(r.lowerBound == end && r.count > 0 && r.count <= 8*1024*1024)
            end = r.upperBound
        }
        #expect(end == plan.byteCount)
        #expect(try plan.range(37).count == 4*1024*1024)
        #expect(throws: (any Error).self) { try plan.range(-1) }
        #expect(throws: (any Error).self) { try plan.range(38) }
    }
    @Test(arguments: [UInt64(0), 1, 2047, 2049, 1048577, UInt64.max])
    func refusesUnsupportedSizes(sectors: UInt64) {
        #expect(throws: (any Error).self) { try SNESDataSnapshotPlan(partitionSectors: sectors) }
    }
    @Test func validatesExactBinaryBytesAndNormalizesDataIndices() throws {
        let data = Data([0, 10, 255, 128, 0, 65]), id = UUID()
        let framed = snesDataFrame(data, challenge: id, index: 2)
        let frame = (Data([7]) + framed).dropFirst()
        let value = try SNESDataSnapshotChunk(frame: frame, challenge: id, index: 2, count: data.count)
        #expect(value.bytes == data)
        #expect(value.sha256 == BackupManifest.digest(data))
    }
    @Test(arguments: ["challenge", "index", "count", "payload", "short", "extra", "footer", "noncanonical"])
    func refusesIncompleteChangedOrUnrelatedFrames(fault: String) {
        let data = Data([0, 1, 2, 3]), id = UUID()
        var raw = snesDataFrame(data, challenge: id, index: 0)
        var wantedID = id, wantedIndex = 0, wantedCount = data.count
        switch fault {
        case "challenge": wantedID = UUID()
        case "index": wantedIndex = 1
        case "count": wantedCount += 1
        case "payload": raw[raw.firstIndex(of: 10)!+2] ^= 1
        case "short": raw.removeLast()
        case "extra": raw.append(10)
        case "footer": raw[raw.count-5] = 0x7a
        default: raw = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: " 0 4 ", with: " 00 4 ").utf8)
        }
        #expect(throws: (any Error).self) { try SNESDataSnapshotChunk(frame: raw, challenge: wantedID, index: wantedIndex, count: wantedCount) }
    }
}

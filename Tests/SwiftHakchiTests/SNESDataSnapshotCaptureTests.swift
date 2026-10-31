import Foundation
import CryptoKit
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor SNESDataSnapshotFakeIO: SNESDataSnapshotIO {
    let source: SNESPreparationSource, base: SNESPreparationFakeIO, fault: String, plan: SNESDataSnapshotPlan
    let digest: String
    var chunks = 0, hashes = 0
    init(source: SNESPreparationSource, fault: String) throws {
        self.source = source; self.fault = fault
        base = SNESPreparationFakeIO(source: source, fault: fault)
        plan = try SNESDataSnapshotPlan(partitionSectors: StockRestorePartitions.dataSectors(String(decoding: source.partitions, as: UTF8.self)))
        var hash = SHA256()
        for i in 0..<plan.chunkCount {
            var data = Data(repeating: 0, count: try plan.range(i).count)
            if i == 0 { data.replaceSubrange(0..<source.header.count, with: source.header) }
            hash.update(data: data)
        }
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { if fault == "attachment", chunks > 0 { return [] }; return try await base.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await base.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await base.connect(expected: expected) }
    func observe() async throws -> String { await base.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await (base as any RecoveryProbeIO).readBoot2(slot) }
    func readBoot1() async throws -> Data { try await (base as any RecoveryProbeIO).readBoot1() }
    func readPartitions() async throws -> Data { try await (base as any RecoveryProbeIO).readPartitions() }
    func readDataSuperblock() async throws -> Data { try await (base as any RecoveryProbeIO).readDataSuperblock() }
    func disconnect() async { await base.disconnect() }
    func dataHash(challenge: UUID) -> Data {
        hashes += 1
        if fault == "hash" { return Data("incomplete".utf8) }
        let h = fault == "changed-hash" && hashes == 2 ? String(repeating: "1", count: 64) : digest
        return Data("SWIFTHAKCHI_SNES_DATA_HASH_V1 \(challenge.uuidString) \(plan.byteCount) \(h)\n".utf8)
    }
    func dataChunk(index: Int, challenge: UUID) throws -> Data {
        chunks += 1
        if fault == "cancel" { throw CancellationError() }
        if fault == "chunk" { return Data("partial".utf8) }
        var data = Data(repeating: 0, count: try plan.range(index).count)
        if index == 0 { data.replaceSubrange(0..<source.header.count, with: source.header) }
        return snesDataFrame(data, challenge: challenge, index: index)
    }
}
@Suite(.serialized)
struct SNESDataSnapshotCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil),
        arguments: ["none", "inventory", "boot", "connect", "identity", "mounted-data", "kernel", "boot1", "partitions", "header", "hash", "chunk", "attachment", "changed-hash", "cancel"])
    func validatesCurrentConsoleAndClosesExactlyOnce(fault: String) async throws {
        let available = try snesPreparationFixture()
        let source = try #require(available), io = try SNESDataSnapshotFakeIO(source: source, fault: fault)
        let pinned = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        if fault == "none" {
            let result = try await SNESDataSnapshotService(wait: {}).capture(source: source, inputs: inputs, io: io)
            let export = try result.checkedExport()
            #expect(result.chunks.count == 38)
            #expect(export.files["data-header.bin"] == source.header)
            #expect(export.files["data-0000.bin"]?.prefix(2048) == source.header)
            let m = try #require(JSONSerialization.jsonObject(with: export.manifest) as? [String: Any])
            #expect(m["complete"] as? Bool == true)
            #expect(m["firmwareWritten"] as? Bool == false)
            #expect(m["firmwareRestoreEligible"] as? Bool == false)
            let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESDataSnapshot(result)
            let checked = try SNESDataSnapshotPackage.load(directory: saved, expectedHWID: source.source.expectedHWID)
            #expect(checked.byteCount == 300*1024*1024)
            #expect(checked.sha256 == result.sha256)
            try checked.revalidate()
            #expect(throws: (any Error).self) { try SNESDataSnapshotPackage.load(directory: saved, expectedHWID: String(repeating: "1", count: 32)) }
            // Copy/link substitution, surplus files and edited safety flags cannot pass.
            let first = saved.appendingPathComponent("data-0000.bin")
            try FileManager.default.linkItem(at: first, to: root.appendingPathComponent("linked"))
            #expect(throws: (any Error).self) { try checked.revalidate() }
            try FileManager.default.removeItem(at: root.appendingPathComponent("linked"))
            try Data([1]).write(to: saved.appendingPathComponent("extra"))
            #expect(throws: (any Error).self) { try checked.revalidate() }
            try FileManager.default.removeItem(at: saved.appendingPathComponent("extra"))
            let manifest = saved.appendingPathComponent("manifest.json"), original = try Data(contentsOf: manifest)
            var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object["firmwareRestoreEligible"] = true
            try JSONSerialization.data(withJSONObject: object).write(to: manifest)
            #expect(throws: (any Error).self) { try checked.revalidate() }
            try original.write(to: manifest)
            try Data([0]).write(to: first)
            #expect(throws: (any Error).self) { try checked.revalidate() }

        } else {
            await #expect(throws: (any Error).self) { try await SNESDataSnapshotService(wait: {}).capture(source: source, inputs: inputs, io: io) }
        }
        let events = await io.base.events
        #expect(events.filter { $0 == "disconnect" }.count == 1)
        if ["inventory", "boot", "connect", "identity", "mounted-data", "kernel", "boot1", "partitions", "header", "hash"].contains(fault) { #expect(await io.chunks == 0) }
        if fault == "attachment" || fault == "chunk" || fault == "cancel" { #expect(await io.chunks == 1) }
    }
}

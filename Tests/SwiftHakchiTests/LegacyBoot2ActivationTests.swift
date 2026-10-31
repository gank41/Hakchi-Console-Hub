import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

private actor LegacyActivationSpy: LegacyBoot2ActivationIO {
    enum Failure: Error { case injected }
    let material: LegacyBoot2ActivationMaterial
    let journal: LegacyBoot2ActivationJournal
    let fault: String
    var events: [String] = []
    var inventories = 0, observations = 0, reads = 0

    init(_ material: LegacyBoot2ActivationMaterial, journal: LegacyBoot2ActivationJournal, fault: String) {
        self.material = material; self.journal = journal; self.fault = fault
    }
    func step(_ name: String) throws {
        events.append(name)
        if fault == name { throw Failure.injected }
    }
    func inventory() throws -> [RecoveryProbeUSBDevice] {
        try step("inventory"); inventories += 1
        return [inventories == 1 ? probeFEL() : probeRNDIS()]
    }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) throws { try step("boot") }
    func connect(expected: RecoveryProbeUSBDevice) throws { try step("connect") }
    func disconnect() { events.append("disconnect") }
    func observe() throws -> String {
        observations += 1
        try step("observe\(observations)")
        let actual = probeObservation().replacingOccurrences(
            of: "0123456789abcdef0123456789abcdef", with: material.plan.expectedHWID)
        return fault == "identity" ? actual.replacingOccurrences(of: material.plan.expectedHWID, with: String(repeating: "a", count: 32)) : actual
    }
    func readBoot2(_ slot: RecoveryBootSlot) throws -> RecoveryBoot2Read {
        reads += 1; try step("read\(reads)")
        if reads == 1 { return .image(fault == "preimage" ? material.legacy : material.stock) }
        return .image(fault == "readback" ? material.stock : material.legacy)
    }
    func verifyPartitions() throws { try step("partitions") }
    func stage(legacy: Data, id: UUID) throws {
        #expect(legacy == material.legacy && id == material.plan.id)
        try step("stage")
    }
    func burn(id: UUID, expectedSHA256: String, expectedBytes: Int) async throws {
        #expect(try await journal.phase() == .burnIntent)
        #expect(id == material.plan.id && expectedSHA256 == material.plan.legacySHA256 && expectedBytes == material.legacy.count)
        try step("burn")
    }
}

private func activationInputs() throws -> RecoveryBootInputs {
    let raw = try PinnedFELInputs.load()
    return .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage)
}

struct LegacyBoot2ActivationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil),
          arguments: ["none", "identity", "partitions", "preimage", "stage"])
    func preflightNeverBurns(fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let material = try knownLegacyActivationMaterial()
        let prepared = try LegacyBoot2ActivationJournal.prepare(material: material, root: root)
        let journal = try LegacyBoot2ActivationJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        let io = LegacyActivationSpy(material, journal: journal, fault: fault)
        let work = Task { try await LegacyBoot2Activation(wait: {}).run(journal: journal, inputs: activationInputs(), io: io, mode: .preflight) }
        if fault == "none" {
            try await work.value
            #expect(try await journal.phase() == .preflightVerified)
            #expect(await io.events == ["inventory", "boot", "inventory", "inventory", "connect", "observe1", "partitions", "read1", "stage", "observe2", "disconnect"])
        } else {
            await #expect(throws: (any Error).self) { try await work.value }
            #expect(try await journal.phase() == .stoppedBeforeWrite)
        }
        let events = await io.events
        #expect(!events.contains("burn") && events.last == "disconnect")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil),
          arguments: ["none", "burn", "read2", "readback", "observe3"])
    func writeNeedsDurableIntentAndExactReadback(fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let material = try knownLegacyActivationMaterial()
        let prepared = try LegacyBoot2ActivationJournal.prepare(material: material, root: root)
        let journal = try LegacyBoot2ActivationJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        try await journal.append(.preflightVerified)
        let io = LegacyActivationSpy(material, journal: journal, fault: fault)
        let runner = LegacyBoot2Activation(wait: {})
        let work = Task { try await runner.run(journal: journal, inputs: activationInputs(), io: io, mode: .write) }
        if fault == "none" {
            try await work.value
            #expect(try await journal.phase() == .readbackVerified)
        } else {
            await #expect(throws: (any Error).self) { try await work.value }
            #expect(try await journal.phase() == .uncertain)
        }
        let events = await io.events
        #expect(events.filter { $0 == "burn" }.count == 1 && events.last == "disconnect")
        let duplicate = LegacyActivationSpy(material, journal: journal, fault: "none")
        await #expect(throws: (any Error).self) { try await runner.run(journal: journal, inputs: activationInputs(), io: duplicate, mode: .write) }
        #expect(await duplicate.events.isEmpty)
    }
}

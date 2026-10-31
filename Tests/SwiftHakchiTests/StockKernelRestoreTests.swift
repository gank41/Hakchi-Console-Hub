import Foundation
import Testing
import SwiftHakchiCore
import os
import Darwin
@testable import SwiftHakchi

private actor RestoreSpy: StockRestoreIO {
    var events: [String] = []
    let material: StockRestoreMaterial
    let journal: StockRestoreJournal
    let fault: String?
    var inventories = 0, reads = 0, observations = 0
    init(_ material: StockRestoreMaterial, journal: StockRestoreJournal, fault: String? = nil) {
        self.material = material; self.journal = journal; self.fault = fault
    }
    enum Failure: Error { case injected }
    func step(_ name: String) throws {
        events.append(name)
        if fault == name { throw Failure.injected }
        if fault == "cancel-" + name { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func inventory() throws -> [RecoveryProbeUSBDevice] {
        try step("inventory"); inventories += 1
        return [inventories == 1 ? probeFEL() : probeRNDIS()]
    }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) throws { try step("boot") }
    func connect(expected: RecoveryProbeUSBDevice) throws { try step("connect") }
    func disconnect() { events.append("disconnect") }
    func observe() throws -> String {
        observations += 1; try step("observe\(observations)")
        return fault == "identity" ? probeObservation().replacingOccurrences(of: material.plan.expectedHWID, with: String(repeating:"a",count:32)) : probeObservation()
    }
    func verifyPartitions() throws { try step("partitions") }
    func stage(stock: Data, id: UUID) throws {
        try step("stage"); #expect(stock == material.stock && id == material.plan.id)
    }
    func burn(id: UUID, expectedSHA256: String, expectedBytes: Int) async throws {
        #expect(try await journal.phase() == .burnIntent)
        #expect(expectedSHA256 == material.plan.stockSHA256 && expectedBytes == material.stock.count)
        try step("burn")
    }
    func readBoot2(_ slot: RecoveryBootSlot) throws -> RecoveryBoot2Read {
        reads += 1; try step("read\(reads)")
        if fault == "unavailable" { return .unavailable }
        if reads == 1 { return .image(fault == "preimage" ? material.stock : material.preimage) }
        return .image(fault == "readback" ? material.preimage : material.stock)
    }
}
private func restoreInputs() throws -> RecoveryBootInputs {
    let raw = try PinnedFELInputs.load()
    return .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage)
}
struct StockKernelRestoreTests {
    @Test func unknownMaterialNeverOpensIO() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let material = restoreMaterialFixture(), p = try StockRestoreJournal.prepare(material:material,root:root)
        let j = try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256), io = RestoreSpy(material,journal:j)
        await #expect(throws:(any Error).self) { try await StockKernelRestore(wait:{}).run(journal:j,inputs:restoreInputs(),io:io,mode:.preflight) }
        #expect(await io.events.isEmpty)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil), arguments:["none","identity","partitions","preimage","unavailable","stage","observe2","cancel-stage"])
    func preflightNeverBurns(fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let material = try await knownRestoreMaterial(), p = try StockRestoreJournal.prepare(material:material,root:root)
        let j = try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256), io = RestoreSpy(material,journal:j,fault:fault)
        let task = Task { try await StockKernelRestore(wait:{}).run(journal:j,inputs:restoreInputs(),io:io,mode:.preflight) }
        if fault == "none" { try await task.value; #expect(try await j.phase() == .preflightVerified) }
        else { await #expect(throws:(any Error).self) { try await task.value }; #expect(try await j.phase() == .stoppedBeforeWrite) }
        let events = await io.events
        #expect(!events.contains("burn") && events.last == "disconnect")
        if fault == "none" { #expect(events == ["inventory","boot","inventory","inventory","connect","observe1","partitions","read1","stage","observe2","disconnect"]) }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil), arguments:["none","burn","read2","readback","observe3","cancel-burn","cancel-read2"])
    func oneBurnRequiresDurableIntentAndExactReadback(fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let material = try await knownRestoreMaterial(), p = try StockRestoreJournal.prepare(material:material,root:root)
        let j = try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
        try await j.append(.preflightVerified)
        let io = RestoreSpy(material,journal:j,fault:fault), runner = StockKernelRestore(wait:{})
        let task = Task { try await runner.run(journal:j,inputs:restoreInputs(),io:io,mode:.write) }
        if fault == "none" { try await task.value; #expect(try await j.phase() == .readbackVerified) }
        else { await #expect(throws:(any Error).self) { try await task.value }; #expect(try await j.phase() == .uncertain) }
        let events = await io.events
        #expect(events.filter{$0=="burn"}.count == 1 && events.last == "disconnect")
        let duplicate = RestoreSpy(material,journal:j)
        await #expect(throws:(any Error).self) { try await runner.run(journal:j,inputs:restoreInputs(),io:duplicate,mode:.write) }
        #expect(await duplicate.events.isEmpty)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func intentSyncFailurePreventsDispatch() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let material = try await knownRestoreMaterial(), p = try StockRestoreJournal.prepare(material:material,root:root)
        let syncs = OSAllocatedUnfairLock(initialState:0)
        let j = try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,synchronize:{fd in
            if syncs.withLock({$0 += 1;return $0}) == 4 { return -1 };return Darwin.fsync(fd)
        })
        try await j.append(.preflightVerified)
        let io = RestoreSpy(material,journal:j)
        await #expect(throws:(any Error).self) { try await StockKernelRestore(wait:{}).run(journal:j,inputs:restoreInputs(),io:io,mode:.write) }
        #expect(await !io.events.contains("burn"))
    }
}

private actor RestoreStageList {
    var values: [RecoveryStage] = []
    func add(_ stage: RecoveryStage) { values.append(stage) }
}
extension StockKernelRestoreTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func progressFollowsRealIntentAndReadback() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let material = try await knownRestoreMaterial(), prepared = try StockRestoreJournal.prepare(material:material,root:root)
        let journal = try StockRestoreJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256)
        try await journal.append(.preflightVerified)
        let io = RestoreSpy(material,journal:journal), stages = RestoreStageList()
        try await StockKernelRestore(wait:{}).run(journal:journal,inputs:restoreInputs(),io:io,mode:.write,progress:{ stage in
            if stage == .writingStock { let phase = try? await journal.phase(); #expect(phase == .burnIntent) }
            await stages.add(stage)
        })
        let values = await stages.values
        #expect(values == [.checkingMaterial,.checkingUSB,.uploadingRecovery,.waitingForRecovery,.checkingIdentity,
                           .checkingPartitions,.readingCurrentKernel,.stagingStock,.writingStock,.readingBack,.verifying,.closing])
        #expect(try await journal.phase() == .readbackVerified)
    }
}

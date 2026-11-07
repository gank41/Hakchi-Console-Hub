import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func menuSupportSourceFixture(root: URL) async throws -> SNESMenuSupportSource? {
    guard let original = try snesPreparationFixture() else { return nil }
    let launcher = Data("#!/bin/sh\nexit 0\n".utf8)
    let old = startupRecord("B", "usr/bin/clover-canoe-shvc", count: 1024, digest: String(repeating: "a", count: 64))
    let new = startupRecord("B", "usr/bin/clover-canoe-shvc", launcher)
    let frame = Data(String(decoding: startupFrameFixture(), as: UTF8.self)
        .replacingOccurrences(of: String(decoding: old, as: UTF8.self), with: String(decoding: new, as: UTF8.self)).utf8)
    let observation = try SNESBackupPolicy.observation(snesObservation().replacingOccurrences(of: runtimeBindingFixture().expectedHWID, with: original.source.expectedHWID))
    let prep = SNESRecoveryPreparation(source: original, startup: try SNESStartupFrame(frame), header: original.header,
                                       before: probeFEL(), after: probeRNDIS(), observation: observation)
    let url = try await RecoveryBootSnapshotStore(root: root).saveSNESPreparation(prep)
    return try SNESMenuSupportSource.load(setup: original.source, preparation: url)
}
actor MenuSupportFakeIO: SNESMenuSupportIO {
    let base: SNESPreparationFakeIO, fault: String
    let sourceURL: URL
    var captures = 0
    init(source: SNESMenuSupportSource, fault: String = "none") {
        base = SNESPreparationFakeIO(source: source.preparation.source, fault: fault); self.fault = fault; sourceURL = source.directoryURL
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await base.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await base.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await base.connect(expected: expected) }
    func observe() async throws -> String {
        if fault == "final-observation" && captures == 2 { throw RecoveryProbeError.refused("fixture final observation failure") }
        return await base.observe()
    }
    func readBoot2(_ slot: RecoveryBootSlot) async -> RecoveryBoot2Read { await base.menuKernel(slot) }
    func readPartitions() async -> Data { await base.menuPartitions() }
    func disconnect() async { await base.disconnect() }
    func readSupport() async throws -> Data {
        captures += 1
        if fault == "task-cancel" { try await Task.sleep(for: .seconds(30)) }
        if fault == "final-source" && captures == 2 { try Data([1]).write(to: sourceURL.appendingPathComponent("startup.frame")) }
        if fault == "cancel" { throw CancellationError() }
        if fault == "transport" || fault == "empty" || (fault == "second-transport" && captures == 2) {
            throw SNESStartupTransportFailure(frame: fault == "empty" ? Data() : Data("partial".utf8), stageLog: Data())
        }
        if fault == "truncated" { return Data(menuSupportFixture().dropLast()) }
        if fault == "launcher" { return menuSupportFixture(launcher: Data("different".utf8)) }
        if fault == "changed" && captures == 2 { return menuSupportFixture() + Data([0]) }
        return menuSupportFixture()
    }
}
@Suite(.serialized)
struct SNESMenuSupportCaptureTests {
    @Test func failedFinalPackageVerificationCannotLeaveCompleteManifest() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        guard let source=try await menuSupportSourceFixture(root:root) else { return }
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let result=try await SNESMenuSupportService(wait:{}).capture(source:source,inputs:inputs,io:MenuSupportFakeIO(source:source))
        let store=try RecoveryBootSnapshotStore(root:root)
        await #expect(throws:(any Error).self) {
            try await store.saveSNESMenuSupport(result,verify:{_ in throw RecoveryProbeError.refused("verification failed")})
        }
        let folders=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.lastPathComponent.hasPrefix("SNES-Menu-Support-")}
        #expect(folders.count==1)
        #expect(folders.allSatisfy{!FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path)})
    }
    @Test(arguments: ["none", "inventory", "boot", "connect", "identity", "mounted-data", "nested-mount", "kernel", "second-kernel", "partitions", "truncated", "launcher", "transport", "second-transport", "empty", "changed", "cancel"])
    func oneSessionChecksSourceAndClosesOnEveryOutcome(fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await menuSupportSourceFixture(root: root) else { return }
        let pinned = try PinnedFELInputs.load(), io = MenuSupportFakeIO(source: source, fault: fault)
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        if fault == "none" {
            let result = try await SNESMenuSupportService(wait: {}).capture(source: source, inputs: inputs, io: io)
            #expect(result.frame.raw == menuSupportFixture())
            #expect(await io.captures == 2)
            let exported = try result.checkedExport()
            #expect(exported.files["support.frame"] == menuSupportFixture())
        } else {
            await #expect(throws: (any Error).self) { _ = try await SNESMenuSupportService(wait: {}).capture(source: source, inputs: inputs, io: io) }
        }
        let events = await io.base.events
        #expect(events.filter { $0 == "disconnect" }.count == 1)
        #expect(events.filter { $0 == "boot" }.count == (fault == "inventory" ? 0 : 1))
        #expect(!events.contains("stage"))
        if ["inventory", "boot", "connect", "identity", "mounted-data", "nested-mount", "kernel", "second-kernel", "partitions"].contains(fault) { #expect(await io.captures == 0) }
    }
    @Test func alteredPreparationCannotCompleteOrOpenUSB() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await menuSupportSourceFixture(root: root) else { return }
        let io = MenuSupportFakeIO(source: source), pinned = try PinnedFELInputs.load()
        try Data([1]).write(to: source.directoryURL.appendingPathComponent("startup.frame"))
        #expect(throws: (any Error).self) { try source.revalidate() }
        await #expect(throws: (any Error).self) {
            _ = try await SNESMenuSupportService(wait: {}).capture(source: source,
                inputs: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), io: io)
        }
        #expect(await io.base.events.isEmpty)
    }
    @Test func changingSourceDuringExportLeavesNoCompletion() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await menuSupportSourceFixture(root: root) else { return }
        let pinned = try PinnedFELInputs.load()
        let result = try await SNESMenuSupportService(wait: {}).capture(source: source,
            inputs: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), io: MenuSupportFakeIO(source: source))
        let store = try RecoveryBootSnapshotStore(root: root, synchronize: { fd in
            try? Data([1]).write(to: source.directoryURL.appendingPathComponent("startup.frame")); return fsync(fd)
        })
        await #expect(throws: (any Error).self) { _ = try await store.saveSNESMenuSupport(result) }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("SNES-Menu-Support-") }
        #expect(folders.count == 1)
        #expect(!FileManager.default.fileExists(atPath: try #require(folders.first).appendingPathComponent("manifest.json").path))
    }
    @Test func reentrancyRefusedBeforeSecondInventory() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await menuSupportSourceFixture(root: root) else { return }
        let gate = MenuSupportGate(), service = SNESMenuSupportService(wait: {}), pinned = try PinnedFELInputs.load()
        let first = MenuSupportFakeIO(source: source), second = MenuSupportFakeIO(source: source)
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        let task = Task { try await service.capture(source: source, inputs: inputs, io: first, progress: { if $0 == .readingCurrentKernel { await gate.pause() } }) }
        await gate.waitUntilPaused()
        await #expect(throws: (any Error).self) { _ = try await service.capture(source: source, inputs: inputs, io: second) }
        #expect(await second.base.events.isEmpty)
        await gate.release(); _ = try await task.value
    }
    @Test func malformedPreparationManifestIsRejected() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await menuSupportSourceFixture(root: root) else { return }
        let url = source.directoryURL.appendingPathComponent("manifest.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["firmwareWritten"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(throws: (any Error).self) { _ = try SNESMenuSupportSource.load(setup: source.preparation.source.source, preparation: source.directoryURL) }
    }
}
private actor MenuSupportGate {
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?, resume: CheckedContinuation<Void, Never>?
    func pause() async { paused = true; waiter?.resume(); waiter = nil; await withCheckedContinuation { resume = $0 } }
    func waitUntilPaused() async { if !paused { await withCheckedContinuation { waiter = $0 } } }
    func release() { resume?.resume(); resume = nil }
}

extension SNESPreparationFakeIO {
    func menuKernel(_ slot: RecoveryBootSlot) -> RecoveryBoot2Read { readBoot2(slot) }
    func menuPartitions() -> Data { readPartitions() }
}

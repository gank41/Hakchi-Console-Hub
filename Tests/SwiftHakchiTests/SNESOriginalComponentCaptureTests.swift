import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func originalComponentSourceFixture(root: URL) async throws -> SNESOriginalComponentSource? {
    guard let original = try snesPreparationFixture() else { return nil }
    let files = originalComponentFiles(), launcher = Data("#!/bin/sh\nexit 0\n".utf8)
    var dirs: Set<String> = []
    for name in originalComponentPaths.dropLast() {
        var parent = (name as NSString).deletingLastPathComponent
        while parent != "lib/modules" { dirs.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
    }
    var modules: [String: Data] = Dictionary(uniqueKeysWithValues: dirs.map { ($0, startupRecord("D", $0)) })
    for name in originalComponentPaths.dropLast() { modules[name] = startupRecord("M", name, files[name]!) }
    var raw = startupFrameFixture(modules: modules.keys.sorted().reduce(Data()) { $0 + modules[$1]! })
    let old = startupRecord("B", "usr/bin/clover-canoe-shvc", count: 1024, digest: String(repeating: "a", count: 64))
    raw.replaceSubrange(try #require(raw.range(of: old)), with: startupRecord("B", "usr/bin/clover-canoe-shvc", launcher))
    let observation = try SNESBackupPolicy.observation(snesObservation().replacingOccurrences(of: runtimeBindingFixture().expectedHWID, with: original.source.expectedHWID))
    let prep = SNESRecoveryPreparation(source: original, startup: try SNESStartupFrame(raw), header: original.header,
        before: probeFEL(), after: probeRNDIS(), observation: observation)
    let store = try RecoveryBootSnapshotStore(root: root), prepURL = try await store.saveSNESPreparation(prep)
    let source = try SNESMenuSupportSource.load(setup: original.source, preparation: prepURL)
    var supportRaw = menuSupportFixture(launcher: launcher)
    let mcp = "usr/bin/clover-mcp"
    let oldMCP = startupRecord("B", mcp, count: 128)
    supportRaw.replaceSubrange(try #require(supportRaw.range(of: oldMCP)), with: startupRecord("B", mcp, files[mcp]!))
    let support = SNESMenuSupportResult(source: source, frame: try SNESMenuSupportFrame(supportRaw), before: probeFEL(), after: probeRNDIS(), observation: observation)
    let folder = try await store.saveSNESMenuSupport(support)
    return try SNESOriginalComponentSource(material: SNESMenuSupportMaterial.load(source: source, directory: folder))
}
actor OriginalComponentFakeIO: SNESOriginalComponentIO {
    let base: SNESPreparationFakeIO, source: SNESOriginalComponentSource, fault: String
    var reads = 0
    init(source: SNESOriginalComponentSource, fault: String = "none") {
        self.source = source; self.fault = fault; base = SNESPreparationFakeIO(source: source.material.source.preparation.source, fault: fault)
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await base.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await base.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await base.connect(expected: expected) }
    func observe() async throws -> String {
        if fault == "final-observation" && reads == 2 { throw SNESOriginalComponentFrame.failure() }
        let text = await base.observe()
        if fault == "alternate-data" { return text.replacingOccurrences(of: "MOUNTS_END", with: "/dev/nandc /capture-data ext4 ro 0 0\nMOUNTS_END") }
        return text
    }
    func readBoot2(_ slot: RecoveryBootSlot) async -> RecoveryBoot2Read { await base.menuKernel(slot) }
    func readPartitions() async -> Data { await base.menuPartitions() }
    func disconnect() async { await base.disconnect() }
    func readComponents() async throws -> Data {
        reads += 1
        if fault == "task-cancel" { try await Task.sleep(for: .seconds(30)) }
        if fault == "cancel" { throw CancellationError() }
        if fault == "transport" || fault == "empty" || fault == "second-transport" && reads == 2 {
            throw SNESStartupTransportFailure(frame: fault == "empty" ? Data() : Data("partial".utf8), stageLog: Data("fixture transport\n".utf8))
        }
        if fault == "source" && reads == 2 { try Data([1]).write(to: source.material.directoryURL.appendingPathComponent("support.frame")) }
        if fault == "truncated" { return Data(originalComponentFrame().dropLast()) }
        if fault == "different" && reads == 2 { var f = originalComponentFiles(); f[originalComponentPaths[0]] = Data([1]); return originalComponentFrame(f) }
        if fault == "inventory-mismatch" { var f = originalComponentFiles(); f[originalComponentPaths[0]] = Data([1]); return originalComponentFrame(f) }
        return originalComponentFrame()
    }
}
@Suite(.serialized)
struct SNESOriginalComponentCaptureTests {
    @Test func failedFinalVerificationRemovesCompletedComponentManifest() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        guard let source=try await originalComponentSourceFixture(root:root) else { return }
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let result=try await SNESOriginalComponentService(wait:{}).capture(source:source,inputs:inputs,io:OriginalComponentFakeIO(source:source))
        let store=try RecoveryBootSnapshotStore(root:root)
        await #expect(throws:(any Error).self) {
            try await store.saveSNESOriginalComponents(result,verify:{_ in throw RecoveryProbeError.refused("verification failed")})
        }
        let folders=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.lastPathComponent.hasPrefix("SNES-Original-Components-")}
        #expect(folders.count==1)
        #expect(folders.allSatisfy{!FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path)})
    }
    @Test(arguments: ["none", "inventory", "boot", "connect", "identity", "mounted-data", "kernel", "partitions", "truncated", "inventory-mismatch", "transport", "second-transport", "empty", "different", "source", "final-observation", "cancel"])
    func captureChecksTwoReadsAndClosesOnce(fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await originalComponentSourceFixture(root: root) else { return }
        let io = OriginalComponentFakeIO(source: source, fault: fault), pinned = try PinnedFELInputs.load()
        let service = SNESOriginalComponentService(wait: {})
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        if fault == "none" {
            let result = try await service.capture(source: source, inputs: inputs, io: io)
            #expect(await io.reads == 2)
            let export = try result.checkedExport()
            #expect(export.files["components.frame"] == originalComponentFrame())
            let folder = try await RecoveryBootSnapshotStore(root: root).saveSNESOriginalComponents(result)
            #expect(try SNESOriginalComponentMaterial.load(source: source, directory: folder).frame.raw == originalComponentFrame())
            let manifest = try #require(JSONSerialization.jsonObject(with: export.manifest) as? [String: Any])
            #expect(manifest["firmwareWritten"] as? Bool == false && manifest["firmwareRestoreEligible"] as? Bool == false)
        } else {
            do { _ = try await service.capture(source: source, inputs: inputs, io: io); Issue.record("Accepted a failed component capture") }
            catch is CancellationError { #expect(fault == "cancel") }
            catch let failure as SNESOriginalComponentFailure {
                let folder = try await RecoveryBootSnapshotStore(root: root).saveSNESOriginalComponentFailure(failure)
                #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
                if ["source", "final-observation"].contains(fault) { #expect(failure.frame == originalComponentFrame()) }
                if ["transport", "second-transport"].contains(fault) { #expect(failure.frame == Data("partial".utf8)) }
            }
        }
        let events = await io.base.events
        #expect(events.filter { $0 == "disconnect" }.count == 1)
        #expect(events.filter { $0 == "boot" }.count <= 1)
        #expect(!events.contains("stage"))
    }
    @Test func changedSourceDuringProgressStopsBeforeBoot() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await originalComponentSourceFixture(root: root) else { return }
        let io = OriginalComponentFakeIO(source: source), pinned = try PinnedFELInputs.load()
        await #expect(throws: (any Error).self) {
            try await SNESOriginalComponentService(wait: {}).capture(source: source,
                inputs: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), io: io,
                progress: { if $0 == .uploadingRecovery { try? Data([1]).write(to: source.material.directoryURL.appendingPathComponent("support.frame")) } })
        }
        #expect(!(await io.base.events).contains("boot"))
    }
    @Test func sourceChangeAtManifestCommitPreventsCompletion() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await originalComponentSourceFixture(root: root) else { return }
        let io = OriginalComponentFakeIO(source: source), pinned = try PinnedFELInputs.load()
        let result = try await SNESOriginalComponentService(wait: {}).capture(source: source,
            inputs: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), io: io)
        let store = try RecoveryBootSnapshotStore(root: root, synchronize: { fd in
            try? Data([1]).write(to: source.material.directoryURL.appendingPathComponent("support.frame")); return fsync(fd)
        })
        await #expect(throws: (any Error).self) { _ = try await store.saveSNESOriginalComponents(result) }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("SNES-Original-Components-") }
        let folder = try #require(folders.first)
        #expect(folders.count == 1 && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
    }
}

private actor OriginalComponentGate {
    private var paused = false
    private var entered: CheckedContinuation<Void, Never>?, waiting: CheckedContinuation<Void, Never>?
    func pause() async { paused = true; entered?.resume(); entered = nil; await withCheckedContinuation { waiting = $0 } }
    func waitUntilPaused() async { if !paused { await withCheckedContinuation { entered = $0 } } }
    func release() { waiting?.resume(); waiting = nil }
}
extension SNESOriginalComponentCaptureTests {
    @Test func reentrancyIsRefusedWithoutTouchingTheSecondIO() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await originalComponentSourceFixture(root: root) else { return }
        let first = OriginalComponentFakeIO(source: source), second = OriginalComponentFakeIO(source: source)
        let gate = OriginalComponentGate(), service = SNESOriginalComponentService(wait: {}), pinned = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        let running = Task { try await service.capture(source: source, inputs: inputs, io: first,
            progress: { if $0 == .readingCurrentKernel { await gate.pause() } }) }
        await gate.waitUntilPaused()
        await #expect(throws: (any Error).self) { _ = try await service.capture(source: source, inputs: inputs, io: second) }
        #expect(await second.base.events.isEmpty)
        await gate.release(); _ = try await running.value
    }
    @Test func acceptedRealInventoriesHaveTheApprovedPins() throws {
        guard let material = try privateMenuSupportMaterial() else { return }
        let source = try SNESOriginalComponentSource(material: material)
        #expect(source.expected.map(\.count) == [11316,187884,5528,5392,137688])
        #expect(source.expected.map(\.digest) == [
            "0c41deaa23584a86822f6083f024c4a61686f2380470eca2c057a433e6727f12",
            "60137b270bbcecff871323858009104130c8df174f6b3cd74ccbfb11dbd2227a",
            "1ed3d81adb3e964df9904df0ef9a3e331c885e41634453fd98c14c0b0f365a67",
            "e50262274baf4feef644adc5f89a9ce8bea068b80351c02e798a89b1ca5e0f43",
            "dff55752d9c101ff175a9d6b9c31022e1dd6304392a190cdd6e3be36f013946c"])
    }
}

extension SNESOriginalComponentCaptureTests {
    @Test func everyPreparationAndSupportFileRemainsBoundAfterLoading() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await originalComponentSourceFixture(root: root) else { return }
        var paths = ["manifest.json", "stock.img", "boot1.bin", "partitions.txt", "data-header.bin", "startup.frame"].map { source.material.source.directoryURL.appendingPathComponent($0) }
        paths += ["manifest.json", "support.frame"].map { source.material.directoryURL.appendingPathComponent($0) }
        for path in paths {
            let original = try Data(contentsOf: path)
            try Data([1]).write(to: path)
            #expect(throws: (any Error).self) { try source.revalidate() }
            try original.write(to: path)
            try source.revalidate()
        }
    }
}

extension SNESOriginalComponentCaptureTests {
    @Test func dataMountedReadOnlyElsewhereCannotBeCapturedOrExported() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let source = try await originalComponentSourceFixture(root: root) else { return }
        let io = OriginalComponentFakeIO(source: source, fault: "alternate-data"), pinned = try PinnedFELInputs.load()
        await #expect(throws: (any Error).self) {
            _ = try await SNESOriginalComponentService(wait: {}).capture(source: source,
                inputs: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), io: io)
        }
        #expect(await io.reads == 0)
        #expect((await io.base.events).filter { $0 == "disconnect" }.count == 1)
        let observation = try SNESBackupPolicy.observation(snesObservation().replacingOccurrences(of: runtimeBindingFixture().expectedHWID, with: source.material.setup.expectedHWID))
        for mount in ["/dev/nandc /capture-data ext4 ro 0 0", "/dev/mapper/data /alternate ext4 ro 0 0", "/dev/root /other squashfs ro 0 0"] {
            let changed = RecoveryProbeObservation(kernel: observation.kernel, board: observation.board,
                hwid: observation.hwid, mounts: observation.mounts + [mount])
            let result = SNESOriginalComponentResult(source: source, frame: try SNESOriginalComponentFrame(originalComponentFrame()),
                before: probeFEL(), after: probeRNDIS(), observation: changed)
            #expect(throws: (any Error).self) { _ = try result.checkedExport() }
        }
    }
}

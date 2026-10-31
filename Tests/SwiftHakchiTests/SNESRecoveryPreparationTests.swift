import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func snesPreparationFixture() throws -> SNESPreparationSource? {
    guard let path = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] else { return nil }
    return try SNESPreparationSource.load(SNESOfflineSource.load(snapshot: URL(fileURLWithPath: path)))
}
actor SNESPreparationFakeIO: SNESPreparationIO {
    let source: SNESPreparationSource, fault: String
    var events: [String] = [], inventories = 0, reads = 0, observations = 0
    init(source: SNESPreparationSource, fault: String = "none") { self.source = source; self.fault = fault }
    func inventory() throws -> [RecoveryProbeUSBDevice] {
        events.append("inventory"); inventories += 1
        if fault == "inventory" { throw RecoveryProbeError.refused("fixture inventory failure") }
        return inventories == 1 ? [probeFEL()] : [probeRNDIS()]
    }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) throws {
        events.append("boot"); if fault == "boot" { throw RecoveryProbeError.refused("fixture boot failure") }
    }
    func connect(expected: RecoveryProbeUSBDevice) throws {
        events.append("connect"); if fault == "connect" { throw RecoveryProbeError.refused("fixture connect failure") }
    }
    func observe() -> String {
        events.append("observe"); observations += 1
        var text = snesObservation().replacingOccurrences(of: runtimeBindingFixture().expectedHWID, with: source.source.expectedHWID)
        if fault == "identity" || (fault == "final-identity" && observations > 2) { text = text.replacingOccurrences(of: "HWID=", with: "HWID=1") }
        if fault == "mounted-data" { text = text.replacingOccurrences(of: "MOUNTS_END", with: "/dev/nandc /var/lib ext4 rw 0 0\nMOUNTS_END") }
        if fault == "nested-mount" { text = text.replacingOccurrences(of: "MOUNTS_END", with: "tmpfs /newroot/etc/init.d tmpfs rw 0 0\nMOUNTS_END") }
        return text
    }
    func disconnect() { events.append("disconnect") }
    func readBoot2(_ slot: RecoveryBootSlot) -> RecoveryBoot2Read {
        events.append("kernel"); reads += 1
        return .image(fault == "kernel" || (fault == "second-kernel" && reads == 2) ? Data([1]) : source.stock)
    }
    func readBoot1() -> Data { events.append("boot1"); return fault == "boot1" ? Data([1]) : source.boot1 }
    func readPartitions() -> Data { events.append("partitions"); return fault == "partitions" ? Data([1]) : source.partitions }
    func readDataSuperblock() -> Data {
        events.append("header")
        let data = fault == "header" ? Data(count: 2048) : source.header
        return Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(data))\n".utf8) + data
    }
    func stageStock(_ data: Data, id: UUID) throws {
        events.append("stage"); #expect(data == source.stock)
        if fault == "stage" { throw RecoveryProbeError.refused("fixture stage failure") }
    }
    func readStartup() async throws -> Data {
        events.append("startup")
        if fault == "cancel" { throw CancellationError() }
        let second = events.filter { $0 == "startup" }.count == 2
        if fault == "transport-first" || fault == "transport-empty" || (fault == "transport-second" && second) {
            return try await SNESStartupReceipt.capture {
                BoundedSSHExecution(stdout: fault == "transport-empty" ? Data() : Data("partial".utf8),
                    stderr: fault == "transport-empty" ? Data() : Data("reading-text\n".utf8), exitCode: 0, transportCode: -5)
            }
        }
        if fault == "startup" { return Data("rejected".utf8) }
        if fault == "changed-startup", events.filter({ $0 == "startup" }).count == 2 { return startupFrameFixture() + Data([0]) }
        return startupFrameFixture()
    }
}
@Suite(.serialized)
struct SNESRecoveryPreparationTests {
    @Test func sourceChangedDuringDurableSaveLeavesNoCompletionManifest() async throws {
        guard let original = try snesPreparationFixture() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent(original.source.snapshotName)
        try FileManager.default.copyItem(at: original.source.directoryURL, to: copy)
        let source = try SNESPreparationSource.load(SNESOfflineSource.load(snapshot: copy))
        let pinned = try PinnedFELInputs.load()
        let result = try await SNESRecoveryPreparationService(wait: {}).capture(source: source,
            inputs: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), io: SNESPreparationFakeIO(source: source))
        let store = try RecoveryBootSnapshotStore(root: root, synchronize: { fd in
            try? Data([1]).write(to: copy.appendingPathComponent("boot1.bin"))
            return fsync(fd)
        })
        await #expect(throws: (any Error).self) { try await store.saveSNESPreparation(result) }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("SNES-Recovery-Preparation-") }
        #expect(folders.count == 1)
        #expect(FileManager.default.fileExists(atPath: try #require(folders.first).appendingPathComponent("manifest.json").path) == false)
    }
    @Test func changedMacSourceCannotCompleteExport() async throws {
        guard let original = try snesPreparationFixture() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent(original.source.snapshotName)
        try FileManager.default.copyItem(at: original.source.directoryURL, to: copy)
        let source = try SNESPreparationSource.load(SNESOfflineSource.load(snapshot: copy))
        let pinned = try PinnedFELInputs.load()
        let result = try await SNESRecoveryPreparationService(wait: {}).capture(source: source,
            inputs: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage), io: SNESPreparationFakeIO(source: source))
        try Data([1]).write(to: copy.appendingPathComponent("boot1.bin"))
        #expect(throws: (any Error).self) { try result.checkedExport() }
    }
    @Test func overlappingPreparationCannotOpenAnotherSession() async throws {
        guard let source = try snesPreparationFixture() else { return }
        let pinned = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        let gate = PreparationTestGate(), service = SNESRecoveryPreparationService(wait: {})
        let first = SNESPreparationFakeIO(source: source), second = SNESPreparationFakeIO(source: source)
        let task = Task { try await service.capture(source: source, inputs: inputs, io: first, progress: { if $0 == .readingCurrentKernel { await gate.pause() } }) }
        await gate.waitUntilPaused()
        await #expect(throws: (any Error).self) { _ = try await service.capture(source: source, inputs: inputs, io: second) }
        #expect(await second.events.isEmpty)
        await gate.release(); _ = try await task.value
    }
    @Test(arguments: ["none", "bytes", "owner", "linked", "helper"])
    func ownedRAMStageRequiresExactStockAndPositiveCheck(fault: String) throws {
        guard let source = try snesPreparationFixture() else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try Data("rootfs / rootfs rw 0 0\n".utf8).write(to: root.appendingPathComponent("mounts"))
        let helper = root.appendingPathComponent("sntool")
        try Data(("#!/bin/sh\ntest \"$1\" = check && test -f \"$2\" || exit 22\nexit " + (fault == "helper" ? "1\n" : "0\n")).utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        func run(_ command: String) throws -> (Int32, Data) {
            let rewritten = "sha256sum() { /usr/bin/shasum -a 256 \"$@\"; }\nstat() { /usr/bin/stat -f '%l' \"$3\"; }\n" + command
                .replacingOccurrences(of: StockRestoreCommands.pins, with: "true")
                .replacingOccurrences(of: SNESPreparationCommands.directory, with: "./stage")
                .replacingOccurrences(of: "/bin/sntool", with: "./sntool")
                .replacingOccurrences(of: "/proc/mounts", with: "./mounts")
                .replacingOccurrences(of: "test -d /tmp && test ! -L /tmp", with: "test -d '\(root.path)' && test ! -L '\(root.path)'")
            let p = Process(), output = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.currentDirectoryURL = root
            p.arguments = ["-c", rewritten]; p.standardOutput = output; p.standardError = FileHandle.nullDevice
            try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, bytes)
        }
        let created = try run(SNESPreparationCommands.create(id: id))
        #expect(created.0 == 0 && created.1 == Data(SNESPreparationCommands.created(id: id).utf8))
        let stock = root.appendingPathComponent("stage/stock.img")
        try (fault == "bytes" ? Data([0]) : source.stock).write(to: stock)
        if fault == "owner" { try Data(UUID().uuidString.utf8).write(to: root.appendingPathComponent("stage/owner")) }
        if fault == "linked" { try FileManager.default.linkItem(at: stock, to: root.appendingPathComponent("other")) }
        let checked = try run(SNESPreparationCommands.checkedStage(id: id))
        if fault == "none" { #expect(checked.0 == 0); #expect(checked.1 == Data(SNESPreparationCommands.staged(id: id).utf8)) }
        else { #expect(checked.0 != 0); #expect(checked.1.isEmpty) }
        #expect(throws: (any Error).self) { try StockRestoreCompletion.require(.init(stdout: "", stderr: "", stdoutData: Data(), exitCode: 0), marker: SNESPreparationCommands.staged(id: id)) }
    }
    @Test(arguments: ["none", "inventory", "boot", "connect", "identity", "mounted-data", "nested-mount", "kernel", "second-kernel", "boot1", "partitions", "header", "stage", "startup", "changed-startup", "final-identity", "cancel"])
    func preparationChecksSourceBeforeStageAndClosesOnce(fault: String) async throws {
        guard let source = try snesPreparationFixture() else { return }
        let io = SNESPreparationFakeIO(source: source, fault: fault)
        let pinned = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        if fault == "none" {
            let result = try await SNESRecoveryPreparationService(wait: {}).capture(source: source, inputs: inputs, io: io)
            let export = try result.checkedExport()
            #expect(export.files["stock.img"] == source.stock)
            #expect(export.files["startup.frame"] == startupFrameFixture())
            let manifest = try #require(JSONSerialization.jsonObject(with: export.manifest) as? [String: Any])
            #expect(manifest["complete"] as? Bool == true)
            #expect(manifest["firmwareWritten"] as? Bool == false)
            #expect(manifest["firmwareRestoreEligible"] as? Bool == false)
        } else {
            await #expect(throws: (any Error).self) { _ = try await SNESRecoveryPreparationService(wait: {}).capture(source: source, inputs: inputs, io: io) }
        }
        let events = await io.events
        #expect(events.filter { $0 == "boot" }.count == (fault == "inventory" ? 0 : 1))
        #expect(events.filter { $0 == "disconnect" }.count == 1)
        if ["inventory", "boot", "connect", "identity", "mounted-data", "nested-mount", "kernel", "second-kernel", "boot1", "partitions", "header"].contains(fault) {
            #expect(events.contains("stage") == false)
        }
        if fault == "none" {
            #expect(events.filter { $0 == "startup" }.count == 2)
            #expect(try #require(events.firstIndex(of: "stage")) < #require(events.firstIndex(of: "startup")))
        }
    }
}

private actor PreparationTestGate {
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?, resume: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { resume = $0 }
    }
    func waitUntilPaused() async { if !paused { await withCheckedContinuation { waiter = $0 } } }
    func release() { resume?.resume(); resume = nil }
}

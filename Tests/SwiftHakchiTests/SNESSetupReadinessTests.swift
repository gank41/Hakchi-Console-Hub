import Foundation
import Testing
@testable import SwiftHakchi
import SwiftHakchiCore

private func setupHeader(dirty: Bool = false) -> Data {
    var bytes = Data(repeating: 0, count: 2048)
    for (offset, value) in [(1028, UInt32(100_000)), (1036, UInt32(24_000)), (1048, UInt32(2))] {
        for i in 0..<4 { bytes[offset+i] = UInt8((value >> (i*8)) & 255) }
    }
    bytes[1080] = 0x53; bytes[1081] = 0xef; bytes[1082] = dirty ? 0 : 1
    return bytes
}
private func setupFrame(_ bytes: Data) -> Data {
    Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8) + bytes
}
private actor SNESSetupIO: RecoveryProbeIO {
    var events: [String] = []
    let fault: String
    private var observations = 0, activeReads = 0, boot1Reads = 0, partitionReads = 0
    init(fault: String = "none") { self.fault = fault }
    func inventory() -> [RecoveryProbeUSBDevice] { events.append("inventory"); return events.count == 1 ? [probeFEL()] : [probeRNDIS()] }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { events.append("boot") }
    func connect(expected: RecoveryProbeUSBDevice) { events.append("connect") }
    func disconnect() { events.append("disconnect") }
    func observe() -> String {
        events.append("observe"); observations += 1
        var text = snesObservation()
        if fault == "board" { text = text.replacingOccurrences(of: "dp-shvc", with: "dp-nes") }
        if fault == "region" { text = text.replacingOccurrences(of: "REGION=USA", with: "REGION=EUR") }
        if observations == 3 {
            if fault == "identity" { text = text.replacingOccurrences(of: "HWID=012", with: "HWID=112") }
            if fault == "mount" { text = text.replacingOccurrences(of: "ro,noatime", with: "rw,noatime") }
        }
        return text
    }
    func readBoot2(_ slot: RecoveryBootSlot) -> RecoveryBoot2Read {
        events.append(slot == .active ? "active" : "backup")
        if slot == .backup { return .unavailable }
        activeReads += 1
        var bytes = snapshotFixture()
        if fault == "kernelMismatch" && activeReads == 2 { bytes[2048] ^= 1 }
        return .image(bytes)
    }
    func readBoot1() throws -> Data {
        events.append("boot1"); boot1Reads += 1
        if fault == "readFailed" { throw RecoveryProbeError.refused("test read failure") }
        if fault == "cancel" { throw CancellationError() }
        if fault == "emptyBoot1" { return Data() }
        if fault == "oversizedBoot1" { return Data(repeating: 1, count: RecoveryBoot1Read.maximumSize + 1) }
        return Data(repeating: fault == "boot1Mismatch" && boot1Reads == 2 ? 2 : 1, count: 4096)
    }
    func readPartitions() -> Data {
        events.append("partitions"); partitionReads += 1
        let text = legacyPartitionsFixture()
        if fault == "badPartitions" { return Data(text.replacingOccurrences(of: "nandc:data:", with: "nandc:other:").utf8) }
        if fault == "changedPartitions" && partitionReads == 2 { return Data((text + "\n").utf8) }
        return Data(text.utf8)
    }
    func readDataSuperblock() -> Data {
        events.append("header")
        let frame = setupFrame(setupHeader(dirty: fault == "dirty"))
        return fault == "headerTruncated" ? Data(frame.dropLast()) : frame
    }
}

private func captureSetup(_ io: SNESSetupIO) async throws -> SNESSetupReadinessReport {
    let raw = try PinnedFELInputs.load()
    return try await SNESSetupReadinessService(wait: {}).capture(
        inputs: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage), io: io)
}

struct SNESSetupReadinessTests {
    @Test func separateSNESDiagnosticModeUsesSameReadOnlyServiceAndPrivateStore() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try RecoveryDiagnosticOptions.parse(["--snapshot-snes-setup", root.path]) == .snesSetup(root.path))
        for args in [["--snapshot-snes-setup"], ["--snapshot-snes-setup", "relative"],
                     ["--snapshot-snes-setup", root.path, "--boot-recovery"]] {
            #expect(throws: (any Error).self) { try RecoveryDiagnosticOptions.parse(args) }
        }
        let raw = try PinnedFELInputs.load(), io = SNESSetupIO()
        let output = try await RecoveryDiagnosticRunner.run(mode: .snesSetup(root.path),
            inputs: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage), makeIO: { io }, checkHost: {})
        let result = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let path = try #require(result["snapshotDirectory"] as? String)
        #expect(result["firmwareRestoreEligible"] as? Bool == false)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("manifest.json").path))
        #expect(await io.events.filter { $0 == "boot" }.count == 1)
        #expect(await io.events.last == "disconnect")
        #expect(!output.contains("0123456789abcdef"))
    }

    @Test func diagnosticHostOwnershipFailurePreventsAnyUSBAction() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = try PinnedFELInputs.load(), io = SNESSetupIO()
        await #expect(throws: (any Error).self) {
            try await RecoveryDiagnosticRunner.run(mode: .snesSetup(root.path),
                inputs: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage), makeIO: { io },
                checkHost: { throw RecoveryProbeError.refused("Another app owns USB") })
        }
        #expect(await io.events.isEmpty)
    }

    @Test func unsupportedHeaderCanBeSavedOnlyAsPrivateIncompleteDiagnostic() async throws {
        let io = SNESSetupIO(fault: "dirty")
        var captured: SNESSetupDiagnosticFailure?
        do { _ = try await captureSetup(io); Issue.record("Expected an incomplete storage check") }
        catch let failure as SNESSetupDiagnosticFailure { captured = failure }
        catch { Issue.record("Expected a bounded diagnostic capture") }
        let failure = try #require(captured)
        #expect(await io.events.last == "disconnect")
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESSetupDiagnostic(failure)
        #expect(saved.lastPathComponent.hasPrefix("SNES-US-Setup-Diagnostic-"))
        #expect(try Data(contentsOf: saved.appendingPathComponent("data-header-frame.bin")) == setupFrame(setupHeader(dirty: true)))
        #expect(try Data(contentsOf: saved.appendingPathComponent("active-boot2.img")) == snapshotFixture())
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: saved.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["complete"] as? Bool == false)
        #expect(manifest["firmwareRestoreEligible"] as? Bool == false)
        #expect(manifest["status"] as? String == "incomplete-storage-check")
        #expect(manifest["kernel"] == nil)
        let text = try String(contentsOf: saved.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(!text.contains("valid-boot-image-read-twice"))
        let attr = try FileManager.default.attributesOfItem(atPath: saved.appendingPathComponent("data-header-frame.bin").path)
        #expect((attr[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func reportConstructionRejectsUnsafeRecoveryMetadataBeforeExport() throws {
        let accepted = try SNESBackupPolicy.observation(snesObservation())
        for observation in [
            RecoveryProbeObservation(kernel: "unknown", board: accepted.board, hwid: accepted.hwid, mounts: accepted.mounts),
            RecoveryProbeObservation(kernel: accepted.kernel, board: accepted.board, hwid: accepted.hwid,
                mounts: accepted.mounts + ["/dev/nandc /other ext4 rw 0 0"]),
            RecoveryProbeObservation(kernel: accepted.kernel, board: accepted.board, hwid: accepted.hwid,
                mounts: accepted.mounts + ["/dev/nandc /var/lib ext4 ro 0 0"]),
            RecoveryProbeObservation(kernel: accepted.kernel, board: accepted.board, hwid: accepted.hwid,
                mounts: accepted.mounts + ["tmpfs /tmp tmpfs rw 0 0"])
        ] {
            let kernel = SNESKernelBackupReport(before: probeFEL(), after: probeRNDIS(), observation: observation,
                active: snapshotFixture(), backup: nil)
            #expect(throws: (any Error).self) {
                try SNESSetupReadinessReport(kernel: kernel, boot1: Data([1]),
                    partitions: Data(legacyPartitionsFixture().utf8), headerFrame: setupFrame(setupHeader()))
            }
        }
    }

    @Test(arguments: [1116, 1120, 1124])
    func unknownFilesystemFeaturesCannotProduceCompletedPreparation(offset: Int) throws {
        var bytes = setupHeader(); bytes[offset+3] = 0x80
        let kernel = SNESKernelBackupReport(before: probeFEL(), after: probeRNDIS(),
            observation: try SNESBackupPolicy.observation(snesObservation()), active: snapshotFixture(), backup: nil)
        #expect(throws: (any Error).self) {
            try SNESSetupReadinessReport(kernel: kernel, boot1: Data([1]),
                partitions: Data(legacyPartitionsFixture().utf8), headerFrame: setupFrame(bytes))
        }
    }

    @Test func checkedReadsUseOneSessionWithoutPersistentMountOrWriter() async throws {
        let io = SNESSetupIO(), result = try await captureSetup(io)
        #expect(result.kernel.active == snapshotFixture())
        #expect(result.kernel.backup == nil)
        #expect(result.boot1.data == Data(repeating: 1, count: 4096))
        #expect(result.dataHeader == setupHeader())
        #expect(result.dataSuperblock.isClean)
        #expect(result.partitions == Data(legacyPartitionsFixture().utf8))
        #expect(!result.firmwareRestoreEligible)
        #expect(await io.events == ["inventory", "boot", "inventory", "inventory", "connect", "observe", "observe",
            "active", "backup", "boot1", "boot1", "partitions", "header", "active", "partitions", "observe", "disconnect"])
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains(Data(repeating: 1, count: 4096).base64EncodedString()))
        #expect(!json.contains(snapshotFixture().base64EncodedString()))
        #expect(json.contains("raw-unvalidated") && json.contains("false"))
    }

    @Test(arguments: ["board", "region", "identity", "mount", "kernelMismatch", "boot1Mismatch", "emptyBoot1",
        "oversizedBoot1", "badPartitions", "changedPartitions", "headerTruncated", "dirty", "readFailed", "cancel"])
    func failedChecksAlwaysCloseWithoutRetry(fault: String) async throws {
        let io = SNESSetupIO(fault: fault)
        await #expect(throws: (any Error).self) { try await captureSetup(io) }
        #expect(await io.events.last == "disconnect")
        #expect(await io.events.filter { $0 == "boot" }.count == 1)
    }

    @Test func privateExportPreservesRawEvidenceAndDoesNotGrantRestore() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let report = try await captureSetup(SNESSetupIO())
        let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESSetup(report)
        #expect(saved.lastPathComponent.hasPrefix("SNES-US-Setup-"))
        let expected = ["active-boot2.img": snapshotFixture(), "boot1.bin": report.boot1.data,
                        "partitions.txt": report.partitions, "data-header.bin": setupHeader()]
        for (name, bytes) in expected {
            #expect(try Data(contentsOf: saved.appendingPathComponent(name)) == bytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: saved.appendingPathComponent(name).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: saved.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["schemaVersion"] as? Int == 1)
        #expect(manifest["console"] as? String == "snes-usa")
        #expect(manifest["complete"] as? Bool == true)
        #expect(manifest["firmwareRestoreEligible"] as? Bool == false)
        let capture = try #require(manifest["capture"] as? [String: Any])
        let partitions = try #require(capture["partitions"] as? [String: Any])
        #expect(partitions["sha256"] as? String == BackupManifest.digest(report.partitions))
        let files = try FileManager.default.contentsOfDirectory(atPath: saved.path)
        #expect(!files.contains("backup-boot2.img"))
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func incompleteExportHasNoCompletedManifestAndPriorBackupSurvives() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let report = try await captureSetup(SNESSetupIO())
        let prior = try await RecoveryBootSnapshotStore(root: root).saveSNES(report.kernel)
        let failing = try RecoveryBootSnapshotStore(root: root, synchronize: { _ in -1 })
        await #expect(throws: (any Error).self) { try await failing.saveSNESSetup(report) }
        #expect(FileManager.default.fileExists(atPath: prior.appendingPathComponent("manifest.json").path))
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(children.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) } == [prior])
    }
}

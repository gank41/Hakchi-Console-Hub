import Foundation
import Testing
@testable import SwiftHakchi

func snesObservation() -> String {
    probeObservation().replacingOccurrences(of: "SWIFTHAKCHI_RAM_PROBE_V1", with: "SWIFTHAKCHI_SNES_PROBE_V1")
        .replacingOccurrences(of: "BOARD=dp-nes\nNES_DIRECTORY=1", with: "BOARD=dp-shvc\nREGION=USA\nSNES_DIRECTORY=1\nNES_DIRECTORY=0")
}
actor SNESBackupIO: RecoveryProbeIO {
    private(set) var events: [String] = []
    var observations = 0, reads = 0
    let fault: String?
    init(fault: String? = nil) { self.fault = fault }
    func inventory() -> [RecoveryProbeUSBDevice] { events.append("inventory"); return events.count == 1 ? [probeFEL()] : [probeRNDIS()] }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { events.append("boot") }
    func connect(expected: RecoveryProbeUSBDevice) { events.append("connect") }
    func disconnect() { events.append("disconnect") }
    func observe() -> String {
        events.append("observe"); observations += 1
        var text = snesObservation()
        if fault == "board" { text = text.replacingOccurrences(of: "dp-shvc", with: "dp-nes") }
        if fault == "identity" && observations == 3 { text = text.replacingOccurrences(of: "HWID=012", with: "HWID=112") }
        if fault == "mount" && observations == 3 { text = text.replacingOccurrences(of: "ro,noatime", with: "rw,noatime") }
        return text
    }
    func readBoot2(_ slot: RecoveryBootSlot) throws -> RecoveryBoot2Read {
        events.append(slot == .active ? "active" : "backup")
        if fault == "cancel" { throw CancellationError() }
        if slot == .backup { return .unavailable }
        reads += 1
        if fault == "unavailable" { return .unavailable }
        var bytes = snapshotFixture()
        if fault == "truncated" { bytes.removeLast() }
        if fault == "mismatch" && reads == 2 { bytes[2048] ^= 1 }
        return .image(bytes)
    }
}
struct SNESKernelBackupTests {
    @Test func observationIsStrictAndNESPolicyDoesNotAcceptIt() throws {
        let valid = snesObservation()
        #expect(try SNESBackupPolicy.observation(valid).board == "dp-shvc")
        #expect(throws: (any Error).self) { try RecoveryProbePolicy.observation(valid) }
        for (from, to) in [("dp-shvc", "dp-snes"), ("REGION=USA", "REGION=EUR"),
            ("SNES_DIRECTORY=1", "SNES_DIRECTORY=0"), ("NES_DIRECTORY=0", "NES_DIRECTORY=1"),
            ("hakchi-memboot", "hakchi-install"), ("ro,noatime", "rw,noatime"),
            ("3.4.113.29-madmonkey", "unknown"), ("HWID=012", "HWID=xyz"),
            ("MOUNTS_END", "/dev/nandc /other ext4 rw 0 0\nMOUNTS_END"),
            ("MOUNTS_END", "/dev/nandc /var/lib ext4 ro 0 0\nMOUNTS_END"),
            ("REGION=USA", "REGION=USA\nREGION=USA")] {
            #expect(throws: (any Error).self) { try SNESBackupPolicy.observation(valid.replacingOccurrences(of: from, with: to)) }
        }
    }
    @Test func backupReadsActiveTwiceAndClosesBeforeReturning() async throws {
        let io = SNESBackupIO(), raw = try PinnedFELInputs.load()
        let result = try await SNESKernelBackupService(wait: {}).capture(inputs: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage), io: io)
        #expect(result.active == snapshotFixture())
        #expect(result.backup == nil)
        #expect(!result.firmwareRestoreEligible)
        #expect(await io.events == ["inventory", "boot", "inventory", "inventory", "connect", "observe", "observe", "active", "backup", "active", "observe", "disconnect"])
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(json.contains("unavailable") && !json.contains("QU5EUk9JRC"))
    }
    @Test(arguments: ["board", "identity", "mount", "unavailable", "truncated", "mismatch", "cancel"])
    func failuresCloseWithoutRetryOrCompletion(fault: String) async throws {
        let io = SNESBackupIO(fault: fault), raw = try PinnedFELInputs.load()
        await #expect(throws: (any Error).self) {
            try await SNESKernelBackupService(wait: {}).capture(inputs: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage), io: io)
        }
        #expect(await io.events.last == "disconnect")
        #expect(await io.events.filter { $0 == "boot" }.count == 1)
    }
    @Test func privateStoreCompletesOnlyAfterVerifiedWrites() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try PinnedFELInputs.load()
        let result = try await SNESKernelBackupService(wait: {}).capture(inputs: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage), io: SNESBackupIO())
        let store = try RecoveryBootSnapshotStore(root: root)
        let saved = try await store.saveSNES(result)
        #expect(try Data(contentsOf: saved.appendingPathComponent("active-boot2.img")) == snapshotFixture())
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: saved.appendingPathComponent("manifest.json"))) as? [String: Any]
        #expect(manifest?["complete"] as? Bool == true)
        #expect(manifest?["firmwareRestoreEligible"] as? Bool == false)
        let failed = try RecoveryBootSnapshotStore(root: root, synchronize: { _ in -1 })
        await #expect(throws: (any Error).self) { try await failed.saveSNES(result) }
        let manifests = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
        #expect(manifests.count == 1)
    }
}

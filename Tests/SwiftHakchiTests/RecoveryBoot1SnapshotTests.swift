import Foundation
import Testing
import Darwin
import os
@testable import SwiftHakchi
import SwiftHakchiCore

private func boot1Fixture() -> Data { Data(repeating: 0x5a, count: 761856) }
private func boot1Frame(_ bytes: Data) -> Data {
    Data("SWIFTHAKCHI_BOOT1_V1 \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8) + bytes
}

private actor Boot1EvidenceIO: RecoveryProbeIO {
    var events: [String] = []
    let changeIdentity: Bool
    private var observations = 0
    init(changeIdentity: Bool = false) { self.changeIdentity = changeIdentity }
    func inventory() -> [RecoveryProbeUSBDevice] { events.append("inventory"); return events.count == 1 ? [probeFEL()] : [probeRNDIS()] }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { events.append("boot") }
    func connect(expected: RecoveryProbeUSBDevice) { events.append("connect") }
    func observe() -> String {
        observations += 1; events.append("observe")
        let value = probeObservation()
        return changeIdentity && observations == 3 ? value.replacingOccurrences(of:"HWID=012",with:"HWID=112") : value
    }
    func readBoot2(_ slot: RecoveryBootSlot) -> RecoveryBoot2Read { events.append(slot == .active ? "active" : "backup"); return slot == .active ? .image(snapshotFixture()) : .unavailable }
    func readBoot1() -> Data { events.append("boot1"); return boot1Fixture() }
    func disconnect() { events.append("disconnect") }
}

struct RecoveryBoot1SnapshotTests {
    @Test func boot1FrameRequiresExactBytesLengthAndDigest() throws {
        let bytes = boot1Fixture()
        #expect(try RecoveryBoot1Read.parse(boot1Frame(bytes)) == bytes)
        var changed = boot1Frame(bytes); changed[changed.count - 1] ^= 1
        for invalid in [Data(), changed, Data(boot1Frame(bytes).dropLast()),
                        boot1Frame(bytes) + Data([0]), Data("SWIFTHAKCHI_BOOT1_V1 0 \(String(repeating:"a", count:64))\n".utf8),
                        Data("SWIFTHAKCHI_BOOT1_V1 8388609 \(String(repeating:"a", count:64))\n".utf8)] {
            #expect(throws: (any Error).self) { try RecoveryBoot1Read.parse(invalid) }
        }
    }

    @Test func pinnedBoot1ReadIsBoundedAndNeverUsesBurn() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture"), log = root.appendingPathComponent("calls")
        try boot1Fixture().write(to: fixture)
        let tool = root.appendingPathComponent("reader")
        try Data("#!/bin/sh\nprintf '%s %s\\n' \"$1\" \"$2\" >> \"$NES_READ_LOG\"\ntest \"$1\" = read_boot1 || exit 8\ntest \"$NES_READ_FAIL\" = no || exit 1\ncat \"$NES_READ_FIXTURE\"\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let command = RecoveryBoot1SnapshotCommand.read
        #expect(command.contains("read_boot1 8"))
        for forbidden in ["burn_boot", "mount ", "install ", "reboot", "hakchi "] { #expect(!command.contains(forbidden)) }
        for fail in ["no", "yes"] {
            try? FileManager.default.removeItem(at: log)
            let script = command.replacingOccurrences(of: "/bin/sunxi-flash", with: LaunchCommand.shellQuote(tool.path))
                .replacingOccurrences(of: "/tmp/swifthakchi-boot1.XXXXXX", with: root.appendingPathComponent("ram.XXXXXX").path)
            let stubs = #"""
            sha256sum() { if [ "$1" = /bin/sntool ]; then printf 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9  tool\n'; else /usr/bin/shasum -a 256 "$@"; fi; }
            """#
            let process = Process(), out = Pipe(), err = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", stubs + "\n" + script]
            process.environment = ProcessInfo.processInfo.environment.merging(["NES_READ_LOG":log.path,"NES_READ_FIXTURE":fixture.path,"NES_READ_FAIL":fail]) { _,new in new }
            process.standardOutput = out; process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            #expect((process.terminationStatus == 0) == (fail == "no"))
            #expect(try String(contentsOf: log, encoding: .utf8) == "read_boot1 8\n")
            if fail == "no" { #expect(try RecoveryBoot1Read.parse(output) == boot1Fixture()) }
            else { #expect(output.isEmpty) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix("ram.") }) == false)
        }
    }

    @Test func installEvidenceUsesOneBoundSessionAndPrivateDistinctExport() async throws {
        let io = Boot1EvidenceIO(), raw = try PinnedFELInputs.load()
        let report = try await RecoveryRAMProbe(wait: {}).run(
            inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),
            io:io,captureInstallEvidence:true)
        #expect(report.boot1Snapshot?.data == boot1Fixture())
        #expect(report.bootSnapshot?.active == snapshotFixture())
        #expect(await io.events == ["inventory","boot","inventory","inventory","connect","observe","observe","active","backup","boot1","observe","disconnect"])
        let encoded = try JSONEncoder().encode(report)
        #expect(String(decoding:encoded,as:UTF8.self).contains("WlpaWlpa") == false)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let path = try await RecoveryBootSnapshotStore(root:root).save(report)
        #expect(path.lastPathComponent.hasPrefix("InstallEvidence-"))
        #expect(try Data(contentsOf:path.appendingPathComponent("boot1.bin")) == boot1Fixture())
        let json = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:path.appendingPathComponent("manifest.json"))) as? [String:Any])
        #expect(json["schemaVersion"] as? Int == 2)
        #expect(json["firmwareRestoreEligible"] as? Bool == false)
        let stock = root.appendingPathComponent("stock.img"); try snapshotFixture().write(to:stock)
        #expect(throws:(any Error).self) { try StockRestoreMaterial.load(snapshot:path,stock:stock) }
    }

    @Test func interruptedInstallEvidenceExportHasNoCompletionManifest() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let report = RecoveryRAMProbeReport(before:probeFEL(),after:probeRNDIS(),
            observation:try RecoveryProbePolicy.observation(probeObservation()),
            bootSnapshot:try RecoveryBootSnapshot(active:.image(snapshotFixture()),backup:.unavailable),
            boot1Snapshot:try RecoveryBoot1Snapshot(boot1Fixture()))
        let counter = OSAllocatedUnfairLock(initialState:0)
        let store = try RecoveryBootSnapshotStore(root:root,synchronize:{ fd in
            let call = counter.withLock { $0 += 1; return $0 }
            return call == 4 ? -1 : Darwin.fsync(fd)
        })
        await #expect(throws:(any Error).self) { try await store.save(report) }
        let directories = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        #expect(directories.count == 1)
        let directory = try #require(directories.first)
        #expect(directory.lastPathComponent.hasPrefix("InstallEvidence-"))
        #expect(FileManager.default.fileExists(atPath:directory.appendingPathComponent("boot1.bin").path))
        #expect(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("manifest.json").path))
    }

    @Test func changedIdentityAfterBoot1ReadRefusesCompleteEvidence() async throws {
        let io = Boot1EvidenceIO(changeIdentity:true), raw = try PinnedFELInputs.load()
        await #expect(throws:(any Error).self) {
            try await RecoveryRAMProbe(wait:{}).run(
                inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),
                io:io,captureInstallEvidence:true)
        }
        #expect(await io.events.last == "disconnect")
        #expect(await io.events.filter{$0 == "boot"}.count == 1)
    }

    @Test func installEvidenceCLIIsSeparateFromBoot2SnapshotAndRejectsInvalidPaths() throws {
        #expect(try RecoveryDiagnosticOptions.parse(["--snapshot-install-evidence", "/private/tmp/Backups"]) == .installEvidence("/private/tmp/Backups"))
        for args in [["--snapshot-install-evidence"], ["--snapshot-install-evidence", "relative"],
                     ["--snapshot-install-evidence", "/tmp", "--boot-recovery"]] {
            #expect(throws: (any Error).self) { try RecoveryDiagnosticOptions.parse(args) }
        }
    }
}

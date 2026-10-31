import Foundation
import Testing
@testable import SwiftHakchi
import SwiftHakchiCore

func snapshotFixture() -> Data {
    var data = Data(repeating: 0, count: 6144)
    data.replaceSubrange(0..<8, with: Data("ANDROID!".utf8))
    for (offset, value): (Int, UInt32) in [(8,100), (16,200), (36,2048)] {
        for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (8*i)) }
    }
    return data
}
func snapshotFrame(_ bytes: Data) -> Data {
    Data("SWIFTHAKCHI_BOOT2_V1 \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8) + bytes
}
private actor SnapshotIO: RecoveryProbeIO {
    var events: [String] = []
    let bad: String?
    var observationCount = 0
    init(bad: String? = nil) { self.bad = bad }
    func inventory() -> [RecoveryProbeUSBDevice] { events.append("inventory"); return events.count == 1 ? [probeFEL()] : [probeRNDIS()] }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { events.append("boot") }
    func connect(expected: RecoveryProbeUSBDevice) { events.append("connect") }
    func observe() -> String {
        events.append("observe"); observationCount += 1
        if bad == "board" { return probeObservation().replacingOccurrences(of: "dp-nes", with: "dp-snes") }
        if bad == "identity" && observationCount == 3 { return probeObservation().replacingOccurrences(of: "HWID=012", with: "HWID=112") }
        if bad == "mount" && observationCount == 3 { return probeObservation().replacingOccurrences(of: "ro,noatime", with: "rw,noatime") }
        return probeObservation()
    }
    func readBoot2(_ slot: RecoveryBootSlot) throws -> RecoveryBoot2Read {
        events.append(slot == .active ? "active" : "backup")
        if bad == "cancel" { throw CancellationError() }
        if bad == "active" && slot == .active { return .unavailable }
        if slot == .backup { return .unavailable }
        return try RecoveryBoot2Read.parse(snapshotFrame(snapshotFixture()))
    }
    func disconnect() { events.append("disconnect") }
}
struct RecoveryBootSnapshotTests {
    @Test func binaryFramesVerifySizeHashAndExactBoundaries() throws {
        let bytes = snapshotFixture()
        guard case .image(let decoded) = try RecoveryBoot2Read.parse(snapshotFrame(bytes)) else { Issue.record("Lost image"); return }
        #expect(decoded == bytes)
        #expect(try RecoveryBoot2Read.parse(Data("SWIFTHAKCHI_BOOT2_UNAVAILABLE_V1\n".utf8)) == .unavailable)
        var changed = snapshotFrame(bytes); changed[changed.count-1] ^= 1
        for frame in [Data(), changed, Data(snapshotFrame(bytes).dropLast()), snapshotFrame(bytes) + Data([0]),
                      Data("SWIFTHAKCHI_BOOT2_V1 16777217 \(String(repeating: "a",count:64))\n".utf8),
                      Data("SWIFTHAKCHI_BOOT2_V1 -1 \(String(repeating:"a",count:64))\n".utf8),
                      Data("SWIFTHAKCHI_BOOT2_UNAVAILABLE_V1\nextra".utf8), Data(repeating: 65,count:200)] {
            #expect(throws: (any Error).self) { try RecoveryBoot2Read.parse(frame) }
        }
    }
    @Test func activeMustBeStructuredAndUnavailableBackupNeverBecomesStock() throws {
        let bytes = snapshotFixture()
        let captured = try RecoveryBootSnapshot(active: .image(bytes), backup: .unavailable)
        #expect(captured.active == bytes && captured.backup == nil)
        #expect(captured.activeIsKnownStock == false && captured.backupIsKnownStock == false)
        let unknown = try RecoveryBootSnapshot(active: .image(bytes), backup: .image(bytes))
        #expect(unknown.backup == bytes && unknown.backupIsKnownStock == false)
        #expect(throws: (any Error).self) { try RecoveryBootSnapshot(active: .unavailable, backup: .image(bytes)) }
        #expect(throws: (any Error).self) { try RecoveryBootSnapshot(active: .image(Data([1])), backup: .unavailable) }
        #expect(throws: (any Error).self) { try RecoveryBootSnapshot(active: .image(bytes), backup: .image(Data())) }
        let invalidBackup = try RecoveryBootSnapshot(active: .image(bytes), backup: .image(Data([1])))
        #expect(invalidBackup.backup == Data([1]) && invalidBackup.backupIsKnownStock == false)
        #expect(invalidBackup.backupIsStructurallyValid == false)
    }
    @Test func captureUsesAcceptedSessionAndRechecksBeforeAndAfter() async throws {
        let io = SnapshotIO(), raw = try PinnedFELInputs.load()
        let result = try await RecoveryRAMProbe(wait: {}).run(inputs: .init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage), io:io, captureBoot2:true)
        #expect(result.bootSnapshot?.active == snapshotFixture())
        #expect(result.firmwareRestoreEligible == false)
        #expect(await io.events == ["inventory","boot","inventory","inventory","connect","observe","observe","active","backup","observe","disconnect"])
        let json = try JSONEncoder().encode(result)
        #expect(String(decoding:json,as:UTF8.self).contains("QU5EUk9JRC") == false) // raw Android bytes never in JSON
    }
    @Test(arguments: ["board","identity","mount","active","cancel"])
    func failedCaptureDisconnectsWithoutRetryOrCompleteResult(fault: String) async throws {
        let io = SnapshotIO(bad:fault), raw = try PinnedFELInputs.load()
        await #expect(throws: (any Error).self) {
            try await RecoveryRAMProbe(wait: {}).run(inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),io:io,captureBoot2:true)
        }
        let events = await io.events
        #expect(events.filter { $0 == "boot" }.count == 1)
        #expect(events.last == "disconnect")
        if fault == "board" { #expect(events.contains("active") == false) }
    }
    @Test func actualReadScriptFramesBytesUsesOnlyTypedReadsAndCleansRAM() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture"), log = root.appendingPathComponent("calls")
        try snapshotFixture().write(to: fixture)
        let tool = root.appendingPathComponent("reader")
        try Data("#!/bin/sh\nprintf '%s %s\\n' \"$1\" \"$2\" >> \"$NES_READ_LOG\"\ntest \"$1\" = read_boot2 || exit 8\ntest \"$NES_READ_FAIL\" = no || exit 1\ncat \"$NES_READ_FIXTURE\"\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        for (slot, expected): (RecoveryBootSlot,String) in [(.active,"read_boot2 30\n"),(.backup,"read_boot2 68\n")] {
            for fail in ["no","yes"] {
                try? FileManager.default.removeItem(at: log)
                let process = Process(), out = Pipe(), err = Pipe()
                process.executableURL = URL(fileURLWithPath:"/bin/sh")
                let stubs = #"""
                sha256sum() { if [ "$1" = /bin/sntool ]; then printf 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9  tool\n'; else /usr/bin/shasum -a 256 "$@"; fi; }
                """#
                let script = RecoveryBootSnapshotCommand.read(slot)
                    .replacingOccurrences(of:"/bin/sunxi-flash",with:LaunchCommand.shellQuote(tool.path))
                    .replacingOccurrences(of:"/tmp/swifthakchi-boot2.XXXXXX",with:root.appendingPathComponent("ram.XXXXXX").path)
                process.arguments = ["-c",stubs + "\n" + script]
                process.environment = ProcessInfo.processInfo.environment.merging(["NES_READ_LOG":log.path,"NES_READ_FIXTURE":fixture.path,"NES_READ_FAIL":fail]) { _,new in new }
                process.standardOutput = out; process.standardError = err
                try process.run()
                let bytes = out.fileHandleForReading.readDataToEndOfFile()
                let error = err.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                #expect(process.terminationStatus == 0, "\(String(decoding:error,as:UTF8.self))")
                #expect(try String(contentsOf:log,encoding:.utf8) == expected)
                #expect(try RecoveryBoot2Read.parse(bytes) == (fail == "no" ? .image(snapshotFixture()) : .unavailable))
                #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).contains(where:{$0.hasPrefix("ram.")}) == false)
            }
        }
    }
    @Test func ordinaryProbeDoesNotReadAnyKernel() async throws {
        let io = SnapshotIO(), raw = try PinnedFELInputs.load()
        let result = try await RecoveryRAMProbe(wait:{}).run(inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),io:io)
        #expect(result.bootSnapshot == nil)
        #expect(await io.events.contains("active") == false)
    }
}

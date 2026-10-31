import Foundation
import Testing
@testable import SwiftHakchi
import SwiftHakchiCore

private func ext4Header(blocks: UInt32 = 100_000, free: UInt32 = 24_000, logBlockSize: UInt32 = 2) -> Data {
    var data = Data(repeating: 0, count: 2048)
    func put(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { data[offset+i] = UInt8((value >> (i*8)) & 0xff) }
    }
    put(blocks, at:1024+4); put(free,at:1024+12); put(logBlockSize,at:1024+24)
    data[1024+56] = 0x53; data[1024+57] = 0xef
    return data
}
private func ext4Frame(_ data: Data) -> Data {
    Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 \(data.count) \(BackupManifest.digest(data))\n".utf8) + data
}
struct RecoveryDataSuperblockTests {
    @Test func acceptsOnlyExactHashedExt4WithinValidatedPartition() throws {
        let data = ext4Header(), frame = ext4Frame(data)
        let parsed = try RecoveryDataSuperblock.parse(frame,partitionSectors:806_912)
        #expect(parsed.blockSize == 4096)
        #expect(parsed.blocks == 100_000)
        #expect(parsed.freeBlocks == 24_000)
        var altered = frame; altered[altered.count-1] ^= 1
        for invalid in [Data(),altered,Data(frame.dropLast()),frame+Data([0]),
                        ext4Frame(ext4Header(blocks:1_000_000)),
                        ext4Frame(ext4Header(free:100_001)),
                        ext4Frame(ext4Header(logBlockSize:4)),
                        ext4Frame(Data(repeating:0,count:2048))] {
            #expect(throws:(any Error).self) { try RecoveryDataSuperblock.parse(invalid,partitionSectors:806_912) }
        }
        #expect(throws:(any Error).self) { try RecoveryDataSuperblock.parse(frame,partitionSectors:10) }
    }
    @Test func RAMScratchPolicyRejectsOvermountsAndNonRAMRoot() throws {
        let accepted = try RecoveryProbePolicy.observation(probeObservation())
        try RecoveryProbePolicy.requireRAMScratch(accepted)
        let overmount = probeObservation().replacingOccurrences(of:"MOUNTS_END",
            with:"/dev/sda1 /tmp ext4 rw,relatime 0 0\nMOUNTS_END")
        let nonRAM = probeObservation().replacingOccurrences(of:"rootfs / rootfs rw 0 0",
            with:"/dev/sda1 / ext4 rw,relatime 0 0")
        for text in [overmount,nonRAM] {
            let value = try RecoveryProbePolicy.observation(text)
            #expect(throws:(any Error).self) { try RecoveryProbePolicy.requireRAMScratch(value) }
        }
    }
    @Test(arguments:["good","overmount","grep-error","mounted-data"]) func actualReadScriptRefusesUnsafeMountsAndGrepError(fault:String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let scratch = root.appendingPathComponent("scratch"), data = root.appendingPathComponent("data"),
            mounts = root.appendingPathComponent("mounts"), tool = root.appendingPathComponent("sntool")
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:false)
        try ext4Header().write(to:data); try Data([1]).write(to:tool)
        var mountText = "rootfs / rootfs rw 0 0\n/dev/mapper/root-crypt /newroot squashfs ro,noatime 0 0\n"
        if fault == "overmount" { mountText += "/dev/sda1 /tmp ext4 rw,relatime 0 0\n" }
        if fault == "mounted-data" { mountText += data.path + " /mnt ext4 ro 0 0\n" }
        try Data(mountText.utf8).write(to:mounts)
        var script = RecoveryDataSuperblockCommand.read
        script = script.replacingOccurrences(of:"test -b /dev/nandc",with:"test -f " + LaunchCommand.shellQuote(data.path))
            .replacingOccurrences(of:"/dev/nandc",with:data.path)
            .replacingOccurrences(of:"test -d /tmp && test ! -L /tmp",
                with:"test -d " + LaunchCommand.shellQuote(scratch.path) + " && test ! -L " + LaunchCommand.shellQuote(scratch.path))
            .replacingOccurrences(of:"/tmp/swifthakchi-data-header.XXXXXX",with:scratch.appendingPathComponent("ram.XXXXXX").path)
            .replacingOccurrences(of:"/proc/mounts",with:mounts.path)
            .replacingOccurrences(of:"/bin/sntool",with:tool.path)
        let shaStub = "sha256sum() { if [ \"$1\" = \"$NES_TOOL\" ]; then printf 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9  tool\\n'; else /usr/bin/shasum -a 256 \"$@\"; fi; }\n"
        let grepStub = fault == "grep-error" ? "grep() { return 2; }\n" : ""
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath:"/bin/sh")
        process.arguments = ["-c",shaStub + grepStub + script]
        process.environment = ProcessInfo.processInfo.environment.merging(["NES_TOOL":tool.path]) { _,new in new }
        process.standardOutput = out; process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect((process.terminationStatus == 0) == (fault == "good"))
        if fault == "good" { #expect(try RecoveryDataSuperblock.parse(output,partitionSectors:806_912).blocks == 100_000) }
        else { #expect(output.isEmpty) }
        #expect(try FileManager.default.contentsOfDirectory(atPath:scratch.path).isEmpty)
    }
    @Test func commandHasOnlyPinnedBoundedDataRead() {
        let command = RecoveryDataSuperblockCommand.read
        #expect(command.contains("/dev/nandc"))
        #expect(command.contains("bs=2048 count=1"))
        #expect(command.contains("SWIFTHAKCHI_DATA_SUPERBLOCK_V1"))
        for forbidden in ["burn_", "mount -", "install ", "reboot", "flashBoot"] { #expect(!command.contains(forbidden)) }
    }
}

private actor DataInventoryIO: RecoveryProbeIO {
    var events: [String] = []
    let changedIdentity: Bool
    private var observations = 0
    init(changedIdentity: Bool = false) { self.changedIdentity = changedIdentity }
    func inventory() -> [RecoveryProbeUSBDevice] { events.append("inventory"); return events.count == 1 ? [probeFEL()] : [probeRNDIS()] }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { events.append("boot") }
    func connect(expected: RecoveryProbeUSBDevice) { events.append("connect") }
    func observe() -> String {
        observations += 1; events.append("observe")
        let value = probeObservation()
        return changedIdentity && observations == 3 ? value.replacingOccurrences(of:"HWID=012",with:"HWID=112") : value
    }
    func readPartitions() -> Data { events.append("partitions"); return Data(legacyPartitionsFixture().utf8) }
    func readDataSuperblock() -> Data { events.append("superblock"); return ext4Frame(ext4Header()) }
    func disconnect() { events.append("disconnect") }
}

struct RecoveryDataInventorySessionTests {
    @Test func oneBoundSessionReadsValidatedPartitionsThenDataHeader() async throws {
        let io = DataInventoryIO(), raw = try PinnedFELInputs.load()
        let report = try await RecoveryRAMProbe(wait:{}).run(
            inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),
            io:io,captureDataLayout:true)
        #expect(report.dataSuperblock?.blocks == 100_000)
        #expect(report.partitionSHA256 == BackupManifest.digest(Data(legacyPartitionsFixture().utf8)))
        #expect(await io.events == ["inventory","boot","inventory","inventory","connect","observe","observe","partitions","superblock","observe","disconnect"])
        let encoded = try JSONEncoder().encode(report)
        #expect(!encoded.contains(Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1".utf8)))
    }
    @Test func changedIdentityAfterDataReadRefusesAcceptance() async throws {
        let io = DataInventoryIO(changedIdentity:true), raw = try PinnedFELInputs.load()
        await #expect(throws:(any Error).self) {
            try await RecoveryRAMProbe(wait:{}).run(
                inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),
                io:io,captureDataLayout:true)
        }
        #expect(await io.events.last == "disconnect")
    }
    @Test func dataLayoutModeIsSeparateAndReadOnly() throws {
        #expect(try RecoveryDiagnosticOptions.parse(["--inspect-data-layout"]) == .dataLayout)
        #expect(throws:(any Error).self) { try RecoveryDiagnosticOptions.parse(["--inspect-data-layout","/tmp"]) }
    }
}

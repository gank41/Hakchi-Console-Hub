import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

private let inventoryPaths = [
    "clover", "hakchi", "hakchi/games", "hakchi/rootfs", "hakchi/rootfs/bin/hakchi",
    "hakchi/rootfs/etc/preinit", "hakchi/rootfs/etc/preinit.d/b0000_defines",
    "hakchi/rootfs/etc/preinit.d/b0010_functions", "hakchi/rootfs/etc/preinit.d/b0030_package",
    "hakchi/rootfs/etc/preinit.d/b0050_boot"
]

private func inventoryFrame(_ lines: [String]) -> Data {
    let body = "SWIFTHAKCHI_PERSISTENT_INVENTORY_V1\n" + lines.joined(separator:"\n") + "\n"
    let digest = BackupManifest.digest(Data(body.utf8))
    return Data((body + "SWIFTHAKCHI_PERSISTENT_INVENTORY_END_V1 \(body.utf8.count) \(digest)\n").utf8)
}

struct RecoveryPersistentInventoryTests {
    @Test func privateDiagnosticCaptureAcceptsOnlyBoundedPrintableFrame() {
        let frame = inventoryFrame(inventoryPaths.map { "A\t" + $0 })
        #expect(RecoveryPersistentInventory.safeDiagnosticText(frame) != nil)
        #expect(RecoveryPersistentInventory.safeDiagnosticText(frame + Data([27])) == nil)
        #expect(RecoveryPersistentInventory.safeDiagnosticText(Data(repeating:65,count:4097)) == nil)
    }
    @Test func rejectedFrameSummaryShowsOnlyLengthAndHexPrefix() {
        let summary = RecoveryPersistentInventory.diagnosticSummary(Data([0x41,0x1b]))
        #expect(summary.contains("bytes=2"))
        #expect(summary.contains("firstControl=1"))
        #expect(summary.contains("prefixHex=411b"))
    }
    @Test func stageTraceIncludesOnlyExactDiagnosticMarkers() {
        let output = "SWIFTHAKCHI_INV_STAGE_BEGIN_V1\nsecret\nSWIFTHAKCHI_INV_STAGE_BODY_V1suffix\nSWIFTHAKCHI_INV_STAGE_EMITTED_V1\n"
        #expect(RecoveryPersistentInventory.stageTrace(output) == "begin,emitted")
    }
    @Test func mountFlagTraceAcceptsOnlyBoundedBinaryChecks() {
        #expect(RecoveryPersistentInventory.mountFlagTrace("SWIFTHAKCHI_INV_MOUNT_FLAGS_V1 1 11110111\n") == "count=1 flags=11110111")
        #expect(RecoveryPersistentInventory.mountFlagTrace("SWIFTHAKCHI_INV_MOUNT_FLAGS_V1 1 11110111secret\n") == "none")
    }
    @Test(arguments:["good","norecovery-alias","missing-recovery","wrong-options","symlink","mount-failure","umount-failure"])
    func actualMountScriptFramesOnlyVerifiedUnmountedFixedPaths(fault:String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let mounts = root.appendingPathComponent("mounts"), data = root.appendingPathComponent("nandc"),
            tool = root.appendingPathComponent("sntool")
        try Data("rootfs / rootfs rw 0 0\n".utf8).write(to:mounts)
        try Data([0]).write(to:data); try Data([1]).write(to:tool)
        var script = RecoveryPersistentInventoryCommand.read
        script = script.replacingOccurrences(of:"test -b /dev/nandc",with:"test -f " + LaunchCommand.shellQuote(data.path))
            .replacingOccurrences(of:"/dev/nandc",with:data.path)
            .replacingOccurrences(of:"test -d /tmp && test ! -L /tmp",
                with:"test -d " + LaunchCommand.shellQuote(root.path) + " && test ! -L " + LaunchCommand.shellQuote(root.path))
            .replacingOccurrences(of:"/tmp/swifthakchi-inventory.XXXXXX",with:root.appendingPathComponent("ram.XXXXXX").path)
            .replacingOccurrences(of:"/proc/mounts",with:mounts.path)
            .replacingOccurrences(of:"/bin/sntool",with:tool.path)
        let stubs = #"""
        sha256sum() {
          if test "$1" = "$NES_TOOL"; then printf 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9  tool\n'
          else /usr/bin/shasum -a 256 "$@"; fi
        }
        stat() {
          case "$2" in
            %u) /usr/bin/stat -f %u "$3";; %g) /usr/bin/stat -f %g "$3";;
            %a) /usr/bin/stat -f %Lp "$3";; %s) /usr/bin/stat -f %z "$3";;
            *) return 2;;
          esac
        }
        mount() {
          test "$NES_FAULT" != mount-failure || return 4
          test "$1" = -t && test "$2" = ext4 && test "$3" = -o && test "$5" = "$NES_DATA" || return 5
          case "$NES_FAULT" in
            wrong-options) flags=rw,nodev,nosuid,noexec;;
            norecovery-alias) flags=ro,norecovery,nodev,nosuid,noexec;;
            missing-recovery) flags=ro,nodev,nosuid,noexec;;
            *) flags="$4";;
          esac
          printf '%s %s ext4 %s 0 0\n' "$5" "$6" "$flags" >> "$NES_MOUNTS"
          mkdir -p "$6/hakchi/rootfs/bin"
          printf 'fixed-core' > "$6/hakchi/rootfs/bin/hakchi"
          if test "$NES_FAULT" = symlink; then ln -s /etc "$6/hakchi/rootfs/etc"; fi
        }
        umount() {
          test "$NES_FAULT" != umount-failure || return 5
          rm -r "$1/hakchi"
          printf 'rootfs / rootfs rw 0 0\n' > "$NES_MOUNTS"
        }
        """#
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath:"/bin/sh")
        process.arguments = ["-c",stubs + "\n" + script]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NES_TOOL":tool.path,"NES_DATA":data.path,"NES_MOUNTS":mounts.path,"NES_FAULT":fault]) { _,new in new }
        process.standardOutput = out; process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = err.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect((process.terminationStatus == 0) == (fault == "good" || fault == "norecovery-alias"))
        if fault == "good" || fault == "norecovery-alias" {
            let value = try RecoveryPersistentInventory.parse(output)
            #expect(value.entries.count == inventoryPaths.count)
            #expect(value.entries[4].kind == "file")
            #expect(RecoveryPersistentInventory.stageTrace(String(decoding:errorOutput,as:UTF8.self)) == "begin,mounted,body,unmounted,emitted")
        } else { #expect(output.isEmpty) }
        if fault == "umount-failure" {
            #expect(String(decoding:errorOutput,as:UTF8.self).contains("SWIFTHAKCHI_UNMOUNT_FAILED_V1"))
        } else if fault == "wrong-options" || fault == "missing-recovery" {
            #expect(RecoveryPersistentInventory.mountFlagTrace(String(decoding:errorOutput,as:UTF8.self)) != "none")
        } else {
            #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0.hasPrefix("ram.") }.isEmpty)
        }
    }
    @Test func commandUsesNoJournalReplayAndEmitsOnlyAfterUnmount() {
        let script = RecoveryPersistentInventoryCommand.read
        #expect(script.contains("mount -t ext4 -o ro,noload,nodev,nosuid,noexec /dev/nandc"))
        #expect(script.contains("umount \"$mnt\""))
        #expect(script.contains("SWIFTHAKCHI_PERSISTENT_INVENTORY_END_V1"))
        for forbidden in ["burn_", "-o defaults", "mount -o rw", "reboot", "flashBoot", "find "] {
            #expect(!script.contains(forbidden))
        }
    }
    @Test func acceptsCompleteFixedPathManifestWithValidatedMetadata() throws {
        let lines = inventoryPaths.map { path -> String in
            if path == "clover" || path == "hakchi" || path == "hakchi/rootfs" {
                return "D\t\(path)\t0\t0\t755"
            }
            if path == "hakchi/rootfs/bin/hakchi" {
                return "F\t\(path)\t0\t0\t755\t483\t" + String(repeating:"a",count:64)
            }
            return "A\t\(path)"
        }
        let parsed = try RecoveryPersistentInventory.parse(inventoryFrame(lines))
        #expect(parsed.entries.count == inventoryPaths.count)
        #expect(parsed.entries[4].size == 483)
        #expect(parsed.entries[4].sha256 == String(repeating:"a",count:64))
    }

    @Test func rejectsDuplicatesUnexpectedPathsTypesAndFrameCorruption() throws {
        let absent = inventoryPaths.map { "A\t" + $0 }
        var invalid: [Data] = [Data(), inventoryFrame(Array(absent.dropLast())),
            inventoryFrame(absent + [absent[0]]),
            inventoryFrame(absent.map { $0 == "A\thakchi" ? "F\thakchi\t0\t0\t755\t1\t" + String(repeating:"a",count:64) : $0 }),
            inventoryFrame(absent.map { $0 == "A\tclover" ? "A\t../../etc" : $0 }),
            inventoryFrame(absent.map { $0 == "A\thakchi/rootfs" ? "D\thakchi/rootfs\t0\t0\t755" : $0 }),
            inventoryFrame(absent.map { $0 == "A\tclover" ? "D\tclover\troot\t0\t755" : $0 }),
            inventoryFrame(absent.map { $0 == "A\tclover" ? "D\tclover\t0\t0\t999" : $0 }),
            inventoryFrame(absent.map { $0 == "A\thakchi/rootfs/bin/hakchi" ? "F\thakchi/rootfs/bin/hakchi\t0\t0\t755\t5000001\t" + String(repeating:"a",count:64) : $0 })]
        var altered = inventoryFrame(absent); altered[50] ^= 1; invalid.append(altered)
        invalid.append(Data(inventoryFrame(absent).dropLast()))
        invalid.append(inventoryFrame(absent) + Data([0]))
        for value in invalid {
            #expect(throws:(any Error).self) { try RecoveryPersistentInventory.parse(value) }
        }
    }
}

private actor PersistentInventoryIO: RecoveryProbeIO {
    var events: [String] = []
    let filesystemState: UInt16
    let needsRecovery: Bool
    init(filesystemState:UInt16 = 1,needsRecovery:Bool = false) {
        self.filesystemState = filesystemState;self.needsRecovery = needsRecovery
    }
    func inventory() -> [RecoveryProbeUSBDevice] {
        events.append("inventory")
        return events.count == 1 ? [probeFEL()] : [probeRNDIS()]
    }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { events.append("boot") }
    func connect(expected: RecoveryProbeUSBDevice) { events.append("connect") }
    func observe() -> String { events.append("observe"); return probeObservation() }
    func readPartitions() -> Data { events.append("partitions"); return Data(legacyPartitionsFixture().utf8) }
    func readDataSuperblock() -> Data {
        events.append("superblock")
        return ext4InventoryHeader(state:filesystemState,needsRecovery:needsRecovery)
    }
    func readPersistentInventory() -> Data {
        events.append("files")
        return inventoryFrame(inventoryPaths.map { "A\t" + $0 })
    }
    func disconnect() { events.append("disconnect") }
}

private func ext4InventoryHeader(state:UInt16 = 1,needsRecovery:Bool = false) -> Data {
    var bytes = Data(repeating:0,count:2048)
    func put(_ value:UInt32,_ offset:Int) {
        for i in 0..<4 { bytes[offset+i] = UInt8((value >> (i*8)) & 255) }
    }
    put(100_864,1028);put(80_000,1036);put(2,1048)
    bytes[1080] = 0x53;bytes[1081] = 0xef
    bytes[1082] = UInt8(state & 255);bytes[1083] = UInt8(state >> 8)
    if needsRecovery { bytes[1120] = 4 }
    return Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(bytes))\n".utf8) + bytes
}

struct RecoveryPersistentInventorySessionTests {
    @Test(arguments:[(UInt16(0),false),(UInt16(2),false),(UInt16(1),true)])
    func refusesUncleanFilesystemBeforeMount(state:UInt16,needsRecovery:Bool) async throws {
        let io = PersistentInventoryIO(filesystemState:state,needsRecovery:needsRecovery)
        let raw = try PinnedFELInputs.load()
        await #expect(throws:(any Error).self) {
            try await RecoveryRAMProbe(wait:{}).run(
                inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),
                io:io,capturePersistentInventory:true)
        }
        #expect(!((await io.events).contains("files")))
    }
    @Test func persistentModeIsSeparateFromOfflineInspection() throws {
        #expect(try RecoveryDiagnosticOptions.parse(["--inspect-persistent"]) == .persistent)
        #expect(throws:(any Error).self) { try RecoveryDiagnosticOptions.parse(["--inspect-persistent","/tmp"]) }
    }
    @Test func fixedFileInventoryRunsAfterHeaderInOneBoundSession() async throws {
        let io = PersistentInventoryIO(), raw = try PinnedFELInputs.load()
        let report = try await RecoveryRAMProbe(wait:{}).run(
            inputs:.init(fes1:raw.fes1,uboot:raw.uboot,bootImage:raw.bootImage),
            io:io,capturePersistentInventory:true)
        #expect(report.persistentInventory?.entries.count == inventoryPaths.count)
        #expect(await io.events == ["inventory","boot","inventory","inventory","connect","observe","observe","partitions","superblock","files","observe","disconnect"])
    }
}

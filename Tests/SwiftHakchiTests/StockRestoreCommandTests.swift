import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

// Exact captured metadata contains no console identifiers or ROM bytes.
func legacyCompactPartitionsFixture() -> String { "mbr::32768 nanda:boot:6144 nandb:rootfs:38912 nandc:data:806912 nandd:private:2048 nande:UDISK:27648\n" }
func legacyDetailedPartitionsFixture() -> String { "check partition table copy 0: mbr: version 0x00000200, magic softw411\nOK\ncheck partition table copy 1: mbr: version 0x00000200, magic softw411\nOK\ncheck partition table copy 2: mbr: version 0x00000200, magic softw411\nOK\ncheck partition table copy 3: mbr: version 0x00000200, magic softw411\nOK\nmbr: version 0x00000200, magic softw411\n5 partitions\npartition  1: class =         DISK, name =         boot, partition start =    32768, partition size =     6144 user_type=32768\npartition  2: class =         DISK, name =       rootfs, partition start =    38912, partition size =    38912 user_type=32768\npartition  3: class =         DISK, name =         data, partition start =    77824, partition size =   806912 user_type=32768\npartition  4: class =         DISK, name =      private, partition start =   884736, partition size =     2048 user_type=32768\npartition  5: class =         DISK, name =        UDISK, partition start =   886784, partition size =        0 user_type=0\n" }
func legacyPartitionsFixture() -> String {
    "SWIFTHAKCHI_COMPACT_PARTITIONS_V1\n" + legacyCompactPartitionsFixture() +
    "SWIFTHAKCHI_DETAILED_PARTITIONS_V1\n" + legacyDetailedPartitionsFixture()
}
private func simulatedRAMPartitionQuery(_ command: String, in root: URL) throws -> String {
    let mounts = root.appendingPathComponent("mounts")
    try Data("rootfs / rootfs rw 0 0\n".utf8).write(to: mounts)
    return command
        .replacingOccurrences(of: "test -d /tmp && test ! -L /tmp",
                              with: "test -d " + LaunchCommand.shellQuote(root.path) + " && test ! -L " + LaunchCommand.shellQuote(root.path))
        .replacingOccurrences(of: "/proc/mounts", with: mounts.path)
}
struct StockRestoreCommandTests {
    @Test(arguments: ["ok","short","hash","check-fails","check-mutates","md","partition","alias","pin","owner","linked","burn-fails","compact-fails","compact-mismatch"])
    func actualBurnScriptChecksStagedInputAndDispatchesAtMostOnce(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let tool = root.appendingPathComponent("sntool"), part = root.appendingPathComponent("sunxi-part"), flash = root.appendingPathComponent("sunxi-flash")
        let partition = root.appendingPathComponent("partition"), log = root.appendingPathComponent("calls"), input = root.appendingPathComponent("burn-input")
        try Data(legacyDetailedPartitionsFixture().utf8).write(to:partition)
        let compact=root.appendingPathComponent("compact")
        try Data(legacyCompactPartitionsFixture().utf8).write(to:compact)
        let helper = #"""
        #!/bin/sh
        case "${0##*/}:$1" in
          sntool:ismd) test "$NES_FAULT" != md || exit 0; exit 1;;
          sntool:check)
            test "$NES_FAULT" != check-fails || exit 4
            if test "$NES_FAULT" = check-mutates; then printf x >> "$2"; fi
            exit 0;;
          sunxi-part:)
            test "$#" = 0 || exit 10
            if test "$NES_FAULT" = compact-mismatch; then sed 's/806912/806913/' "$NES_COMPACT"; else cat "$NES_COMPACT"; fi
            test "$NES_FAULT" != compact-fails || exit 11
            exit 0;;
          sunxi-part:--nand-part)
            test "$#" = 1 || exit 10
            cat "$NES_PART"
            test "$NES_FAULT" != partition || exit 5
            exit 0;;
          sunxi-flash:burn_boot2)
            printf '%s %s\n' "$1" "$2" >> "$NES_LOG"
            cat > "$NES_INPUT"
            test "$NES_FAULT" != burn-fails || exit 6
            exit 0;;
        esac
        exit 9
        """#
        try Data(helper.utf8).write(to:tool)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:tool.path)
        try FileManager.default.createSymbolicLink(at:part,withDestinationURL:tool)
        try FileManager.default.createSymbolicLink(at:flash,withDestinationURL:tool)
        let ram = root.appendingPathComponent("ram"), id = UUID(), bytes = snapshotFixture(), sha = SwiftHakchiCore.BackupManifest.digest(bytes)
        let stubs = #"""
        sha256sum() {
          if test "$NES_FAULT" = pin && test "$1" = "$NES_TOOL"; then printf 'bad  tool\n'; else /usr/bin/shasum -a 256 "$@"; fi
        }
        readlink() { if test "$NES_FAULT" = alias; then printf 'wrong\n'; else printf '%s\n' "$NES_TOOL"; fi; }
        stat() { /usr/bin/stat -f %l "$3"; }
        """#
        func execute(_ script: String) throws -> (Int32,Data) {
            var script = script.replacingOccurrences(of:"/bin/sntool",with:tool.path)
                .replacingOccurrences(of:"/bin/sunxi-part",with:part.path)
                .replacingOccurrences(of:"/bin/sunxi-flash",with:flash.path)
                .replacingOccurrences(of:StockRestoreCommands.directory,with:ram.path)
                .replacingOccurrences(of:"f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9",with:SwiftHakchiCore.BackupManifest.digest(try Data(contentsOf:tool)))
            script = stubs + "\n" + script
            let p=Process(), out=Pipe(), err=Pipe(); p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=["-c",script]
            p.environment=ProcessInfo.processInfo.environment.merging(["NES_FAULT":fault,"NES_TOOL":tool.path,"NES_PART":partition.path,"NES_COMPACT":compact.path,"NES_LOG":log.path,"NES_INPUT":input.path]){_,new in new}
            p.standardOutput=out;p.standardError=err;try p.run()
            let data=out.fileHandleForReading.readDataToEndOfFile();_ = err.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
            return (p.terminationStatus,data)
        }
        let creation=try execute(StockRestoreCommands.create(id:id))
        if ["pin","alias"].contains(fault) { #expect(creation.0 != 0);#expect(!FileManager.default.fileExists(atPath:log.path));return }
        #expect(creation.0 == 0)
        #expect(creation.1 == Data(StockRestoreCompletion.created(id:id).utf8))
        // Exclusive lock refuses a second caller, preserving the original owner.
        #expect(try execute(StockRestoreCommands.create(id:UUID())).0 != 0)
        let staged=ram.appendingPathComponent("stock.img")
        try (fault == "short" ? Data(bytes.prefix(100)) : bytes).write(to:staged)
        if fault == "hash" { var changed=bytes;changed[1000] ^= 1;try changed.write(to:staged) }
        if fault == "owner" { try Data("wrong".utf8).write(to:ram.appendingPathComponent("owner")) }
        if fault == "linked" { try FileManager.default.removeItem(at:staged);try FileManager.default.createSymbolicLink(at:staged,withDestinationURL:partition) }
        if fault == "ok" {
            let checked=try execute(StockRestoreCommands.checkedStage(id:id,sha:sha,count:bytes.count))
            #expect(checked.0 == 0 && checked.1 == Data(StockRestoreCompletion.staged(id:id,sha:sha).utf8))
        }
        let script=try StockRestoreCommands.burn(id:id,sha:sha,count:bytes.count,partitionSHA256:SwiftHakchiCore.BackupManifest.digest(Data(legacyPartitionsFixture().utf8)))
        let result=try execute(script)
        if fault == "ok" { #expect(result.0 == 0);#expect(result.1 == Data(StockRestoreCommands.marker(id:id,sha:sha).utf8)) }
        else { #expect(result.0 != 0) }
        if ["ok","burn-fails"].contains(fault) {
            #expect(try String(contentsOf:log,encoding:.utf8) == "burn_boot2 30\n")
            #expect(try Data(contentsOf:input) == bytes)
        } else { #expect(!FileManager.default.fileExists(atPath:log.path)) }
        #expect(FileManager.default.fileExists(atPath:ram.path))
    }
    @Test func failedPartitionQueryRetainsBoundedEvidence() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let tool=root.appendingPathComponent("tool")
        try Data("#!/bin/sh\nif test \"$1\" = ismd; then exit 1; fi\nprintf 'unrecognized-layout\\n'\nprintf 'partition read failed\\n' >&2\nexit 6\n".utf8).write(to:tool)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:tool.path)
        let script=try simulatedRAMPartitionQuery(StockRestoreCommands.partitions,in:root).replacingOccurrences(of:StockRestoreCommands.pins,with:":")
            .replacingOccurrences(of:"/bin/sntool",with:tool.path).replacingOccurrences(of:"/bin/sunxi-part",with:tool.path)
            .replacingOccurrences(of:"/tmp/swifthakchi-part.XXXXXX",with:root.appendingPathComponent("part.XXXXXX").path)
        let p=Process(), out=Pipe(), err=Pipe();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=["-c",script]
        p.standardOutput=out;p.standardError=err;try p.run()
        let stdout=out.fileHandleForReading.readDataToEndOfFile(), stderr=err.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        #expect(p.terminationStatus != 0)
        #expect(String(decoding:stdout,as:UTF8.self).contains("unrecognized-layout"))
        #expect(String(decoding:stderr,as:UTF8.self).contains("partition read failed"))
    }
    @Test(arguments:[false,true]) func partitionQueryAllowsFourMiBScratchButBoundsReturnedMetadata(oversized: Bool) throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let tool=root.appendingPathComponent("tool"), fixture=root.appendingPathComponent("fixture")
        try Data(legacyDetailedPartitionsFixture().utf8).write(to:fixture)
        let compact=root.appendingPathComponent("compact")
        try Data((oversized ? String(repeating:"X",count:16385) : legacyCompactPartitionsFixture()).utf8).write(to:compact)
        let body = #"""
        #!/bin/sh
        if test "$1" = ismd; then exit 1; fi
        dd if=/dev/zero of="$NES_SCRATCH" bs=1048576 count=4 2>/dev/null || exit 9
        if test "$#" = 0; then cat "$NES_COMPACT"; elif test "$#" = 1 && test "$1" = --nand-part; then cat "$NES_FIXTURE"; else exit 10; fi
        """#
        try Data(body.utf8).write(to:tool);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:tool.path)
        let script=try simulatedRAMPartitionQuery(StockRestoreCommands.partitions,in:root).replacingOccurrences(of:StockRestoreCommands.pins,with:":")
            .replacingOccurrences(of:"/bin/sntool",with:tool.path).replacingOccurrences(of:"/bin/sunxi-part",with:tool.path)
            .replacingOccurrences(of:"/tmp/swifthakchi-part.XXXXXX",with:root.appendingPathComponent("part.XXXXXX").path)
        let p=Process(),out=Pipe(),err=Pipe();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=["-c","sha256sum() { /usr/bin/shasum -a 256 \"$@\"; }\n"+script]
        p.environment=ProcessInfo.processInfo.environment.merging(["NES_SCRATCH":root.appendingPathComponent("scratch").path,"NES_FIXTURE":fixture.path,"NES_COMPACT":compact.path]){_,new in new}
        p.standardOutput=out;p.standardError=err;try p.run();let stdout=out.fileHandleForReading.readDataToEndOfFile();let stderr=err.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        if oversized {
            #expect(p.terminationStatus != 0 && stdout.count <= 16384)
            #expect(throws:(any Error).self){try StockRestoreCompletion.partitionData(.init(stdout:"",stderr:"",stdoutData:stdout,exitCode:0))}
            return
        }
        #expect(p.terminationStatus == 0,"\(String(decoding:stderr,as:UTF8.self))")
        #expect(String(decoding:stdout,as:UTF8.self).contains(legacyPartitionsFixture()))
        #expect(try StockRestoreCompletion.partitionData(.init(stdout:String(decoding:stdout,as:UTF8.self),stderr:String(decoding:stderr,as:UTF8.self),stdoutData:stdout,exitCode:Int(p.terminationStatus))) == Data(legacyPartitionsFixture().utf8))
    }
    @Test func zeroStatusWithoutCompleteProofCannotPassNativeChecks() throws {
        let bytes=Data(legacyPartitionsFixture().utf8), sha=BackupManifest.digest(bytes)
        let footer=Data("SWIFTHAKCHI_PARTITIONS_END_V1 \(bytes.count) \(sha)\n".utf8)
        func result(_ output:Data, exit:Int=0) -> SSHResult { .init(stdout:String(decoding:output,as:UTF8.self),stderr:"",stdoutData:output,exitCode:exit) }
        #expect(try StockRestoreCompletion.partitionData(result(bytes+footer)) == bytes)
        for r in [result(Data()),result(bytes),result(bytes+footer,exit:1),result(bytes+Data(footer.dropLast())),result(bytes+footer+Data("extra\n".utf8)),result(bytes+Data("SWIFTHAKCHI_PARTITIONS_END_V1 1 \(sha)\n".utf8))] {
            #expect(throws:(any Error).self){try StockRestoreCompletion.partitionData(r)}
        }
        let id=UUID(), created=StockRestoreCompletion.created(id:id), staged=StockRestoreCompletion.staged(id:id,sha:sha)
        try StockRestoreCompletion.require(result(Data(created.utf8)),marker:created)
        for value in ["",created,staged+"extra",StockRestoreCompletion.staged(id:UUID(),sha:sha)] {
            #expect(throws:(any Error).self){try StockRestoreCompletion.require(result(Data(value.utf8)),marker:staged)}
        }
    }
    @Test func reservedRawBootAreaPrecedesTheSeparateBootPartition() throws {
        let value=legacyPartitionsFixture()
        try StockRestorePartitions.validate(value)
        #expect(throws:(any Error).self){try StockRestorePartitions.validate(value.replacingOccurrences(of:"start =    32768",with:"start =    32767"))}
        // The separate boot partition may be3MiB; raw boot2 lies before it.
        #expect(value.contains("name =         boot, partition start =    32768, partition size =     6144"))
    }
    @Test func pinnedDetailedPrinterUsesOneBasedPartitionNumbers() throws {
        let value=legacyPartitionsFixture()
        try StockRestorePartitions.validate(value)
        for bad in [value.replacingOccurrences(of:"partition  1:",with:"partition 0:"),value.replacingOccurrences(of:"partition  5:",with:"partition  4:"),value.replacingOccurrences(of:"partition  3:",with:"partition  6:")] {
            #expect(throws:(any Error).self){try StockRestorePartitions.validate(bad)}
        }
    }
    @Test func compactMetadataDoesNotEstablishVersionAndRanges() throws {
        let value="mbr::32768 nanda:boot:6144 nandb:rootfs:38912 nandc:data:806912 nandd:private:2048 nande:UDISK:27648\n"
        #expect(throws:(any Error).self){try StockRestorePartitions.validate(value)}
        let bytes=Data(value.utf8), footer="SWIFTHAKCHI_PARTITIONS_END_V1 \(value.utf8.count) \(BackupManifest.digest(bytes))\n"
        #expect(throws:(any Error).self){try StockRestoreCompletion.partitionData(.init(stdout:value+footer,stderr:"",stdoutData:bytes+Data(footer.utf8),exitCode:0))}
    }
    @Test func capturedPairResolvesOnlyFinalUDISKAndRequiresAgreement() throws {
        let value=legacyPartitionsFixture()
        try StockRestorePartitions.validate(value)
        for bad in [legacyCompactPartitionsFixture(),legacyDetailedPartitionsFixture(),
            value.replacingOccurrences(of:"UDISK:27648",with:"UDISK:0"),
            value.replacingOccurrences(of:"UDISK:27648",with:"UDISK:4294967295"),
            value.replacingOccurrences(of:"boot:6144",with:"boot:6143"),
            value.replacingOccurrences(of:"data:806912",with:"data:806913"),
            value.replacingOccurrences(of:"nanda:boot:",with:"nandz:boot:"),
            value.replacingOccurrences(of:"mbr::32768",with:"mbr::032768"),
            value.replacingOccurrences(of:"SWIFTHAKCHI_DETAILED_PARTITIONS_V1",with:"unknown") ] {
            #expect(throws:(any Error).self){try StockRestorePartitions.validate(bad)}
        }
        // An explicit positive final length must agree with the live resolved view.
        try StockRestorePartitions.validate(value.replacingOccurrences(of:"size =        0 user_type=0",with:"size =    27648 user_type=0"))
        #expect(throws:(any Error).self){try StockRestorePartitions.validate(value.replacingOccurrences(of:"size =        0 user_type=0",with:"size =    27649 user_type=0"))}
    }
    @Test func allFourMBRCopiesMustReportOKInOrder() throws {
        let value=legacyPartitionsFixture()
        for bad in [value.replacingOccurrences(of:"copy 0:",with:"copy 1:"),value.replacingOccurrences(of:"\nOK\n",with:"\nBAD\n"),value.replacingOccurrences(of:"copy 3:",with:"copy 4:"),value.replacingOccurrences(of:"OK\ncheck partition table copy 1:",with:"check partition table copy 1:")] {
            #expect(throws:(any Error).self){try StockRestorePartitions.validate(bad)}
        }
    }
    @Test func onlyPositiveLegacyLayoutIsAccepted() throws {
        try StockRestorePartitions.validate(legacyPartitionsFixture())
        let value = legacyPartitionsFixture()
        for bad in ["",String(value.dropLast(12)),value+"extra\n",value.replacingOccurrences(of:"softw411",with:"softw311"),value.replacingOccurrences(of:"5 partitions",with:"4 partitions"),value.replacingOccurrences(of:"rootfs",with:"boot-res"),value.replacingOccurrences(of:"size =     6144",with:"size =        0"),value.replacingOccurrences(of:"start =    38912",with:"start =    32768"),value.replacingOccurrences(of:"32768",with:"4294967296")] {
            #expect(throws:(any Error).self){try StockRestorePartitions.validate(bad)}
        }
    }
}

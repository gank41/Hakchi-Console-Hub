import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct LegacyBoot2ActivationCommandTests {
    @Test(arguments: ["ok", "short", "bad-image", "wrong-owner", "wrong-partition", "check-fails", "burn-fails"])
    func checkedScriptDispatchesOnlyOneBoot2WriteAfterValidStage(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("sntool")
        let part = root.appendingPathComponent("sunxi-part")
        let flash = root.appendingPathComponent("sunxi-flash")
        let compact = root.appendingPathComponent("compact"), detailed = root.appendingPathComponent("detailed")
        let calls = root.appendingPathComponent("calls"), input = root.appendingPathComponent("input")
        try Data(legacyCompactPartitionsFixture().utf8).write(to: compact)
        try Data(legacyDetailedPartitionsFixture().utf8).write(to: detailed)
        let helper = #"""
        #!/bin/sh
        case "${0##*/}:$1" in
          sntool:ismd) exit 1;;
          sntool:check) test "$NES_FAULT" != check-fails;;
          sunxi-part:) cat "$NES_COMPACT";;
          sunxi-part:--nand-part) cat "$NES_DETAILED";;
          sunxi-flash:burn_boot2)
            printf '%s %s\n' "$1" "$2" >> "$NES_CALLS"
            cat > "$NES_INPUT"
            test "$NES_FAULT" != burn-fails;;
        esac
        """#
        try Data(helper.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        try FileManager.default.createSymbolicLink(at: part, withDestinationURL: tool)
        try FileManager.default.createSymbolicLink(at: flash, withDestinationURL: tool)
        let ram = root.appendingPathComponent("ram"), id = UUID(), bytes = snapshotFixture()
        let sha = BackupManifest.digest(bytes)
        func execute(_ script: String) throws -> (Int32, Data) {
            let pins = BackupManifest.digest(try Data(contentsOf: tool))
            let mapped = script.replacingOccurrences(of: "/bin/sntool", with: tool.path)
                .replacingOccurrences(of: "/bin/sunxi-part", with: part.path)
                .replacingOccurrences(of: "/bin/sunxi-flash", with: flash.path)
                .replacingOccurrences(of: LegacyBoot2ActivationCommands.directory, with: ram.path)
                .replacingOccurrences(of: "f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9", with: pins)
            let stubs = #"""
            sha256sum() { /usr/bin/shasum -a 256 "$@"; }
            readlink() { printf '%s\n' "$NES_TOOL"; }
            stat() { /usr/bin/stat -f %l "$3"; }
            """#
            let process = Process(), output = Pipe(), error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", stubs + "\n" + mapped]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "NES_FAULT": fault, "NES_TOOL": tool.path, "NES_COMPACT": compact.path,
                "NES_DETAILED": detailed.path, "NES_CALLS": calls.path, "NES_INPUT": input.path]) { _, new in new }
            process.standardOutput = output; process.standardError = error
            try process.run()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            _ = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, stdout)
        }
        let created = try execute(LegacyBoot2ActivationCommands.create(id: id))
        #expect(created.0 == 0)
        let staged = ram.appendingPathComponent("legacy.img")
        try Data(fault == "short" ? bytes.prefix(100) : bytes).write(to: staged)
        if fault == "bad-image" { var changed = bytes; changed[1024] ^= 1; try changed.write(to: staged) }
        if fault == "wrong-owner" { try Data("wrong".utf8).write(to: ram.appendingPathComponent("owner")) }
        let partitionSHA = fault == "wrong-partition" ? String(repeating: "0", count: 64) : BackupManifest.digest(Data(legacyPartitionsFixture().utf8))
        let result = try execute(LegacyBoot2ActivationCommands.burn(id: id, sha: sha, count: bytes.count, partitionSHA256: partitionSHA))
        if fault == "ok" {
            #expect(result.0 == 0)
            #expect(result.1 == Data(LegacyBoot2ActivationCommands.marker(id: id, sha: sha).utf8))
            #expect(try String(contentsOf: calls, encoding: .utf8) == "burn_boot2 30\n")
            #expect(try Data(contentsOf: input) == bytes)
        } else {
            #expect(result.0 != 0)
            if fault == "burn-fails" { #expect(try String(contentsOf: calls, encoding: .utf8) == "burn_boot2 30\n") }
            else { #expect(!FileManager.default.fileExists(atPath: calls.path)) }
        }
    }
}

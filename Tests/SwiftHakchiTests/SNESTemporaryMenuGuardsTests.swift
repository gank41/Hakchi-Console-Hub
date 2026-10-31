import Foundation
import Testing
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESTemporaryMenuGuardsTests {
    @Test(arguments: ["none", "readonly", "identity", "set-failure"])
    func readonlyGuardStopsBeforeMenuWhenABlockCannotBeProtected(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("busybox")
        for name in ["nanda", "nandb", "nandc", "nandd", "nande"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sys/\(name)"), withIntermediateDirectories: true)
            try Data((fault == "identity" && name == "nandc" ? "7:1\n" : "176:0\n").utf8).write(to: root.appendingPathComponent("sys/\(name)/dev"))
            try Data([0]).write(to: root.appendingPathComponent(name))
        }
        let shim = """
        #!/bin/sh
        case "$1" in
          stat) printf 'b0:0\\n';;
          cat) shift; /bin/cat "$@";;
          blockdev)
            case "$2" in
              --setro) test '\(fault)' != set-failure || exit 1; printf 'set\\n' >> '\(root.path)/sets';;
              --getro) test '\(fault)' != readonly || { printf '0\\n'; exit 0; }; printf '1\\n';;
              *) exit 91;;
            esac;;
          *) exit 92;;
        esac
        """
        try Data(shim.utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.path)
        let guards = SNESTemporaryMenuScripts.guards
            .replacingOccurrences(of: "/dev/", with: root.path + "/")
            .replacingOccurrences(of: "/sys/class/block/", with: root.path + "/sys/")
        let command = """
        set -eu
        B='\(bin.path)'
        fail() { exit 47; }
        test() { if [ "$1" = -b ]; then /bin/test -f "$2"; else /bin/test "$@"; fi; }
        \(guards)
        lock_blocks
        require_ro_blocks
        printf 'PROTECTED\\n'
        """
        let p = Process(), output = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c",command]
        p.standardOutput = output; p.standardError = errors
        try p.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let trace = errors.fileHandleForReading.readDataToEndOfFile()
        if fault == "none" && p.terminationStatus != 0 { Issue.record("\(String(decoding: trace.suffix(5000), as: UTF8.self))") }
        if fault == "none" { #expect(p.terminationStatus == 0); #expect(data == Data("PROTECTED\n".utf8)) }
        else { #expect(p.terminationStatus != 0); #expect(data.isEmpty) }
    }
    @Test(arguments: ["good", "low"])
    func memoryGateDoesNotStartMenuWhenRAMIsLow(kind: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meminfo")
        try Data((kind == "good" ? "MemTotal: 120000 kB\nMemFree: 40000 kB\nBuffers: 4000 kB\nCached: 8000 kB\n" : "MemTotal: 120000 kB\nMemFree: 1000 kB\nBuffers: 1 kB\nCached: 1 kB\n").utf8).write(to: file)
        let guardCode = SNESTemporaryMenuScripts.guards.replacingOccurrences(of: "/proc/meminfo", with: file.path)
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "set -eu\nB=busybox_fixture\nbusybox_fixture() { if [ \"$1\" = awk ]; then shift; /usr/bin/awk \"$@\"; else exit 9; fi; }\nfail() { exit 47; }\n" + guardCode + "\nrequire_memory\nprintf 'ENOUGH\\n'"]
        p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect((p.terminationStatus == 0) == (kind == "good"))
        #expect(bytes == (kind == "good" ? Data("ENOUGH\n".utf8) : Data()))
    }
}

struct SNESTemporaryMenuLogTests {
    @Test func loggingDrainsAfterLimitWithoutTerminatingProducer() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("log"), done = root.appendingPathComponent("done")
        let command = """
        set -eu
        B=bb
        bb() { case "$1" in head) shift; /usr/bin/head "$@";; cat) shift; /bin/cat "$@";; *) exit 9;; esac; }
        \(SNESTemporaryMenuScripts.logging)
        ( /bin/dd if=/dev/zero bs=65536 count=32 2>/dev/null && printf 'DONE' > '\(done.path)' ) | cap_log '\(log.path)'
        """
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c",command]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(try Data(contentsOf: log).count == 1048576)
        #expect(try Data(contentsOf: done) == Data("DONE".utf8))
    }
}

struct SNESTemporaryMenuDriverTests {
    @Test(arguments: ["none", "mali", "clovercon", "sunxi-keyboard", "sunxi-knob"])
    func rejectedDriverStopsBeforeMenuAndUsesSNESControllerParameters(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = root.appendingPathComponent("calls")
        let shim = """
        bb() {
          test "$1" = insmod || exit 92
          shift
          printf '%s\\n' "$*" >> '\(calls.path)'
          case "$1" in */\(fault).ko) return 42;; esac
        }
        """
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "set -eu\nB=bb\nfail() { exit 47; }\n" + shim + "\n" + SNESTemporaryMenuScripts.startupGate.replacingOccurrences(of: "/probe/", with: root.path + "/") + "\n" + SNESTemporaryMenuScripts.loadDrivers.replacingOccurrences(of: "/probe/controller-load", with: root.appendingPathComponent("controller-load").path) + "\nprintf 'START_MENU\\n'"]
        p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect(p.terminationStatus == (fault == "none" ? 0 : 47))
        #expect(bytes == (fault == "none" ? Data("START_MENU\n".utf8) : Data()))
        let receipt = try? Data(contentsOf: root.appendingPathComponent("controller-load"))
        #expect(receipt == (fault == "none" ? Data("loaded-arguments:1,-1,2,-1;36;0;0;8;0\n".utf8) : nil))
        let lines = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        if fault != "mali" {
            #expect(lines.contains("/probe/clovercon.ko module_params=1,-1,2,-1 home_combination=36 autofire=0 autofire_xy=0 autofire_interval=8 fc_start=0"))
        }
    }
}

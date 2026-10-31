import Foundation
import Darwin
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryNodeGuardTests {
    @Test(arguments: ["file-as-directory", "fifo-as-file", "fifo-as-directory"])
    func aFailedNodeTypeTestCannotBeHiddenByLaterSuccessfulStatChecks(_ fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let leaf = root.appendingPathComponent("node"), tools = root.appendingPathComponent("tools")
        if fault == "file-as-directory" { try Data("data".utf8).write(to: leaf) }
        else { #expect(mkfifo(leaf.path, 0o600) == 0) }
        // Simulate the console's root-owned single-link inode without accessing any device.
        try Data("#!/bin/sh\ncase \"$3\" in %u) echo 0;; %h) echo 1;; *) exit 1;; esac\n".utf8).write(to: tools)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tools.path)
        let prefix = try SNESLibraryInventoryCommands.prefix(context: String(repeating: "a", count: 64), hwid: String(repeating: "1", count: 32), runtime: String(repeating: "b", count: 64))
        let guards = prefix.components(separatedBy: "\n").filter { $0.hasPrefix("regular()") || $0.hasPrefix("directory()") }.joined(separator: "\n")
        let script = "set -eu\nB=" + LaunchCommand.shellQuote(tools.path) + "\n" + guards + "\n" +
            (fault == "fifo-as-file" ? "regular" : "directory") + " " + LaunchCommand.shellQuote(leaf.path) + "\nprintf ALLOWED\n"
        let process = Process(), out = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
        process.standardOutput = out; try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus != 0 && data.isEmpty)
    }
    @Test(arguments: ["none", "retroarch", "hc-snes-superv"])
    func inventoryRefusesWhileCompatibilityGameIsRunning(_ active: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools")
        let shim = """
        #!/bin/sh
        case "$1:$2" in
          pidof:clover-mcp) echo 100 ;;
          pidof:retroarch|pidof:hc-snes-superv) test "$2" = "$HC_TEST_PROCESS" && echo 201 ;;
          pidof:*) exit 1 ;;
          readlink:-f) echo /usr/bin/clover-mcp ;;
          *) exit 1 ;;
        esac
        """
        try Data(shim.utf8).write(to: tools)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tools.path)
        let prefix = try SNESLibraryInventoryCommands.prefix(context: String(repeating: "a", count: 64), hwid: String(repeating: "1", count: 32), runtime: String(repeating: "b", count: 64))
        let start = try #require(prefix.range(of: "no_game() {"))
        let end = try #require(prefix.range(of: "\n}", range: start.lowerBound..<prefix.endIndex))
        let function = String(prefix[start.lowerBound..<end.upperBound])
        let script = "set -eu\nB=" + LaunchCommand.shellQuote(tools.path) + "\n" + function + "\nno_game\nprintf ALLOWED\n"
        let process = Process(), out = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(["HC_TEST_PROCESS": active]) { _, new in new }
        process.standardOutput = out; try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(active != "none" ? (process.terminationStatus != 0 && data.isEmpty) : (process.terminationStatus == 0 && String(decoding: data, as: UTF8.self) == "ALLOWED"))
    }

}

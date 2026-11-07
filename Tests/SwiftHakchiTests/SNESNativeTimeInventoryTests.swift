import Foundation
import Testing
@testable import SwiftHakchi

struct SNESNativeTimeInventoryTests {
    @Test func acceptsOnlyBoundedHexSamples() throws {
        let frame = Data("SNES-TIME-V1\nSAMPLE STOCK 3 31320a\nSAMPLE ADDED 0 -\nEND\n".utf8)
        let result = try SNESNativeTimeInventory.parse(frame)
        #expect(result.samples == [Data([0x31, 0x32, 0x0a]), Data()])
        #expect(result.kinds == [.stock, .added])
        for invalid in ["SNES-TIME-V1\nSAMPLE STOCK 3 3132\nEND\n", "SNES-TIME-V1\nSAMPLE STOCK 1 FF\nEND\n", "SNES-TIME-V1\nSAMPLE STOCK 0 00\nEND\n", "SNES-TIME-V1\nSAMPLE UNKNOWN 1 00\nEND\n", "SNES-TIME-V1\nSAMPLE STOCK 33 " + String(repeating: "00", count: 33) + "\nEND\n", "SNES-TIME-V1\nSAMPLE STOCK 1 00\nEND\nEXTRA\n", "SNES-TIME-V1\n" + String(repeating: "SAMPLE STOCK 1 00\n", count: 9) + "END\n"] {
            #expect(throws: (any Error).self) { try SNESNativeTimeInventory.parse(Data(invalid.utf8)) }
        }
    }

    @Test func inventoryReadsOnlyBoundedRegularTimeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        let game = profiles.appendingPathComponent("CLV-P-ABCDE", isDirectory: true)
        let slot = game.appendingPathComponent("suspendpoint1", isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let time = slot.appendingPathComponent("state.time")
        try Data("123\n".utf8).write(to: time)
        let oversized = game.appendingPathComponent("suspendpoint2", isDirectory: true)
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 33).write(to: oversized.appendingPathComponent("state.time"))
        let linked = game.appendingPathComponent("suspendpoint3", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("state.time"), withDestinationURL: time)
        let added = profiles.appendingPathComponent("CLV-U-ABCDE/suspendpoint1", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try Data("9".utf8).write(to: added.appendingPathComponent("state.time"))
        try FileManager.default.createSymbolicLink(at: profiles.appendingPathComponent("CLV-P-XXXXX"), withDestinationURL: game)
        try FileManager.default.createSymbolicLink(at: game.appendingPathComponent("suspendpoint4"), withDestinationURL: slot)
        let unrelated = profiles.appendingPathComponent("CLV-X-ABCDE/suspendpoint1", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("not a console game".utf8).write(to: unrelated.appendingPathComponent("state.time"))
        let tool = root.appendingPathComponent("tool")
        let shim = "#!/bin/sh\ncase \"$1\" in\n stat) shift; [ \"$1\" = -c ] && shift 2; exec /usr/bin/stat -f %z \"$@\";;\n head|od|tr) cmd=$1; shift; exec /usr/bin/\"$cmd\" \"$@\";;\n *) exit 90;;\nesac\n"
        try Data(shim.utf8).write(to: tool); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let command = SNESNativeTimeInventory.command.replacingOccurrences(of: "B=/mnt/swifthakchi/busybox", with: "B='\(tool.path)'")
            .replacingOccurrences(of: "P=/var/lib/clover/profiles/0", with: "P='\(profiles.path)'")
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardOutput = output; process.standardError = errors; try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let inventory = try SNESNativeTimeInventory.parse(data)
        #expect(inventory.samples == [Data("123\n".utf8), Data("9".utf8)])
        #expect(inventory.kinds == [.stock, .added])
        #expect(try Data(contentsOf: time) == Data("123\n".utf8))
        #expect(try Data(contentsOf: oversized.appendingPathComponent("state.time")).count == 33)
    }
}

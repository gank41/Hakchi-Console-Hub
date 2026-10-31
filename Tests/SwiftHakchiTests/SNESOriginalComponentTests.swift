import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

let originalComponentPaths = ["lib/modules/3.4.113/extra/clvcon.ko", "lib/modules/3.4.113/extra/mali.ko",
    "lib/modules/3.4.113/kernel/drivers/input/keyboard/sunxi-keyboard.ko",
    "lib/modules/3.4.113/kernel/drivers/input/keyboard/sunxi-knob.ko", "usr/bin/clover-mcp"]
func originalComponentFiles() -> [String: Data] {
    Dictionary(uniqueKeysWithValues: originalComponentPaths.enumerated().map { ($0.element, Data([0, 255, 10, UInt8($0.offset+1)])) })
}
func originalComponentFrame(_ files: [String: Data] = originalComponentFiles(), order: [String] = originalComponentPaths) -> Data {
    var data = Data("SWIFTHAKCHI_SNES_ORIGINAL_COMPONENTS_V1\n".utf8)
    for name in order {
        let bytes = files[name]!
        data += Data("F \(name) \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8) + bytes + Data([10])
    }
    return data + Data("END\n".utf8)
}
struct SNESOriginalComponentTests {
    @Test func opaqueBytesRoundTripWithoutExecutionOrEncodingChanges() throws {
        let raw = originalComponentFrame(), frame = try SNESOriginalComponentFrame(raw)
        #expect(frame.raw == raw && frame.records.count == 5)
        #expect(frame.records.map(\.path) == originalComponentPaths)
        #expect(frame.records.map(\.data) == originalComponentPaths.map { originalComponentFiles()[$0]! })
    }
    @Test(arguments: ["missing", "duplicate", "order", "extra", "hash", "count", "kind", "leading-zero", "truncated", "trailing", "budget", "file-budget"])
    func rejectsChangedOrUnboundedFrames(fault: String) throws {
        var raw = originalComponentFrame()
        switch fault {
        case "missing": raw = originalComponentFrame(order: Array(originalComponentPaths.dropLast()))
        case "duplicate": raw = originalComponentFrame(order: [originalComponentPaths[0]] + originalComponentPaths)
        case "order": raw = originalComponentFrame(order: Array(originalComponentPaths.reversed()))
        case "extra": var f = originalComponentFiles(); f["usr/bin/other"] = Data([1]); raw = originalComponentFrame(f, order: originalComponentPaths + ["usr/bin/other"])
        case "hash": let r = try #require(raw.range(of: Data(BackupManifest.digest(originalComponentFiles()[originalComponentPaths[0]]!).utf8))); raw.replaceSubrange(r, with: Data(String(repeating: "0", count: 64).utf8))
        case "count", "kind", "leading-zero":
            let prefix = Data("F \(originalComponentPaths[0]) 4 ".utf8)
            let range = try #require(raw.range(of: prefix))
            raw.replaceSubrange(range, with: Data("\(fault == "kind" ? "B" : "F") \(originalComponentPaths[0]) \(fault == "count" ? "5" : (fault == "leading-zero" ? "04" : "4")) ".utf8))
        case "truncated": raw.removeLast()
        case "trailing": raw += Data([0])
        case "budget": raw = Data(count: 524289)
        default: var f = originalComponentFiles(); f[originalComponentPaths[0]] = Data(count: 262145); raw = originalComponentFrame(f)
        }
        #expect(throws: (any Error).self) { _ = try SNESOriginalComponentFrame(raw) }
    }
    @Test(arguments: ["normal", "parent-link", "source-link", "hardlink", "fifo", "nested", "large", "hash", "read", "stat", "alternate-data"])
    func fixedCaptureReadsOnlyRegularFilesAndNeverExecutesThem(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("newroot"), scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var files = originalComponentFiles()
        files["usr/bin/clover-mcp"] = Data("#!/bin/sh\ntouch '\(root.path)/executed'\n".utf8)
        for (name, bytes) in files {
            let url = original.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let target = original.appendingPathComponent(originalComponentPaths[0])
        if fault == "parent-link" {
            try FileManager.default.moveItem(at: original.appendingPathComponent("lib"), to: root.appendingPathComponent("outside"))
            try FileManager.default.createSymbolicLink(at: original.appendingPathComponent("lib"), withDestinationURL: root.appendingPathComponent("outside"))
        }
        if fault == "source-link" {
            try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("outside"))
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("outside"))
        }
        if fault == "hardlink" { try FileManager.default.linkItem(at: target, to: root.appendingPathComponent("other")) }
        if fault == "fifo" { try FileManager.default.removeItem(at: target); #expect(mkfifo(target.path, 0o600) == 0) }
        if fault == "large" { try Data(count: 262145).write(to: target) }
        let mounts = root.appendingPathComponent("mounts")
        try Data(("rootfs / rootfs rw 0 0\nsquash \(original.path) squashfs ro 0 0\n" + (fault == "nested" ? "tmpfs \(original.path)/lib tmpfs rw 0 0\n" : "")).utf8).write(to: mounts)
        if fault == "alternate-data" {
            let dataMount = try String(contentsOf: mounts, encoding: .utf8) + "/dev/nandc /capture-data ext4 ro 0 0\n"
            try Data(dataMount.utf8).write(to: mounts)
        }
        let sha = fault == "hash" ? "sha256sum() { return 9; }\n" : "sha256sum() { /usr/bin/shasum -a 256 \"$@\"; }\n"
        let read = fault == "read" ? "cat() { case \"$1\" in *clvcon.ko) return 9;; *) /bin/cat \"$@\";; esac; }\n" : ""
        var statCommand = #"stat() { /usr/bin/stat -f '%z:%l' "$3"; }"# + "\n"
        if fault == "stat" {
            statCommand = """
            stat() { n=$(cat '\(root.path)/stat-count' 2>/dev/null || printf 0); n=$((n+1)); printf '%s' "$n" > '\(root.path)/stat-count'; /usr/bin/stat -f '%z:%l' "$3"; test "$n" != 2; }
            """ + "\n"
        }
        let command = sha + read + statCommand + SNESOriginalComponentCommand.read
            .replacingOccurrences(of: "/newroot", with: original.path)
            .replacingOccurrences(of: "/proc/mounts", with: mounts.path)
            .replacingOccurrences(of: "/tmp/swifthakchi-components.", with: scratch.path + "/capture.")
            .replacingOccurrences(of: "test -d /tmp && test ! -L /tmp", with: "test -d '\(scratch.path)' && test ! -L '\(scratch.path)'")
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", command]; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        #expect((p.terminationStatus == 0) == (fault == "normal"))
        if fault == "normal" { #expect(try SNESOriginalComponentFrame(bytes).records.map(\.data) == originalComponentPaths.map { files[$0]! }) }
        else { #expect(bytes.isEmpty) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
    }
}

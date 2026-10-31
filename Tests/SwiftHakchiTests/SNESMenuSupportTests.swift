import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func menuSupportFixture(launcher: Data = Data("#!/bin/sh\nexit 0\n".utf8), extra: [String: Data] = [:]) -> Data {
    var records: [String: Data] = [:]
    for path in ["etc/asound.conf", "etc/clover/buildtype", "etc/clover/ui", "etc/group", "etc/nsswitch.conf", "etc/passwd", "etc/udev/udev.conf"] {
        records[path] = startupRecord("A", path)
    }
    records["usr/bin/clover-canoe-shvc"] = startupRecord("F", "usr/bin/clover-canoe-shvc", launcher)
    records["lib/udev/rules.d"] = startupRecord("D", "lib/udev/rules.d")
    records.merge(extra) { _, new in new }
    var result = Data("SWIFTHAKCHI_SNES_MENU_SUPPORT_V1\nTEXT_BEGIN\n".utf8)
    for path in records.keys.sorted() { result += records[path]! }
    result += Data("EXECUTABLES_BEGIN\n".utf8)
    for path in ["sbin/udevadm", "sbin/udevd", "usr/bin/clover-mcp", "usr/bin/udevadm"] {
        result += startupRecord(path == "sbin/udevadm" || path == "usr/bin/udevadm" ? "A" : "B", path,
                                count: path == "sbin/udevadm" || path == "usr/bin/udevadm" ? 0 : 128)
    }
    return result + Data("END\n".utf8)
}

@Suite(.serialized)
struct SNESMenuSupportTests {
    @Test func opaqueContentAndLiteralLinksAreEvidenceOnly() throws {
        let bytes = menuSupportFixture(extra: [
            "etc/group": startupRecord("F", "etc/group", Data([0,255,10])),
            "lib/udev/rules.d/01-input.rules": startupRecord("L", "lib/udev/rules.d/01-input.rules", Data("../../elsewhere".utf8))])
        let result = try SNESMenuSupportFrame(bytes)
        #expect(result.raw == bytes)
        #expect(result.records.first { $0.path == "etc/group" }?.data == Data([0,255,10]))
        #expect(result.records.first { $0.path == "sbin/udevd" }?.data == nil)
    }
    @Test(arguments: ["end", "trailing", "bad-hash", "bad-count", "duplicate", "bad-kind", "missing-launcher", "unsafe", "depth", "parent", "size", "link", "budget"])
    func rejectsMalformedOrUnboundedEvidence(fault: String) throws {
        var bytes = menuSupportFixture()
        switch fault {
        case "end": bytes = Data(bytes.dropLast())
        case "trailing": bytes += Data([0])
        case "bad-hash": bytes = menuSupportFixture(extra: ["etc/group": startupRecord("F", "etc/group", Data([1]), digest: String(repeating: "0", count: 64))])
        case "bad-count": bytes = menuSupportFixture(extra: ["etc/group": startupRecord("F", "etc/group", Data([1]), count: 2)])
        case "duplicate": bytes = menuSupportFixture(extra: ["etc/group": startupRecord("A", "etc/group") + startupRecord("A", "etc/group")])
        case "bad-kind": bytes = menuSupportFixture(extra: ["etc/group": startupRecord("B", "etc/group", count: 1)])
        case "missing-launcher": bytes = menuSupportFixture(extra: ["usr/bin/clover-canoe-shvc": startupRecord("A", "usr/bin/clover-canoe-shvc")])
        case "unsafe": bytes = menuSupportFixture(extra: ["lib/udev/rules.d/../x": startupRecord("F", "lib/udev/rules.d/../x", Data([1]))])
        case "depth": bytes = menuSupportFixture(extra: ["lib/udev/rules.d/a/b": startupRecord("F", "lib/udev/rules.d/a/b", Data([1]))])
        case "parent": bytes = menuSupportFixture(extra: ["lib/udev/rules.d": startupRecord("A", "lib/udev/rules.d"), "lib/udev/rules.d/a": startupRecord("F", "lib/udev/rules.d/a", Data([1]))])
        case "size": bytes = Data(count: 4*1024*1024+1)
        case "link": bytes = menuSupportFixture(extra: ["etc/group": startupRecord("L", "etc/group", Data([10]))])
        default:
            var extra: [String: Data] = [:]
            for i in 0..<128 { let p = String(format: "lib/udev/rules.d/%03d", i); extra[p] = startupRecord("L", p, Data("x".utf8)) }
            bytes = menuSupportFixture(extra: extra)
        }
        #expect(throws: (any Error).self) { _ = try SNESMenuSupportFrame(bytes) }
    }
    @Test(arguments: ["normal", "parent-link", "root-link", "hardlink", "fifo", "unsafe", "nested", "many", "large", "hash"])
    func fixedCaptureNeverExecutesOrFollowsOriginalFiles(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("newroot"), scratch = root.appendingPathComponent("scratch")
        for path in ["etc/clover", "etc/udev", "lib/udev/rules.d", "usr/bin", "sbin"] {
            try FileManager.default.createDirectory(at: original.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let launcher = "#!/bin/sh\ntouch '\(root.path)/executed'\n"
        try Data(launcher.utf8).write(to: original.appendingPathComponent("usr/bin/clover-canoe-shvc"))
        try Data("SUBSYSTEM==\"input\"\n".utf8).write(to: original.appendingPathComponent("lib/udev/rules.d/01-input.rules"))
        if fault == "parent-link" {
            try FileManager.default.moveItem(at: original.appendingPathComponent("etc"), to: root.appendingPathComponent("outside"))
            try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("etc").path, withDestinationPath: "../outside")
        }
        if fault == "root-link" {
            try FileManager.default.moveItem(at: original.appendingPathComponent("lib/udev/rules.d"), to: root.appendingPathComponent("rules"))
            try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("lib/udev/rules.d").path, withDestinationPath: "../../../rules")
        }
        if fault == "hardlink" { try FileManager.default.linkItem(at: original.appendingPathComponent("usr/bin/clover-canoe-shvc"), to: root.appendingPathComponent("other")) }
        if fault == "fifo" { #expect(mkfifo(original.appendingPathComponent("etc/group").path, 0o600) == 0) }
        if fault == "unsafe" { try Data([1]).write(to: original.appendingPathComponent("lib/udev/rules.d/bad;name")) }
        if fault == "many" { for i in 0..<128 { try Data([1]).write(to: original.appendingPathComponent("lib/udev/rules.d/a\(i)")) } }
        if fault == "large" { try Data(count: 65537).write(to: original.appendingPathComponent("etc/group")) }
        let mounts = root.appendingPathComponent("mounts")
        try Data(("rootfs / rootfs rw 0 0\nsquash \(original.path) squashfs ro 0 0\n" + (fault == "nested" ? "tmpfs \(original.path)/etc tmpfs rw 0 0\n" : "")).utf8).write(to: mounts)
        let sha = fault == "hash" ? "sha256sum() { return 1; }\n" : "sha256sum() { /usr/bin/shasum -a 256 \"$@\"; }\n"
        let command = sha + "stat() { /usr/bin/stat -f '%z:%l' \"$3\"; }\n" + SNESMenuSupportCommand.read
            .replacingOccurrences(of: "/newroot", with: original.path)
            .replacingOccurrences(of: "/proc/mounts", with: mounts.path)
            .replacingOccurrences(of: "/tmp/swifthakchi-menu-support.", with: scratch.path + "/capture.")
            .replacingOccurrences(of: "test -d /tmp && test ! -L /tmp", with: "test -d '\(scratch.path)' && test ! -L '\(scratch.path)'")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if fault == "normal" {
            #expect(process.terminationStatus == 0)
            let parsed = try SNESMenuSupportFrame(bytes)
            #expect(parsed.records.first { $0.path == "usr/bin/clover-canoe-shvc" }?.data == Data(launcher.utf8))
        } else { #expect(process.terminationStatus != 0); #expect(bytes.isEmpty) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
    }
}

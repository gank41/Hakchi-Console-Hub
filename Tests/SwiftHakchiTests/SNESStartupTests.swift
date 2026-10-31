import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func startupRecord(_ kind: String, _ path: String, _ data: Data = Data(), count: Int? = nil, digest: String? = nil) -> Data {
    let hasData = kind == "F" || kind == "L"
    let hash = ["A", "D"].contains(kind) ? "-" : (digest ?? BackupManifest.digest(data))
    var result = Data("\(kind) \(path) \(count ?? data.count) \(hash)\n".utf8)
    if hasData { result.append(data); result.append(10) }
    return result
}
func startupFrameFixture(extra: Data = Data(), modules: Data = Data()) -> Data {
    var data = Data("SWIFTHAKCHI_SNES_STARTUP_V1\nTEXT_BEGIN\n".utf8)
    data += startupRecord("L", "bin/busybox", Data("/bin/busybox.original".utf8))
    data += startupRecord("L", "bin/sh", Data("busybox".utf8))
    data += startupRecord("F", "etc/clover/REGION", Data("USA\n".utf8))
    data += startupRecord("F", "etc/clover/boardtype", Data("dp-shvc\n".utf8))
    data += startupRecord("A", "etc/fstab")
    data += startupRecord("D", "etc/init.d")
    data += extra
    data += startupRecord("F", "etc/inittab", Data("::sysinit:/etc/init.d/rcS\n".utf8))
    data += startupRecord("A", "etc/modules")
    data += startupRecord("A", "etc/modules-load.d")
    data += startupRecord("A", "etc/udev/rules.d")
    data += startupRecord("L", "sbin/init", Data("../bin/busybox".utf8))
    data += startupRecord("B", "usr/bin/clover-canoe-shvc", count: 1024, digest: String(repeating: "a", count: 64))
    data += Data("MODULES_BEGIN\n".utf8)
    data += startupRecord("D", "lib/modules")
    data += modules
    data += Data("END\n".utf8)
    return data
}
@Suite(.serialized)
struct SNESStartupTests {
    @Test(arguments: ["normal", "parent-link", "module-root-link", "nested-mount", "hardlink", "unsafe-name", "fifo", "deep-module", "hash-failure", "too-many-text"])
    func actualCaptureNeverFollowsOrExecutesSource(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("newroot"), scratch = root.appendingPathComponent("scratch")
        for path in ["etc/clover", "etc/init.d", "bin", "sbin", "usr/bin", "lib/modules/3.4.112/extra"] {
            try FileManager.default.createDirectory(at: original.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        for (path, content) in ["etc/clover/REGION": "USA\n", "etc/clover/boardtype": "dp-shvc\n", "etc/inittab": "::sysinit:/etc/init.d/rcS\n",
                                "bin/busybox": "binary", "usr/bin/clover-canoe-shvc": "binary", "lib/modules/3.4.112/extra/mali.ko": "module",
                                "etc/init.d/rcS": "#!/bin/sh\ntouch '\(root.path)/executed'\n"] {
            try Data(content.utf8).write(to: original.appendingPathComponent(path))
        }
        try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("bin/sh").path, withDestinationPath: "busybox")
        try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("sbin/init").path, withDestinationPath: "../bin/busybox")
        if fault == "parent-link" {
            try FileManager.default.moveItem(at: original.appendingPathComponent("etc"), to: root.appendingPathComponent("outside"))
            try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("etc").path, withDestinationPath: "../outside")
        }
        if fault == "hardlink" { try FileManager.default.linkItem(at: original.appendingPathComponent("etc/inittab"), to: root.appendingPathComponent("other")) }
        if fault == "module-root-link" {
            try FileManager.default.moveItem(at: original.appendingPathComponent("lib/modules"), to: root.appendingPathComponent("modules"))
            try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("lib/modules").path, withDestinationPath: "../../modules")
        }
        if fault == "unsafe-name" { try Data().write(to: original.appendingPathComponent("etc/init.d/bad;name")) }
        if fault == "fifo" { #expect(mkfifo(original.appendingPathComponent("etc/init.d/pipe").path, 0o600) == 0) }
        if fault == "deep-module" {
            try FileManager.default.createDirectory(at: original.appendingPathComponent("lib/modules/1/2/3/4/5/6/7/8/9"), withIntermediateDirectories: true)
        }
        if fault == "too-many-text" {
            for i in 0..<128 { try Data().write(to: original.appendingPathComponent("etc/init.d/file\(i)")) }
        }
        let mounts = root.appendingPathComponent("mounts")
        try Data(("rootfs / rootfs rw 0 0\nsquash \(original.path) squashfs ro 0 0\n" + (fault == "nested-mount" ? "tmpfs \(original.path)/etc/init.d tmpfs rw 0 0\n" : "")).utf8).write(to: mounts)
        let sha = fault == "hash-failure" ? "sha256sum() { return 9; }\n" : "sha256sum() { /usr/bin/shasum -a 256 \"$@\"; }\n"
        let command = sha + "stat() { /usr/bin/stat -f '%z:%l' \"$3\"; }\n" + SNESStartupCommand.read
            .replacingOccurrences(of: "/newroot", with: original.path)
            .replacingOccurrences(of: "/proc/mounts", with: mounts.path)
            .replacingOccurrences(of: "/tmp/swifthakchi-startup.", with: scratch.path + "/capture.")
            .replacingOccurrences(of: "test -d /tmp && test ! -L /tmp", with: "test -d '\(scratch.path)' && test ! -L '\(scratch.path)'")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if fault == "normal" {
            #expect(process.terminationStatus == 0)
            let parsed = try SNESStartupFrame(bytes)
            #expect(parsed.records.contains { $0.path == "lib/modules/3.4.112/extra/mali.ko" && $0.kind == "M" })
            #expect(parsed.records.contains { $0.path == "etc/fstab" && $0.kind == "A" })
        } else { #expect(process.terminationStatus != 0); #expect(bytes.isEmpty) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path) == false)
    }
    @Test func capturesOpaqueTextLinksAbsenceAndModuleMetadata() throws {
        let scripts = startupRecord("F", "etc/init.d/S00test", Data([0, 255, 10, 35]))
        let modules = startupRecord("D", "lib/modules/3.4.112") + startupRecord("M", "lib/modules/3.4.112/mali.ko", count: 100, digest: String(repeating: "b", count: 64))
        let bytes = startupFrameFixture(extra: scripts, modules: modules)
        let frame = try SNESStartupFrame(bytes)
        #expect(frame.raw == bytes)
        #expect(frame.records.first { $0.path == "etc/init.d/S00test" }?.data == Data([0, 255, 10, 35]))
        #expect(frame.records.first { $0.path.hasSuffix("mali.ko") }?.count == 100)
    }
    @Test(arguments: ["../escape", "etc/init.d/../escape", "etc/init.d/bad name", "etc/init.d/bad;name", "etc/init.d/a/b", "/etc/init.d/a", "etc/init.d/é"])
    func refusesUnlistedOrUnsafePaths(path: String) throws {
        #expect(throws: (any Error).self) { try SNESStartupFrame(startupFrameFixture(extra: startupRecord("F", path, Data("bad".utf8)))) }
    }
    @Test func rejectsIncompleteDuplicateBadCountsHashesAndMissingParents() throws {
        let valid = startupFrameFixture()
        for bad in [Data(valid.dropLast()), valid + Data([0]), Data(valid.dropFirst()),
                    startupFrameFixture(extra: startupRecord("F", "etc/inittab", Data())),
                    startupFrameFixture(extra: startupRecord("F", "etc/init.d/test", Data("a".utf8), count: 65537)),
                    startupFrameFixture(extra: startupRecord("F", "etc/init.d/test", Data("a".utf8), digest: String(repeating: "0", count: 64))),
                    startupFrameFixture(modules: startupRecord("M", "lib/modules/missing/mali.ko", count: 10)),
                    startupFrameFixture(modules: startupRecord("M", "lib/modules/mali.ko", count: 8*1024*1024+1))] {
            #expect(throws: (any Error).self) { try SNESStartupFrame(bad) }
        }
        let wrongBoard = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "dp-shvc", with: "dp-nesx").utf8)
        #expect(throws: (any Error).self) { try SNESStartupFrame(wrongBoard) }
        #expect(throws: (any Error).self) { try SNESStartupFrame(Data(count: 12*1024*1024+1)) }
    }
    @Test func linkRecordsAlsoConsumeTextFileBudget() throws {
        var links = Data()
        for index in 0..<128 { links += startupRecord("L", String(format: "etc/init.d/l%03d", index), Data("elsewhere".utf8)) }
        #expect(throws: (any Error).self) { try SNESStartupFrame(startupFrameFixture(extra: links)) }
    }
}

import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func runtimeELFFixture(_ role: String) -> Data {
    let dependencies = role == "loader" ? [] : (role == "libc" ? ["ld-linux-armhf.so.3"] : ["libc.so.6", "ld-linux-armhf.so.3"])
    var bytes = Data(count: 1024)
    bytes.replaceSubrange(0..<7, with: [127, 69, 76, 70, 1, 1, 1])
    func write(_ offset: Int, _ value: UInt32, count: Int = 4) {
        bytes.replaceSubrange(offset..<offset+count, with: (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0*8)) })
    }
    write(16, role == "daemon" ? 2 : 3, count: 2); write(18, 40, count: 2); write(20, 1)
    write(28, 52); write(36, 0x05000400); write(40, 52, count: 2); write(42, 32, count: 2)
    write(44, role == "loader" ? 2 : 3, count: 2)
    var strings = Data([0]), needed: [UInt32] = []
    for name in dependencies { needed.append(UInt32(strings.count)); strings.append(Data(name.utf8)); strings.append(0) }
    bytes.replaceSubrange(512..<512+strings.count, with: strings)
    var dynamic: [(UInt32, UInt32)] = [(5, 0x1200), (10, UInt32(strings.count))]
    dynamic += needed.map { (1, $0) }; dynamic.append((0, 0))
    for (index, item) in dynamic.enumerated() { write(256+index*8, item.0); write(260+index*8, item.1) }
    let programs: [[UInt32]] = [[1, 0, 0x1000, 0, 1024, 1024, 5, 4096],
        [2, 256, 0x1100, 0, UInt32(dynamic.count*8), UInt32(dynamic.count*8), 4, 4]]
    for (index, program) in programs.enumerated() { for (field, value) in program.enumerated() { write(52+index*32+field*4, value) } }
    if role != "loader" {
        let path = Data("/lib/ld-linux-armhf.so.3\0".utf8)
        bytes.replaceSubrange(800..<800+path.count, with: path)
        for (field, value) in [UInt32(3), 800, 0x1320, 0, UInt32(path.count), UInt32(path.count), 4, 1].enumerated() { write(116+field*4, value) }
    }
    return bytes
}
func runtimeFrameFixture() -> Data {
    var frame = Data("SWIFTHAKCHI_SNES_RUNTIME_V1\n".utf8)
    for (role, chain) in [("loader", "ld-linux-armhf.so.3>ld-2.23.so"), ("libc", "libc.so.6>libc-2.23.so")] {
        let bytes = runtimeELFFixture(role)
        frame.append(Data("\(role) \(chain) \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8))
        frame.append(bytes); frame.append(10)
    }
    frame.append(Data("END\n".utf8)); return frame
}
func runtimeBindingFixture() -> SNESRuntimeBinding {
    .init(sourceSnapshot: "SNES-US-Setup-11111111-1111-1111-1111-111111111111",
          setupManifestSHA256: String(repeating: "a", count: 64), expectedHWID: "0123456789abcdef0123456789abcdef")
}
actor RuntimeCaptureIO: RecoveryProbeIO {
    var events: [String] = []
    let fault: String
    let hwid: String
    var reads = 0
    init(_ fault: String = "none", hwid: String = runtimeBindingFixture().expectedHWID) { self.fault = fault; self.hwid = hwid }
    func inventory() -> [RecoveryProbeUSBDevice] { events.append("inventory"); return events.count == 1 ? [probeFEL()] : [probeRNDIS()] }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) { events.append("boot") }
    func connect(expected: RecoveryProbeUSBDevice) { events.append("connect") }
    func disconnect() { events.append("disconnect") }
    func observe() -> String {
        events.append("observe")
        let observed = snesObservation().replacingOccurrences(of: runtimeBindingFixture().expectedHWID, with: hwid)
        return fault == "identity" ? observed.replacingOccurrences(of: "HWID=", with: "HWID=1") : observed
    }
    func readSNESRuntime() throws -> Data {
        events.append("read"); reads += 1
        if fault == "cancel" { throw CancellationError() }
        if fault == "read" { throw RecoveryProbeError.refused("test read failure") }
        let bytes = runtimeFrameFixture()
        return fault == "changed" && reads == 2 ? bytes + Data([0]) : bytes
    }
}
struct SNESRuntimeCaptureTests {
    @Test func mappedDynamicTablesAndUnsupportedDependencyTagsAreRejected() throws {
        func setting(_ data: Data, _ offset: Int, _ value: UInt32) -> Data {
            var result = data
            result.replaceSubrange(offset..<offset+4, with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0*8)) })
            return result
        }
        let valid = runtimeELFFixture("libc")
        // PT_DYNAMIC's file and virtual locations must identify the same mapped bytes.
        #expect(throws: (any Error).self) { try ARMRuntimeELF(data: setting(valid, 92, 0x1140)) }
        // A second overlapping PT_LOAD would make runtime mapping ambiguous.
        var overlap = setting(valid, 116, 1)
        overlap = setting(overlap, 120, 0); overlap = setting(overlap, 124, 0x1000)
        overlap = setting(overlap, 132, 1024); overlap = setting(overlap, 136, 1024)
        #expect(throws: (any Error).self) { try ARMRuntimeELF(data: overlap) }
        // Zero-filled load memory must not cover another segment's mapped bytes.
        var bss = setting(valid, 72, 2048)
        bss = setting(bss, 116, 1); bss = setting(bss, 120, 800); bss = setting(bss, 124, 0x1400)
        bss = setting(bss, 132, 224); bss = setting(bss, 136, 224)
        #expect(throws: (any Error).self) { try ARMRuntimeELF(data: bss) }
        for tag: UInt32 in [15, 29, 0x7fffffff, 0x7ffffffd, 0x6ffffefa, 0x6ffffefb, 0x6ffffefc] {
            // Append unsupported load-affecting tags without changing DT_NEEDED.
            var changed = setting(valid, 280, tag); changed = setting(changed, 284, 1)
            changed = setting(changed, 288, 0); changed = setting(changed, 292, 0)
            changed = setting(changed, 100, 40); changed = setting(changed, 104, 40)
            #expect(throws: (any Error).self) { try ARMRuntimeELF(data: changed) }
        }
    }
    @Test func onlyExactPinnedDaemonRPathCanBeInspected() throws {
        var bytes = runtimeELFFixture("libc")
        let path = Data("-nostartfiles\0".utf8), at = 512 + Data("\0ld-linux-armhf.so.3\0".utf8).count
        bytes.replaceSubrange(at..<at+path.count, with: path)
        bytes[268] = UInt8(at - 512 + path.count) // DT_STRSZ
        bytes[280] = 15; bytes[284] = UInt8(at - 512) // Replace DT_NULL with DT_RPATH.
        bytes[100] = 40; bytes[104] = 40
        #expect(throws: (any Error).self) { try ARMRuntimeELF(data: bytes) }
        _ = try ARMRuntimeELF(data: bytes, allowedRPath: "-nostartfiles")
        #expect(throws: (any Error).self) { try ARMRuntimeELF(data: bytes, allowedRPath: "/other") }
    }
    @Test(arguments: ["normal", "parent-link", "nested-mount", "file-mount"])
    func actualReadCommandRejectsLibraryDirectoryEscape(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("newroot"), library = original.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try runtimeELFFixture("loader").write(to: library.appendingPathComponent("ld-linux-armhf.so.3"))
        try runtimeELFFixture("libc").write(to: library.appendingPathComponent("libc.so.6"))
        if fault == "parent-link" {
            let other = root.appendingPathComponent("other")
            try FileManager.default.moveItem(at: library, to: other)
            try FileManager.default.createSymbolicLink(at: library, withDestinationURL: other)
        }
        var mounts = "squash /newroot squashfs ro 0 0\n"
        if fault == "nested-mount" { mounts += "tmpfs /newroot/lib tmpfs rw 0 0\n" }
        if fault == "file-mount" { mounts += "tmpfs /newroot/lib/libc.so.6 tmpfs rw 0 0\n" }
        let mountPath = root.appendingPathComponent("mounts")
        try Data(mounts.replacingOccurrences(of: "/newroot", with: original.path).utf8).write(to: mountPath)
        let command = "sha256sum() { /usr/bin/shasum -a 256 \"$@\"; }\n" + SNESRuntimeCommand.read
            .replacingOccurrences(of: "/newroot", with: original.path)
            .replacingOccurrences(of: "/proc/mounts", with: mountPath.path)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if fault == "normal" { #expect(process.terminationStatus == 0); _ = try SNESRuntimeFrame(bytes) }
        else { #expect(process.terminationStatus != 0); #expect(bytes.isEmpty) }
    }
    @Test func boundedELFAndClosedDependencySet() throws {
        let loader = try ARMRuntimeELF(data: runtimeELFFixture("loader"))
        #expect(loader.dependencies.isEmpty)
        #expect(try ARMRuntimeELF(data: runtimeELFFixture("daemon")).interpreter == "/lib/ld-linux-armhf.so.3")
        let frame = try SNESRuntimeFrame(runtimeFrameFixture())
        #expect(frame.loader.count == 1024 && frame.libc.count == 1024)
        var staticExecutable = runtimeELFFixture("loader")
        staticExecutable[16] = 2; staticExecutable[36] |= 2
        #expect(try ARMRuntimeELF(data: staticExecutable).type == 2)
        for offset in [0, 4, 5, 18, 20, 28, 36, 42, 44, 260] {
            var bad = runtimeELFFixture("libc"); bad[offset] ^= 255
            #expect(throws: (any Error).self) { try ARMRuntimeELF(data: bad) }
        }
        #expect(throws: (any Error).self) { try ARMRuntimeELF(data: Data(count: 2*1024*1024+1)) }
    }
    @Test func malformedRuntimeFrameIsRejectedBeforeMaterial() throws {
        let valid = runtimeFrameFixture()
        for bytes in [Data(valid.dropLast()), valid + Data([0]), Data(valid.prefix(25)),
                      Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "ld-2.23.so", with: "../evil.so").utf8)] {
            #expect(throws: (any Error).self) { try SNESRuntimeFrame(bytes) }
        }
        var changed = valid; changed[150] ^= 1
        #expect(throws: (any Error).self) { try SNESRuntimeFrame(changed) }
    }
    @Test(arguments: ["none", "identity", "changed", "read", "cancel"])
    func captureReadsTwiceClosesAndNeverRetries(_ fault: String) async throws {
        let io = RuntimeCaptureIO(fault), raw = try PinnedFELInputs.load()
        do {
            let report = try await SNESRuntimeCaptureService(wait: {}).capture(binding: runtimeBindingFixture(),
                inputs: .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage), io: io)
            #expect(fault == "none")
            #expect(report.frame.loader == runtimeELFFixture("loader"))
        } catch { #expect(fault != "none") }
        #expect(await io.events.filter { $0 == "boot" }.count == 1)
        #expect(await io.events.last == "disconnect")
        if fault == "none" { #expect(await io.reads == 2) }
    }
    @Test func fixedLibraryCommandHasNoWriteOrCallerPath() throws {
        let command = SNESRuntimeCommand.read
        for forbidden in ["burn_", "mount ", " > /", "source ", "eval ", "switch_root", "reboot", "install "] {
            #expect(command.contains(forbidden) == false)
        }
        #expect(command.contains("/newroot/lib/"))
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-n", "-c", command]
        try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 0)
    }
}

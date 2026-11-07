import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESReplacementSaveHelperTests {
    @Test func bundledHelperIsPortableAndRejectsChangedBytes() throws {
        let helper = try SNESReplacementSaveHelper.bundled()
        #expect(helper.bytes.count > 0)
        #expect(helper.bytes.range(of: Data("/Users/".utf8)) == nil)
        #expect(helper.bytes.range(of: Data("/Development/NES".utf8)) == nil)
        let elf = try ARMRuntimeELF(data: helper.bytes)
        #expect(elf.type == 2 && elf.interpreter == nil && elf.dependencies.isEmpty)
        var changed = helper.bytes; changed[changed.count - 1] ^= 1
        #expect(throws: (any Error).self) { try SNESReplacementSaveHelper.validate(changed) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveHelper.validate(Data(helper.bytes.dropLast())) }
    }

    @Test(arguments: ["new", "same", "same-truncated", "different", "link", "truncated"])
    func temporaryHelperDeliveryNeverReplacesAnExistingFile(_ scenario: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        _ = try SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: data, runtime: runtime, fault: "valid")
        let helper = try SNESReplacementSaveHelper.bundled(), nonce = UUID()
        let request = try SNESReplacementSaveHelperDelivery.prepare(helper: helper, hwid: String(repeating: "1", count: 32),
            contextSHA256: String(repeating: "a", count: 64), runtimeSHA256: String(repeating: "b", count: 64),
            selection: .init(kind: .builtin, id: nil, treeSHA256: nil, selectorSHA256: BackupManifest.digest(Data())), challenge: nonce)
        if scenario == "new", let path = ProcessInfo.processInfo.environment["SNES_HELPER_DELIVERY_ARM_FIXTURE"] {
            let fixture = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            try Data(request.script.utf8).write(to: fixture.appendingPathComponent("script"))
            try request.input.write(to: fixture.appendingPathComponent("input"))
            try request.receipt.write(to: fixture.appendingPathComponent("receipt"))
        }
        let target = runtime.appendingPathComponent("snes-save-profile-switch")
        if scenario == "same" || scenario == "same-truncated" { try helper.bytes.write(to: target); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }
        if scenario == "different" { try Data("keep".utf8).write(to: target) }
        if scenario == "link" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: data) }
        let marker = "# SNES_HELPER_DELIVERY_BODY\n"
        let parts = request.script.components(separatedBy: marker)
        #expect(parts.count == 2)
        let stub = """
        set -eu
        set -o pipefail
        B='\(runtime.path)/busybox'; R='\(runtime.path)'; M='\(root.path)'
        regular() { test -f "$1" && test ! -L "$1" && test "$("$B" stat -c '%h' "$1")" = 1; }
        directory() { test -d "$1" && test ! -L "$1"; }
        current_selection() { :; }
        no_game() { :; }
        """ + "\n"
        let script = stub + parts[1].replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("helper-mounts").path)
        try Data("tmpfs /mnt tmpfs rw 0 0\n".utf8).write(to: root.appendingPathComponent("helper-mounts"))
        let scriptURL = root.appendingPathComponent("deliver.sh"), inputURL = root.appendingPathComponent("input")
        try Data(script.utf8).write(to: scriptURL)
        try (["truncated", "same-truncated"].contains(scenario) ? Data(request.input.prefix(10)) : request.input).write(to: inputURL)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [scriptURL.path]
        process.standardInput = try FileHandle(forReadingFrom: inputURL); process.standardOutput = output; process.standardError = errors
        try process.run(); let reply = output.fileHandleForReading.readDataToEndOfFile(), error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if scenario == "new" || scenario == "same" {
            #expect(process.terminationStatus == 0, "\(String(decoding: error, as: UTF8.self))")
            #expect(reply == request.receipt)
            #expect(try Data(contentsOf: target) == helper.bytes)
        } else {
            #expect(process.terminationStatus != 0)
            if scenario == "different" { #expect(try Data(contentsOf: target) == Data("keep".utf8)) }
            if scenario == "link" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == data.path) }
            if scenario == "same-truncated" { #expect(try Data(contentsOf: target) == helper.bytes) }
            if scenario == "truncated", FileManager.default.fileExists(atPath: target.path) {
                #expect(try Data(contentsOf: target) != helper.bytes)
                let mode = try #require(FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
                #expect(mode.intValue & 0o111 == 0)
            }
        }
    }
}

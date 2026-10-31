import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryDiscardUploadTests {
    func frame(_ request: SNESLibraryDiscardUploadCommands.Request, upload: String) -> Data {
        Data(["SWIFTHAKCHI_SNES_UPLOAD_V1 " + request.challenge.uuidString, "CONTEXT " + request.contextSHA256,
            "HWID " + request.hwid, "MENU " + request.id.uuidString, "SELECTOR " + request.selectorSHA256,
            upload, "END", ""].joined(separator: "\n").utf8)
    }
    @Test(arguments: ["absent", "empty", "present", "wrong-menu", "wrong-selector", "extra", "leading-zero", "oversize", "bad-hash"])
    func uploadReportIsBoundedAndBoundToThisExactUnshownMenu(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root)
        let request = try SNESLibraryDiscardUploadCommands.prepare(plan: plan, contextSHA256: plan.before.contextSHA256,
            runtimeSHA256: String(repeating: "b", count: 64), challenge: UUID())
        let bytes = fault == "empty" ? Data() : Data(repeating: 1, count: 17), hash = BackupManifest.digest(bytes)
        var raw = frame(request, upload: fault == "absent" ? "UPLOAD absent" : "UPLOAD \(bytes.count) \(hash)")
        var text = String(decoding: raw, as: UTF8.self)
        if fault == "wrong-menu" { text = text.replacingOccurrences(of: request.id.uuidString, with: UUID().uuidString) }
        if fault == "wrong-selector" { text = text.replacingOccurrences(of: "SELECTOR " + request.selectorSHA256, with: "SELECTOR " + String(repeating: "f", count: 64)) }
        if fault == "extra" { text += "extra\n" }
        if fault == "leading-zero" { text = text.replacingOccurrences(of: "UPLOAD 17 ", with: "UPLOAD 017 ") }
        if fault == "oversize" { text = text.replacingOccurrences(of: "UPLOAD 17 ", with: "UPLOAD 4194401 ") }
        if fault == "bad-hash" { text = text.replacingOccurrences(of: hash, with: "unknown") }
        raw = Data(text.utf8)
        if ["absent", "empty", "present"].contains(fault) {
            let parsed = try SNESLibraryDiscardUploadInspection(raw, request: request)
            #expect(parsed.upload == (fault == "absent" ? nil : .init(byteCount: bytes.count, sha256: hash)))
        } else { #expect(throws: (any Error).self) { try SNESLibraryDiscardUploadInspection(raw, request: request) } }
    }
    @Test(arguments: ["present", "empty", "missing", "link", "hardlink", "oversize", "selector", "game"])
    func fixedReaderNeverChangesFilesAndRejectsUnsafeUploads(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input"))
        let data = root.appendingPathComponent("data"), runtime = root.appendingPathComponent("runtime")
        for path in [data, runtime, data.appendingPathComponent("clover")] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let profile = data.appendingPathComponent("clover/settings.json"), sentinel = Data("{}".utf8)
        try sentinel.write(to: profile)
        let upload = data.appendingPathComponent("swifthakchi/snes-v2/menus/" + plan.material.menu.id.uuidString + "/.upload")
        let outside = root.appendingPathComponent("outside"), bytes = fault == "empty" ? Data() : Data(repeating: 1, count: fault == "oversize" ? 4194401 : 17)
        try bytes.write(to: outside)
        if fault != "missing" {
            try FileManager.default.createDirectory(at: upload.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fault == "link" { try FileManager.default.createSymbolicLink(at: upload, withDestinationURL: outside) }
            else if fault == "hardlink" { try FileManager.default.linkItem(at: outside, to: upload) }
            else { try bytes.write(to: upload) }
        }
        if fault == "selector" { try Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n".utf8).write(to: data.appendingPathComponent("swifthakchi/snes-v2/active-menu")) }
        _ = try await SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: data, runtime: runtime, fault: fault == "game" ? "game" : "valid")
        let bb = runtime.appendingPathComponent("busybox")
        let shim = try String(contentsOf: bb).replacingOccurrences(of: "stat)\n", with: "stat)\n            if test \"$2\" = -L;then shift;fi\n")
        try Data(shim.utf8).write(to: bb)
        let pin = BackupManifest.digest(Data(shim.utf8)), checks = Data((pin + "  " + bb.path + "\n").utf8)
        try checks.write(to: runtime.appendingPathComponent("runtime-files.sha256"))
        let request = try SNESLibraryDiscardUploadCommands.prepare(plan: plan, contextSHA256: plan.before.contextSHA256,
            runtimeSHA256: BackupManifest.digest(checks), challenge: UUID())
        let script = request.script.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib", with: data.path).replacingOccurrences(of: "/etc/clover", with: root.path)
            .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
            .replacingOccurrences(of: "/proc/$$/fd/7", with: upload.path)
            .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
        process.standardOutput = out; process.standardError = err
        try process.run(); let reply = out.fileHandleForReading.readDataToEndOfFile(), errors = err.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(try Data(contentsOf: profile) == sentinel && Data(contentsOf: outside) == bytes)
        if ["present", "empty", "missing"].contains(fault) {
            #expect(process.terminationStatus == 0, "\(String(decoding: errors, as: UTF8.self))")
            let parsed = try SNESLibraryDiscardUploadInspection(reply, request: request)
            #expect(parsed.upload == (fault == "missing" ? nil : .init(byteCount: bytes.count, sha256: BackupManifest.digest(bytes))))
        } else { #expect(process.terminationStatus != 0) }
    }
}

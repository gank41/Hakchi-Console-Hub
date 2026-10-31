import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCleanupCommandsTests {
    @Test(arguments: ["valid", "partial", "link", "hardlink", "extra", "changed", "game", "parent-link"])
    func previewIsReadOnlyAndRejectsForeignOrChangedNodes(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("input"); try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let (plan, live, backup, originals) = try await SNESLibraryCleanupPlanTests().fixture(inputs, changedROM: true)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: live, backup: backup, originals: originals)
        let nonce = UUID(), runtimeHash = String(repeating: "b", count: 64)
        let request = try SNESLibraryCleanupCommands.preview(scope: scope, contextSHA256: live.contextSHA256, runtimeSHA256: runtimeHash, challenge: nonce)
        #expect(request.script.utf8.count < 65536 && !request.script.contains(" rm ") && !request.script.contains(" mkdir "))
        let data = root.appendingPathComponent("data"), runtime = root.appendingPathComponent("runtime")
        for dir in [data, runtime, data.appendingPathComponent("clover")] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let pin = try SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: data, runtime: runtime, fault: fault)
        func host(_ logical: String) -> URL {
            URL(fileURLWithPath: SNESLibraryCleanupCommands.path(logical).replacingOccurrences(of: "/var/lib", with: data.path))
        }
        for file in scope.files {
            let path = host(file.path); try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plan.backup.read(path: file.path).write(to: path)
        }
        let namespace = data.appendingPathComponent("swifthakchi/snes-v2"), newMenu = plan.material.menu
        var protected: [String: Data] = newMenu.files.reduce(into: [:]) { $0["menus/" + newMenu.id.uuidString + "/" + $1.key] = $1.value }
        for (name, bytes) in newMenu.objects { protected["objects/" + name] = bytes }
        protected["menus/" + newMenu.id.uuidString + "/menu.manifest"] = try SNESLibraryStartupScripts.manifest(for: newMenu)
        protected["descriptions/" + newMenu.id.uuidString + ".json"] = newMenu.manifest
        for (name, bytes) in protected {
            let path = namespace.appendingPathComponent(name); try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true); try bytes.write(to: path)
        }
        let selected = data.appendingPathComponent("swifthakchi/snes-v2/active-menu"), selector = try scope.selection.bytes()
        try FileManager.default.createDirectory(at: selected.deletingLastPathComponent(), withIntermediateDirectories: true); try selector.write(to: selected)
        let outside = root.appendingPathComponent("outside"), sentinel = Data("untouched".utf8); try sentinel.write(to: outside)
        let first = host(try #require(scope.files.first).path)
        if fault == "partial" { try FileManager.default.removeItem(at: first) }
        if fault == "changed" { try sentinel.write(to: first) }
        if fault == "link" { try FileManager.default.removeItem(at: first); try FileManager.default.createSymbolicLink(at: first, withDestinationURL: outside) }
        if fault == "hardlink" { try FileManager.default.removeItem(at: first); try FileManager.default.linkItem(at: outside, to: first) }
        let oldRoot = host("menus/" + (try #require(scope.oldMenuID)).uuidString)
        if fault == "extra" { try sentinel.write(to: oldRoot.appendingPathComponent("unlisted")) }
        if fault == "parent-link" {
            let menus = oldRoot.deletingLastPathComponent(), moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: menus, to: moved); try FileManager.default.createSymbolicLink(at: menus, withDestinationURL: moved)
        }
        func hex(_ value: String) -> String { Data(value.utf8).map { String(format: "%02x", $0) }.joined() }
        var body = String(decoding: request.body, as: UTF8.self)
        for logical in scope.files.map(\.path) + scope.directories {
            body = body.replacingOccurrences(of: hex(SNESLibraryCleanupCommands.path(logical)), with: hex(host(logical).path))
        }
        let bytes = Data(body.utf8), input = root.appendingPathComponent("table"); try bytes.write(to: input)
        let script = request.script.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib", with: data.path).replacingOccurrences(of: "/etc/clover", with: root.path)
            .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
            .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
            .replacingOccurrences(of: runtimeHash, with: BackupManifest.digest(try Data(contentsOf: runtime.appendingPathComponent("runtime-files.sha256"))))
            .replacingOccurrences(of: BackupManifest.digest(request.body), with: BackupManifest.digest(bytes))
            .replacingOccurrences(of: "head -c " + String(request.body.count), with: "head -c " + String(bytes.count))
        let (status, raw, err) = try await SNESLibraryCleanupTestRunner.run(script, input: input)
        #expect(try Data(contentsOf: outside) == sentinel && Data(contentsOf: selected) == selector)
        if fault == "valid" || fault == "partial" {
            #expect(status == 0, "\(String(decoding: err, as: UTF8.self))")
            let seen = try SNESLibraryCleanupObservation(raw, scope: scope, challenge: nonce, contextSHA256: live.contextSHA256)
            #expect(seen.files.compactMap { $0 }.count == scope.files.count - (fault == "partial" ? 1 : 0))
            for file in scope.files.dropFirst(fault == "partial" ? 1 : 0) { #expect(try Data(contentsOf: host(file.path)) == plan.backup.read(path: file.path)) }
        } else {
            #expect(status != 0)
            #expect(throws: (any Error).self) { try SNESLibraryCleanupObservation(raw, scope: scope, challenge: nonce, contextSHA256: live.contextSHA256) }
        }
    }
}

enum SNESLibraryCleanupTestRunner {
    static func run(_ script: String, input: URL) async throws -> (Int32, Data, Data) {
        try await Task.detached {
            let process = Process(), output = Pipe(), errors = Pipe(), handle = try FileHandle(forReadingFrom: input); defer { try? handle.close() }
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
            process.standardInput = handle; process.standardOutput = output; process.standardError = errors
            try process.run(); let raw = output.fileHandleForReading.readDataToEndOfFile(), err = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, raw, err)
        }.value
    }
}

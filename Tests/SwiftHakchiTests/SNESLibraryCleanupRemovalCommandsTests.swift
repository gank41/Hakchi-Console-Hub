import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCleanupRemovalCommandsTests {
    @Test(arguments: ["valid", "partial", "link-after-preview", "hardlink-after-preview", "extra-after-preview", "changed-after-preview", "game-after-preview", "parent-link-after-preview", "replaced-same-bytes", "changed-selector", "foreign-menu", "protected-manifest"])
    func removeRechecksTheWholePreviewAndPreservesCurrentGamesAndSaves(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("input"); try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let (plan, live, backup, originals) = try await SNESLibraryCleanupPlanTests().fixture(inputs, changedROM: true)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: live, backup: backup, originals: originals)
        let nonce = UUID(), runtimeHash = String(repeating: "b", count: 64)
        let request = try SNESLibraryCleanupCommands.preview(scope: scope, contextSHA256: live.contextSHA256, runtimeSHA256: runtimeHash, challenge: nonce)
        #expect(request.script.utf8.count < 65536 && !request.script.contains(" rm ") && !request.script.contains(" mkdir "))
        if let export = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CLEANUP_ARM_EXPORT"], fault == "valid" {
            let target = URL(fileURLWithPath: export); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let synthetic = try SNESLibraryCleanupJournalTests().preview(scope, context: live.contextSHA256)
            let removal = try SNESLibraryCleanupCommands.remove(scope: scope, preview: synthetic, runtimeSHA256: runtimeHash, challenge: UUID())
            try Data(request.script.utf8).write(to: target.appendingPathComponent("preview.sh")); try request.body.write(to: target.appendingPathComponent("body.bin"))
            try Data(removal.script.utf8).write(to: target.appendingPathComponent("remove.sh"))
            try Data(SNESLibraryStartupScripts.verifier.utf8).write(to: target.appendingPathComponent("library-selector"))
            let menu = plan.material.menu
            let menuRoot = "/var/lib/swifthakchi/snes-v2/menus/" + menu.id.uuidString
            var protectedFiles: [String: String] = [:]
            for (name, bytes) in menu.files { protectedFiles[menuRoot + "/" + name] = bytes.base64EncodedString() }
            for (name, bytes) in menu.objects { protectedFiles["/var/lib/swifthakchi/snes-v2/objects/" + name] = bytes.base64EncodedString() }
            protectedFiles[menuRoot + "/menu.manifest"] = try SNESLibraryStartupScripts.manifest(for: menu).base64EncodedString()
            protectedFiles["/var/lib/swifthakchi/snes-v2/descriptions/" + menu.id.uuidString + ".json"] = menu.manifest.base64EncodedString()
            var stock: [String: String] = [:]
            for entry in originals.entries {
                for file in entry.files where file.name.hasSuffix(".desktop") { stock[entry.code + "/" + file.name] = file.data.base64EncodedString() }
            }
            var backupFiles: [String: String] = [:]
            for file in scope.files { backupFiles[SNESLibraryCleanupCommands.path(file.path)] = try plan.backup.read(path: file.path).base64EncodedString() }
            let oldID = try #require(scope.oldMenuID)
            let fixture: [String: Any] = ["runtime": runtimeHash, "oldRoot": SNESLibraryCleanupCommands.path("menus/" + oldID.uuidString),
                "protected": protectedFiles, "stock": stock, "files": backupFiles,
                "selector": try scope.selection.bytes().base64EncodedString(), "tokens": synthetic.tokensSHA256,
                "receipt": removal.receipt.base64EncodedString(), "filesCount": scope.files.count, "dirsCount": scope.directories.count]
            try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: target.appendingPathComponent("fixture.json"))
        }
        let data = root.appendingPathComponent("data"), runtime = root.appendingPathComponent("runtime")
        for dir in [data, runtime, data.appendingPathComponent("clover")] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let pin = try SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: data, runtime: runtime, fault: "valid")
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
        let oldRoot = host("menus/" + (try #require(scope.oldMenuID)).uuidString)
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
        let (status, raw, errors) = try await SNESLibraryCleanupTestRunner.run(script, input: input)
        #expect(status == 0, "\(String(decoding: errors, as: UTF8.self))")
        let seen = try SNESLibraryCleanupObservation(raw, scope: scope, challenge: nonce, contextSHA256: live.contextSHA256)
        let currentGame = selected.deletingLastPathComponent().appendingPathComponent("objects/current.sfrom")
        let save = data.appendingPathComponent("clover/save.bin")
        try FileManager.default.createDirectory(at: currentGame.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sentinel.write(to: currentGame); try sentinel.write(to: save)
        if fault == "changed-after-preview" { try sentinel.write(to: first) }
        if fault == "link-after-preview" { try FileManager.default.removeItem(at: first); try FileManager.default.createSymbolicLink(at: first, withDestinationURL: outside) }
        if fault == "hardlink-after-preview" { try FileManager.default.removeItem(at: first); try FileManager.default.linkItem(at: outside, to: first) }
        if fault == "extra-after-preview" { try sentinel.write(to: oldRoot.appendingPathComponent("unlisted")) }
        if fault == "replaced-same-bytes" {
            let original = try Data(contentsOf: first), replacement = root.appendingPathComponent("replacement")
            try original.write(to: replacement); try FileManager.default.removeItem(at: first); try FileManager.default.moveItem(at: replacement, to: first)
        }
        if fault == "changed-selector" { try sentinel.write(to: selected) }
        if fault == "game-after-preview" { _ = try SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: data, runtime: runtime, fault: "game") }
        if fault == "parent-link-after-preview" {
            let menus = oldRoot.deletingLastPathComponent(), moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: menus, to: moved); try FileManager.default.createSymbolicLink(at: menus, withDestinationURL: moved)
        }
        if fault == "foreign-menu" { try FileManager.default.createDirectory(at: namespace.appendingPathComponent("menus/" + UUID().uuidString), withIntermediateDirectories: true) }
        if fault == "protected-manifest" { try sentinel.write(to: namespace.appendingPathComponent("menus/" + newMenu.id.uuidString + "/menu.manifest")) }
        let removal = try SNESLibraryCleanupCommands.remove(scope: scope, preview: seen, runtimeSHA256: runtimeHash, challenge: UUID())
        let removeScript = removal.script.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib", with: data.path).replacingOccurrences(of: "/etc/clover", with: root.path)
            .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
            .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
            .replacingOccurrences(of: runtimeHash, with: BackupManifest.digest(try Data(contentsOf: runtime.appendingPathComponent("runtime-files.sha256"))))
            .replacingOccurrences(of: BackupManifest.digest(request.body), with: BackupManifest.digest(bytes))
            .replacingOccurrences(of: "head -c " + String(request.body.count), with: "head -c " + String(bytes.count))
        let (removed, receipt, err) = try await SNESLibraryCleanupTestRunner.run(removeScript, input: input)
        #expect(try Data(contentsOf: outside) == sentinel && Data(contentsOf: currentGame) == sentinel && Data(contentsOf: save) == sentinel)
        if fault == "valid" || fault == "partial" {
            #expect(removed == 0, "\(String(decoding: err, as: UTF8.self))")
            _ = try SNESLibraryCleanupReceipt(receipt, request: removal, scope: scope)
            for file in scope.files { #expect(!FileManager.default.fileExists(atPath: host(file.path).path)) }
            for dir in scope.directories { #expect(!FileManager.default.fileExists(atPath: host(dir).path)) }
            #expect(try Data(contentsOf: selected) == selector)
        } else {
            #expect(removed != 0)
            #expect(throws: (any Error).self) { try SNESLibraryCleanupReceipt(receipt, request: removal, scope: scope) }
            // A changed preview refuses before removing any of the other known targets.
            for file in scope.files.dropFirst() { #expect(FileManager.default.fileExists(atPath: host(file.path).path)) }
        }
    }
}

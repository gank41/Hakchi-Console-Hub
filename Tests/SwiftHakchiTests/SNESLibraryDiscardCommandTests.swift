import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryDiscardCommandTests {
    @MainActor func plan(_ root: URL, working: String) async throws -> SNESLibrarySyncPlan {
        if working == "library" { return try await SNESLibraryCleanupPlanTests().fixture(root, changedROM: true).0 }
        let (material, initial, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root)
        let backup: SNESLibraryBackup
        if working == "legacy" {
            let legacy = try SNESOneGameMenu.prepare(originals: originals, code: "CLV-U-ABCDE", metadata: oneGameMetadata,
                rom: oneGameSyntheticROM(), artwork: oneGameSyntheticArt())
            backup = try await SNESLibraryRestoreTests().backup(root, originals: originals, legacy: legacy)
        } else { backup = initial }
        return try .prepare(material: material, backup: backup, before: backup.inventory, capacity: backup.inventory.capacity,
            installation: reference, originals: originals)
    }
    @Test(arguments: ["builtin", "legacy", "library", "empty-upload", "selector-upload", "partial-selector-upload", "foreign-file", "changed-upload", "changed-selector"])
    func fixedDiscardRemovesOnlyTheUnshownCopyAndNeverOverwritesTheWorkingMenu(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let working = ["legacy", "library"].contains(fault) ? fault : "builtin"
        let plan = try await plan(root.appendingPathComponent("input"), working: working)
        let current = try await SNESLibraryDiscardPlanTests().partial(plan)
        let pendingObject = try #require(plan.material.menu.objects.sorted { $0.key < $1.key }.first { plan.before.capacity.objects[$0.key] == nil })
        let payload = pendingObject.value
        let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(plan.material.menu.id.uuidString)\n\(plan.wireSHA256)\n".utf8)
        let uploadBytes = fault == "selector-upload" ? selector : fault == "partial-selector-upload" ? Data(selector.prefix(31)) : fault == "empty-upload" ? Data() : Data(payload.prefix(17))
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: current,
            upload: .init(byteCount: uploadBytes.count, sha256: BackupManifest.digest(uploadBytes)))
        let data = root.appendingPathComponent("data"), runtime = root.appendingPathComponent("runtime")
        for path in [data, runtime, data.appendingPathComponent("clover")] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let namespace = data.appendingPathComponent("swifthakchi/snes-v2"), stage = namespace.appendingPathComponent("menus/" + plan.material.menu.id.uuidString)
        func file(_ logical: String) -> URL {
            URL(fileURLWithPath: SNESLibraryCleanupCommands.path(logical).replacingOccurrences(of: "/var/lib", with: data.path))
        }
        func write(_ bytes: Data, to target: URL) throws {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        for saved in plan.before.files { try write(plan.backup.read(path: saved.path), to: file(saved.path)) }
        for name in ["objects", "menus", "descriptions"] { try FileManager.default.createDirectory(at: namespace.appendingPathComponent(name), withIntermediateDirectories: true) }
        for name in scope.retiredObjects { try write(try #require(plan.material.menu.objects[name]), to: namespace.appendingPathComponent("objects/" + name)) }
        let desktop = try #require(plan.material.menu.files.sorted { $0.key < $1.key }.first)
        try write(desktop.value, to: stage.appendingPathComponent(desktop.key))
        try write(uploadBytes, to: stage.appendingPathComponent(".upload"))
        if fault == "foreign-file" { try write(Data("keep foreign".utf8), to: stage.appendingPathComponent("foreign")) }
        let pin = try await SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: data, runtime: runtime, fault: "valid")
        let runtimeHash = String(repeating: "b", count: 64), nonce = UUID()
        let request = try SNESLibraryCleanupCommands.preview(scope: scope, contextSHA256: current.contextSHA256, runtimeSHA256: runtimeHash, challenge: nonce)
        func run(_ script: String, body: Data) throws -> (Int32, Data, Data) {
            func hex(_ value: String) -> String { Data(value.utf8).map { String(format: "%02x", $0) }.joined() }
            var relocated = String(decoding: body, as: UTF8.self)
            for logical in scope.fileTargets.map(\.path) + scope.directories {
                relocated = relocated.replacingOccurrences(of: hex(SNESLibraryCleanupCommands.path(logical)), with: hex(file(logical).path))
            }
            let relocatedBody = Data(relocated.utf8)
            let changed = script.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
                .replacingOccurrences(of: "/var/lib", with: data.path).replacingOccurrences(of: "/etc/clover", with: root.path)
                .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
                .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
                .replacingOccurrences(of: runtimeHash, with: BackupManifest.digest(try Data(contentsOf: runtime.appendingPathComponent("runtime-files.sha256"))))
                .replacingOccurrences(of: BackupManifest.digest(body), with: BackupManifest.digest(relocatedBody))
                .replacingOccurrences(of: "head -c " + String(body.count), with: "head -c " + String(relocatedBody.count))
            let scriptFile = root.appendingPathComponent(UUID().uuidString + ".sh"), inputFile = root.appendingPathComponent(UUID().uuidString + ".bin")
            try Data(changed.utf8).write(to: scriptFile); try relocatedBody.write(to: inputFile)
            let process = Process(), output = Pipe(), errors = Pipe(), input = try FileHandle(forReadingFrom: inputFile)
            defer { try? input.close() }
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [scriptFile.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            let started = Date(); try process.run()
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog); defer { watchdog.cancel() }
            let bytes = output.fileHandleForReading.readDataToEndOfFile(), stderr = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            #expect(Date().timeIntervalSince(started) < 29, "\(String(decoding: stderr, as: UTF8.self))")
            return (process.terminationStatus, bytes, stderr)
        }
        let seen = try run(request.script, body: request.body)
        if fault == "foreign-file" { #expect(seen.0 != 0) }
        else {
            #expect(seen.0 == 0, "\(String(decoding: seen.2, as: UTF8.self))")
            let preview = try SNESLibraryCleanupObservation(seen.1, scope: scope, challenge: nonce, contextSHA256: current.contextSHA256)
            if fault == "changed-upload" { try Data("changed".utf8).write(to: stage.appendingPathComponent(".upload")) }
            if fault == "changed-selector" { try Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n".utf8).write(to: namespace.appendingPathComponent("active-menu")) }
            let removal = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview, runtimeSHA256: runtimeHash, challenge: UUID())
            let removed = try run(removal.script, body: removal.body)
            if ["changed-upload", "changed-selector"].contains(fault) { #expect(removed.0 != 0); #expect(FileManager.default.fileExists(atPath: stage.path)) }
            else {
                #expect(removed.0 == 0, "\(String(decoding: removed.2, as: UTF8.self))")
                _ = try SNESLibraryCleanupReceipt(removed.1, request: removal, scope: scope)
                #expect(!FileManager.default.fileExists(atPath: stage.path))
                #expect(FileManager.default.fileExists(atPath: namespace.path) == !scope.retireNamespace)
            }
        }
        for saved in plan.before.files { #expect(try Data(contentsOf: file(saved.path)) == plan.backup.read(path: saved.path)) }
    }
}

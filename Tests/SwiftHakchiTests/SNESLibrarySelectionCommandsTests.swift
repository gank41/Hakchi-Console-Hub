import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibrarySelectionCommandsTests {
    func inactive(menu: SNESLibraryMenu) throws -> SNESLibraryInventory {
        let source = SNESLibraryInventoryTests(), nonce = UUID()
        var rows = String(decoding: try source.frame(challenge: nonce, menu: menu), as: UTF8.self).components(separatedBy: "\n")
        rows = rows.filter { !$0.hasPrefix("FILE ") || $0.hasPrefix("FILE " + source.hex("clover/settings.json") + " ") }
        rows = rows.map { $0.hasPrefix("SELECTOR ") ? "SELECTOR builtin - - " + BackupManifest.digest(Data()) : $0 }
        return try source.parse(Data(rows.joined(separator: "\n").utf8), challenge: nonce)
    }
    @Test(arguments: ["valid", "game", "changed-selector", "pending", "damaged-wire", "linked-parent"])
    func publicationChangesOnlyTheSavedChoiceAndRequiresANormalRestart(_ fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root), menu = try fixture.menu(review, originals)
        let before = try inactive(menu: menu), challenge = UUID(), hash = String(repeating: "b", count: 64)
        let request = try SNESLibrarySelectionCommands.prepare(menu: menu, before: before, runtimeSHA256: hash, challenge: challenge)
        #expect(!request.script.contains("kill ") && !request.script.contains("reboot") && !request.script.contains("rm -r"))
        if let export = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SELECTION_ARM_EXPORT"], fault == "valid" {
            let target = URL(fileURLWithPath: export); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let source = SNESLibraryInventoryTests(), nonce = UUID(), initial = try source.parse(source.frame(challenge: nonce), challenge: nonce)
            let copying = try SNESLibraryCopyCommands.prepare(menu: menu, before: initial, runtimeSHA256: hash, challenge: UUID())
            try Data(copying.script.utf8).write(to: target.appendingPathComponent("copy.sh")); try copying.body.write(to: target.appendingPathComponent("body.bin"))
            try Data(request.script.utf8).write(to: target.appendingPathComponent("selection.sh"))
            try Data(SNESLibraryStartupScripts.verifier.utf8).write(to: target.appendingPathComponent("library-selector"))
            try JSONSerialization.data(withJSONObject: ["id": menu.id.uuidString, "context": before.contextSHA256, "hwid": before.hwid,
                "runtime": hash, "objectNames": menu.objects.keys.sorted(), "selectionExpected": request.receipt.base64EncodedString(),
                "selector": request.selector.base64EncodedString(), "stock": Dictionary(uniqueKeysWithValues: originals.entries.flatMap { entry in
                    entry.files.filter { $0.name.hasSuffix(".desktop") }.map { (entry.code + "/" + $0.name, $0.data.base64EncodedString()) }
                })], options: [.sortedKeys]).write(to: target.appendingPathComponent("fixture.json"))
        }
        let data = root.appendingPathComponent("data"), runtime = root.appendingPathComponent("runtime")
        for dir in [data, runtime, data.appendingPathComponent("clover")] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let pin = try SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: data, runtime: runtime, fault: fault)
        let namespace = data.appendingPathComponent("swifthakchi/snes-v2"), stage = namespace.appendingPathComponent("menus/" + menu.id.uuidString)
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("pages/000"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: namespace.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: namespace.appendingPathComponent("descriptions"), withIntermediateDirectories: true)
        let wire = try SNESLibraryStartupScripts.manifest(for: menu)
        try (fault == "damaged-wire" ? wire + Data([1]) : wire).write(to: stage.appendingPathComponent("menu.manifest"))
        try menu.manifest.write(to: namespace.appendingPathComponent("descriptions/" + menu.id.uuidString + ".json"))
        let sentinel = Data("do not touch".utf8)
        try sentinel.write(to: data.appendingPathComponent("clover/settings.json"))
        if fault == "changed-selector" { try sentinel.write(to: namespace.appendingPathComponent("active-menu")) }
        if fault == "pending" { try sentinel.write(to: stage.appendingPathComponent(".upload")) }
        if fault == "linked-parent" {
            let menus = namespace.appendingPathComponent("menus"), moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: menus, to: moved); try FileManager.default.createSymbolicLink(at: menus, withDestinationURL: moved)
        }
        let script = request.script.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib", with: data.path).replacingOccurrences(of: "/etc/clover", with: root.path)
            .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
            .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
            .replacingOccurrences(of: hash, with: BackupManifest.digest(try Data(contentsOf: runtime.appendingPathComponent("runtime-files.sha256"))))
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
        process.standardOutput = output; process.standardError = errors
        try process.run(); let raw = output.fileHandleForReading.readDataToEndOfFile(), err = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(try Data(contentsOf: data.appendingPathComponent("clover/settings.json")) == sentinel)
        if fault == "valid" {
            #expect(process.terminationStatus == 0, "\(String(decoding: err, as: UTF8.self))")
            #expect(try Data(contentsOf: namespace.appendingPathComponent("active-menu")) == request.selector)
            #expect(try SNESLibrarySelectionReceipt(raw, request: request).selectorSHA256 == BackupManifest.digest(request.selector))
            #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent(".upload").path))
        } else {
            #expect(process.terminationStatus != 0)
            #expect(throws: (any Error).self) { try SNESLibrarySelectionReceipt(raw, request: request) }
            if fault == "changed-selector" { #expect(try Data(contentsOf: namespace.appendingPathComponent("active-menu")) == sentinel) }
            else { #expect(!FileManager.default.fileExists(atPath: namespace.appendingPathComponent("active-menu").path)) }
            if fault == "pending" { #expect(try Data(contentsOf: stage.appendingPathComponent(".upload")) == sentinel) }
        }
    }
}

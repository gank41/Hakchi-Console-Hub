import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryDiscardARMExportTests {
    @Test func exportsSyntheticCommandsForPinnedARMTools() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_DISCARD_ARM_EXPORT"] else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root), current = try SNESLibraryDiscardPlanTests().partial(plan)
        let payload = try #require(plan.material.menu.objects.sorted { $0.key < $1.key }.first { plan.before.capacity.objects[$0.key] == nil }).value
        let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(plan.material.menu.id.uuidString)\n\(plan.wireSHA256)\n".utf8)
        let uploadBytes = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_DISCARD_SELECTOR_EXPORT"] == "1" ? selector : Data(payload.prefix(17))
        let runtime = String(repeating: "b", count: 64)
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: current, upload: .init(byteCount: uploadBytes.count, sha256: BackupManifest.digest(uploadBytes)))
        let preview = try SNESLibraryDiscardJournalTests().preview(scope, context: current.contextSHA256)
        let inspect = try SNESLibraryCleanupCommands.preview(scope: scope, contextSHA256: current.contextSHA256, runtimeSHA256: runtime, challenge: preview.challenge)
        let remove = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview, runtimeSHA256: runtime, challenge: UUID())
        let upload = try SNESLibraryDiscardUploadCommands.prepare(plan: plan, contextSHA256: current.contextSHA256, runtimeSHA256: runtime, challenge: UUID())
        let target = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for (name, bytes) in [("preview.sh", Data(inspect.script.utf8)), ("remove.sh", Data(remove.script.utf8)), ("upload.sh", Data(upload.script.utf8)), ("body.bin", inspect.body)] {
            try bytes.write(to: target.appendingPathComponent(name))
        }
        var files = Dictionary(uniqueKeysWithValues: plan.material.menu.files.map { ("menus/" + plan.material.menu.id.uuidString + "/" + $0.key, $0.value) })
        files["menus/" + plan.material.menu.id.uuidString + "/menu.manifest"] = try SNESLibraryStartupScripts.manifest(for: plan.material.menu)
        files["menus/" + plan.material.menu.id.uuidString + "/.upload"] = uploadBytes
        files["descriptions/" + plan.material.menu.id.uuidString + ".json"] = plan.material.menu.manifest
        for key in scope.retiredObjects { files["objects/" + key] = plan.material.menu.objects[key] }
        let kept = try Dictionary(uniqueKeysWithValues: plan.before.files.map { ($0.path, try plan.backup.read(path: $0.path).base64EncodedString()) })
        try JSONSerialization.data(withJSONObject: ["runtime": runtime, "id": plan.material.menu.id.uuidString, "tokens": preview.tokensSHA256,
            "files": files.mapValues { $0.base64EncodedString() }, "kept": kept, "uploadHash": BackupManifest.digest(uploadBytes), "uploadBytes": uploadBytes.count], options: [.sortedKeys]).write(to: target.appendingPathComponent("fixture.json"))
    }
}

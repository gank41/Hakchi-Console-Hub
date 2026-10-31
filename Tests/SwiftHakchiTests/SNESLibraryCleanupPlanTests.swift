import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCleanupPlanTests {
    func fixture(_ root: URL, changedROM: Bool) async throws -> (SNESLibrarySyncPlan, SNESLibraryInventory, SNESLibraryBackup, SNESOriginalGamesFrame) {
        let maker = SNESLibraryMaterialTests(), oldRoot = root.appendingPathComponent("old"), newRoot = root.appendingPathComponent("new")
        let (oldReview, originals) = try maker.fixture(oldRoot), old = try maker.menu(oldReview, originals)
        let before = try await SNESLibraryRestoreTests().backup(root, originals: originals, menu: old)
        let (initial, _) = try maker.fixture(newRoot, count: 1)
        if changedROM {
            let game = try #require(initial.rows.first).game, path = URL(fileURLWithPath: game.romPath).appendingPathComponent(game.code + ".sfc")
            var bytes = try Data(contentsOf: path); bytes[512] = 1
            let h = 0x7fc0; bytes[h+0x1c] = 255; bytes[h+0x1d] = 255; bytes[h+0x1e] = 0; bytes[h+0x1f] = 0
            let sum = bytes.reduce(0) { $0 + Int($1) } & 65535
            bytes[h+0x1c] = UInt8((sum ^ 65535) & 255); bytes[h+0x1d] = UInt8((sum ^ 65535) >> 8)
            bytes[h+0x1e] = UInt8(sum & 255); bytes[h+0x1f] = UInt8(sum >> 8); try bytes.write(to: path)
        }
        let review = try SNESLibraryCompatibility.review(games: initial.rows.map(\.game), originals: originals), menu = try maker.menu(review, originals)
        let material = try SNESLibraryMaterial.freeze(menu: menu, in: newRoot)
        let reference = SNESLibraryInstallationReference(hwid: before.inventory.hwid, operationID: UUID(), reviewSHA256: String(repeating: "c", count: 64),
            catalog: root.appendingPathComponent("SNES-Original-Games-" + UUID().uuidString), catalogSHA256: String(repeating: "d", count: 64))
        let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: before, before: before.inventory, capacity: before.inventory.capacity,
            installation: reference, originals: originals)
        let current = try await SNESLibraryRestoreTests().backup(root, originals: originals, menu: menu)
        var rows = String(decoding: current.inventory.rawFrame, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty && $0 != "END" }
        for oldMenu in before.inventory.menus {
            rows.append("MENU library \(oldMenu.id.uuidString) \(oldMenu.treeSHA256) \(oldMenu.manifestBytes) \(oldMenu.descriptionBytes) \(oldMenu.descriptionSHA256!)")
            for name in oldMenu.references { rows.append("REF \(oldMenu.id.uuidString) \(name)") }
        }
        for record in before.inventory.capacity.objects.values where current.inventory.capacity.objects[record.name] == nil { rows.append("OBJECT \(record.name) \(record.byteCount) \(record.sha256)") }
        rows.append("END")
        let live = try SNESLibraryInventory(raw: Data((rows.joined(separator: "\n") + "\n").utf8), challenge: current.inventory.challenge,
            contextSHA256: current.inventory.contextSHA256, hwid: current.inventory.hwid, catalogSHA256: current.inventory.catalogSHA256)
        return (plan, live, current, originals)
    }
    @Test(arguments: [false, true]) func scopeRetiresOnlyTheOldMenuAndUnreferencedOldContent(_ changed: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, live, current, originals) = try await fixture(root, changedROM: changed)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: live, backup: current, originals: originals)
        let old = try #require(plan.before.selection.id).uuidString
        #expect(scope.files.contains { $0.path == "menus/" + old + "/menu.manifest" })
        #expect(scope.files.contains { $0.path == "descriptions/" + old + ".json" })
        #expect(!scope.files.contains { $0.path == "active-menu" || $0.path.hasPrefix("clover/") || $0.path.contains(plan.material.menu.id.uuidString) })
        #expect(scope.retiredObjects.count == (changed ? 1 : 0))
        #expect(scope.retiredObjects.isDisjoint(with: scope.protectedObjects))
        #expect(scope.directories.contains("menus/" + old))
        #expect(!scope.directories.contains("objects") && !scope.directories.contains("clover"))
        let loaded = try SNESLibraryCleanupPlan.load(data: scope.data, expectedReviewSHA256: scope.reviewSHA256, plan: plan, originals: originals)
        #expect(loaded.reviewSHA256 == scope.reviewSHA256 && loaded.files == scope.files)
        try loaded.validateSources()
    }
    @Test func mismatchedCurrentBackupOrEditedScopeCannotAuthorizeRemoval() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, live, current, originals) = try await fixture(root, changedROM: true)
        #expect(throws: (any Error).self) { try SNESLibraryCleanupPlan.prepare(plan: plan, current: live, backup: plan.backup, originals: originals) }
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: live, backup: current, originals: originals)
        var fields = try #require(JSONSerialization.jsonObject(with: scope.data) as? [String: Any]); fields["skipBackup"] = true
        let changed = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(throws: (any Error).self) { try SNESLibraryCleanupPlan.load(data: changed, expectedReviewSHA256: BackupManifest.digest(changed), plan: plan, originals: originals) }
    }
}

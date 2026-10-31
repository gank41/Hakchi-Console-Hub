import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibrarySyncPlanTests {
    func fixture(_ root: URL) async throws -> (SNESLibraryMaterial, SNESLibraryBackup, SNESOriginalGamesFrame, SNESLibraryInstallationReference) {
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root), menu = try fixture.menu(review, originals)
        let material = try SNESLibraryMaterial.freeze(menu: menu, in: root), backup = try await SNESLibraryRestoreTests().backup(root, originals: originals)
        let reference = SNESLibraryInstallationReference(hwid: backup.inventory.hwid, operationID: UUID(), reviewSHA256: String(repeating: "c", count: 64),
            catalog: root.appendingPathComponent("SNES-Original-Games-" + UUID().uuidString), catalogSHA256: String(repeating: "d", count: 64))
        return (material, backup, originals, reference)
    }
    @Test func inertReviewKeepsTheExactRecoveryAndCopyScope() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (material, backup, originals, reference) = try await fixture(root)
        let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: backup.inventory,
            capacity: backup.inventory.capacity, installation: reference, originals: originals)
        try plan.requireSources()
        #expect(plan.material.menu.id == material.menu.id)
        #expect(plan.before.snapshotSHA256 == backup.inventory.snapshotSHA256)
        #expect(plan.wireSHA256 == BackupManifest.digest(try SNESLibraryStartupScripts.manifest(for: material.menu)))
        #expect(plan.projection.canFit && plan.reviewSHA256 == BackupManifest.digest(plan.data))
        let json = try #require(JSONSerialization.jsonObject(with: plan.data) as? [String: Any])
        #expect(json["scope"] as? String == "native-snes-library-review")
        #expect(json["requiredUSBVersion"] as? Int == 0x6a07)
        let raw = try SNESLibrarySyncPlan.load(data: plan.data, expectedReviewSHA256: plan.reviewSHA256, originals: originals)
        #expect(raw.reviewSHA256 == plan.reviewSHA256)
        let source = try #require(material.menu.sources.first { $0.name.hasSuffix(".desktop") })
        try Data("changed".utf8).write(to: URL(fileURLWithPath: source.directory).appendingPathComponent(source.name))
        #expect(throws: (any Error).self) { try plan.requireSources() }
    }
    @Test(arguments: ["different-save", "different-console", "missing-space", "changed-backup", "unknown-field"])
    func invalidRecoveryAndCapacityCannotBecomeAnActionableReview(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (material, backup, originals, originalReference) = try await fixture(root)
        var before = backup.inventory, reference = originalReference
        if fault == "different-save" {
            let raw = Data(String(decoding: before.rawFrame, as: UTF8.self).replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8))).utf8)
            before = try SNESLibraryInventory(raw: raw, challenge: before.challenge, contextSHA256: before.contextSHA256, hwid: before.hwid, catalogSHA256: before.catalogSHA256)
        }
        if fault == "different-console" { reference = .init(hwid: String(repeating: "2", count: 32), operationID: reference.operationID,
            reviewSHA256: reference.reviewSHA256, catalog: reference.catalog, catalogSHA256: reference.catalogSHA256) }
        if fault == "changed-backup" { try Data("[]".utf8).write(to: backup.directory.appendingPathComponent("data-0/file-0000.bin")) }
        if fault == "unknown-field" {
            let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: before, capacity: before.capacity, installation: reference, originals: originals)
            var json = try #require(JSONSerialization.jsonObject(with: plan.data) as? [String: Any]); json["copyAnyway"] = true
            let raw = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
            #expect(throws: (any Error).self) { try SNESLibrarySyncPlan.load(data: raw, expectedReviewSHA256: BackupManifest.digest(raw), originals: originals) }
        } else {
            #expect(throws: (any Error).self) { try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: before,
                capacity: fault == "missing-space" ? nil : before.capacity, installation: reference, originals: originals) }
        }
    }
}

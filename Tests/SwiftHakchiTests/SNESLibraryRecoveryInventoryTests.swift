import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct SNESLibraryRecoveryInventoryTests {
    func frame(_ raw: Data, excluded: UUID) -> Data {
        let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\n")
        var changed = lines
        changed[0] = changed[0].replacingOccurrences(of: "_INVENTORY_V1", with: "_RECOVERY_INVENTORY_V1")
        changed.insert("EXCLUDED " + excluded.uuidString, at: 7)
        return Data(changed.joined(separator: "\n").utf8)
    }
    @Test func partiallyCreatedBaseFoldersAreReadOnlyAndRemainTaggedInMacSnapshots() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), excluded = UUID()
        let raw = frame(try fixture.frame(challenge: nonce), excluded: excluded)
        let partial = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "NAMESPACE absent absent", with: "NAMESPACE partial absent").utf8)
        #expect(throws: (any Error).self) { try fixture.parse(partial, challenge: nonce) }
        let seen = try SNESLibraryInventory(raw: partial, challenge: nonce, contextSHA256: fixture.context, hwid: fixture.hwid,
            catalogSHA256: fixture.catalog, excludingIncompleteMenu: excluded)
        #expect(seen.incompleteNamespace && !seen.capacity.namespaceReady)
        let saved = try await SNESLibraryBackup.capture(inventory: seen, root: root, read: { _, _ in Data("{}".utf8) }, refresh: { seen })
        #expect(try SNESLibraryBackup.open(directory: saved.directory).inventory.incompleteNamespace)
        #expect(try saved.read(path: "clover/settings.json") == Data("{}".utf8))
        #expect(throws: (any Error).self) { try SNESLibraryInventoryCommands.script(contextSHA256: fixture.context, hwid: fixture.hwid,
            catalogSHA256: fixture.catalog, runtimeSHA256: String(repeating: "b", count: 64), librarySupport: true, challenge: nonce,
            allowIncompleteNamespace: true) }
    }
    @Test func recoveryViewIsExplicitAndCannotHideTheSelectedMenu() throws {
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), excluded = UUID()
        let normal = try fixture.parse(fixture.frame(challenge: nonce), challenge: nonce)
        let raw = frame(normal.rawFrame, excluded: excluded)
        #expect(throws: (any Error).self) { try fixture.parse(raw, challenge: nonce) }
        let recovery = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: fixture.context, hwid: fixture.hwid,
            catalogSHA256: fixture.catalog, excludingIncompleteMenu: excluded)
        #expect(recovery.excludedMenuID == excluded && normal.excludedMenuID == nil)
        #expect(recovery.snapshotSHA256 == normal.snapshotSHA256 && recovery.stateSHA256 != normal.stateSHA256)
        #expect(throws: (any Error).self) { try SNESLibraryInventory(raw: normal.rawFrame, challenge: nonce, contextSHA256: fixture.context,
            hwid: fixture.hwid, catalogSHA256: fixture.catalog, excludingIncompleteMenu: excluded) }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let material = SNESLibraryMaterialTests(), (review, originals) = try material.fixture(root), menu = try material.menu(review, originals)
        let selected = frame(try fixture.frame(challenge: nonce, menu: menu), excluded: menu.id)
        #expect(throws: (any Error).self) { try SNESLibraryInventory(raw: selected, challenge: nonce, contextSHA256: fixture.context,
            hwid: fixture.hwid, catalogSHA256: fixture.catalog, excludingIncompleteMenu: menu.id) }
    }
    @Test func aRecoverySnapshotStillContainsAllActiveData() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), excluded = UUID(), raw = frame(try fixture.frame(challenge: nonce), excluded: excluded)
        let inventory = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: fixture.context, hwid: fixture.hwid,
            catalogSHA256: fixture.catalog, excludingIncompleteMenu: excluded)
        let saved = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        #expect(try SNESLibraryBackup.open(directory: saved.directory).inventory.excludedMenuID == excluded)
        #expect(try saved.read(path: "clover/settings.json") == Data("{}".utf8))
    }
    @Test func readOnlyScopeDoesNotDependOnDeletedEditableROMsAndExpiresWithTheJournal() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (material, backup, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root)
        let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: backup.inventory,
            capacity: backup.inventory.capacity, installation: reference, originals: originals)
        let journals = root.appendingPathComponent("journals"); try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: journals)
        #expect(throws: (any Error).self) { try SNESLibraryJournal.reconciliation(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256) }
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        _ = try await journal.beginCopy(); try await journal.close()
        for directory in Set(material.menu.sources.map(\.directory)) { try FileManager.default.removeItem(at: URL(fileURLWithPath: directory)) }
        let scope = try SNESLibraryJournal.reconciliation(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        try scope.require(); #expect(scope.id == material.menu.id && scope.hwid == backup.inventory.hwid)
        try Data("changed".utf8).write(to: prepared.operation.appendingPathComponent("0001.json"))
        #expect(throws: (any Error).self) { try scope.require() }
    }
}

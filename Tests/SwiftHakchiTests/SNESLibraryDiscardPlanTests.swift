import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryDiscardPlanTests {
    func partial(_ plan: SNESLibrarySyncPlan, extraObject: String? = nil, changedSave: Bool = false) throws -> SNESLibraryInventory {
        let whole = try SNESLibraryCopyTransactionTests().after(plan), id = plan.material.menu.id.uuidString
        var rows = String(decoding: whole.rawFrame, as: UTF8.self).components(separatedBy: "\n").filter { row in
            let fields = row.split(separator: " ").map(String.init)
            return !(fields.first == "MENU" && fields.count > 2 && fields[2] == id) && !(fields.first == "REF" && fields.count > 1 && fields[1] == id)
        }
        rows[0] = rows[0].replacingOccurrences(of: "_INVENTORY_V1", with: "_RECOVERY_INVENTORY_V1")
        rows.insert("EXCLUDED " + id, at: 7)
        if let extraObject { rows.insert(extraObject, at: rows.count - 2) }
        var text = rows.joined(separator: "\n")
        if changedSave { text = text.replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8))) }
        return try .init(raw: Data(text.utf8), challenge: whole.challenge, contextSHA256: whole.contextSHA256, hwid: whole.hwid,
            catalogSHA256: whole.catalogSHA256, excludingIncompleteMenu: plan.material.menu.id)
    }
    @Test func discardTargetsOnlyTheNewCopyAndVerifiesItsPartialUploadAgainstFrozenPayloads() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root), current = try partial(plan)
        let payload = try #require(plan.material.menu.objects.values.first), prefix = Data(payload.prefix(17))
        let upload = SNESLibraryDiscardPlan.Upload(byteCount: prefix.count, sha256: BackupManifest.digest(prefix))
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: current, upload: upload)
        #expect(scope.retireNamespace && scope.selection == plan.before.selection)
        #expect(scope.fileTargets.contains { $0.path == "menus/" + plan.material.menu.id.uuidString + "/.upload" && $0.byteCount == 17 && $0.sha256 == upload.sha256 })
        #expect(scope.fileTargets.allSatisfy { !$0.path.hasPrefix("clover/") && !$0.path.hasPrefix("legacy/") && $0.path != "active-menu" })
        #expect(scope.retiredObjects == Set(plan.material.menu.objects.keys))
        #expect(try SNESLibraryDiscardPlan.load(data: scope.data, expectedReviewSHA256: scope.reviewSHA256, plan: plan).data == scope.data)
        #expect(throws: (any Error).self) { try SNESLibraryDiscardPlan.prepare(plan: plan, current: current,
            upload: .init(byteCount: 8, sha256: BackupManifest.digest(Data("foreign!".utf8)))) }
    }
    @Test func existingObjectsAndMenusRemainProtectedEvenWhenTheNewCopySharesTheirFiles() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, _, _, _) = try await SNESLibraryCleanupPlanTests().fixture(root, changedROM: true)
        let current = try partial(plan), scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: current, upload: nil)
        #expect(!scope.retireNamespace)
        #expect(scope.protectedObjects == Set(plan.before.capacity.objects.keys))
        #expect(scope.retiredObjects.isDisjoint(with: scope.protectedObjects))
        #expect(Set(scope.protectedMenus.map(\.id)) == Set(plan.before.menus.filter { $0.kind == .library }.map(\.id)))
        #expect(scope.fileTargets.filter { $0.path.hasPrefix("objects/") }.allSatisfy { plan.before.capacity.objects[String($0.path.dropFirst(8))] == nil })
    }
    @Test func aForeignObjectCannotBeSweptUpAsPartOfDiscardingThisCopy() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root)
        let bytes = Data(repeating: 255, count: 96), hash = BackupManifest.digest(bytes)
        let foreign = try partial(plan, extraObject: "OBJECT \(hash).sfrom 96 \(hash)")
        #expect(throws: (any Error).self) { try SNESLibraryDiscardPlan.prepare(plan: plan, current: foreign, upload: nil) }
    }
    @Test func laterSaveProgressIsKeptWhileDiscardingOnlyTheUnshownCopy() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root), current = try partial(plan, changedSave: true)
        #expect(current.snapshotSHA256 != plan.before.snapshotSHA256)
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: current, upload: nil)
        try scope.requireCurrent(plan, inventory: current)
        #expect(scope.fileTargets.allSatisfy { !$0.path.hasPrefix("clover/") })
    }
}

import Foundation
import SwiftHakchiCore

/// Testable transaction boundary. The physical implementation independently enforces its native context and fixed journal root.
protocol SNESLibraryCopyDevice: Sendable {
    func copy(plan: SNESLibrarySyncPlan, permit: SNESLibraryCopyPermit) async throws -> SNESLibraryCopyResult
    func disconnect() async
}
/// Checked evidence only; it never grants menu selection or deletion authority.
struct SNESLibraryCopyResult: Sendable {
    let receipt: SNESLibraryCopyReceipt, after: SNESLibraryInventory, reviewSHA256: String, evidenceSHA256: String
    var challenge: UUID { receipt.challenge }
    init(plan: SNESLibrarySyncPlan, permit: SNESLibraryCopyPermit, request: SNESLibraryCopyCommands.Request, raw: Data, after: SNESLibraryInventory) throws {
        try permit.require(plan)
        let menu = plan.material.menu, before = plan.before
        guard request.id == menu.id, request.challenge == permit.challenge, request.contextSHA256 == before.contextSHA256,
              request.hwid == before.hwid, request.wireSHA256 == plan.wireSHA256, request.descriptionSHA256 == plan.descriptionSHA256,
              request.selectorSHA256 == before.selection.selectorSHA256 else { throw SNESLibraryInventory.failure() }
        let receipt = try SNESLibraryCopyReceipt(raw, request: request)
        guard receipt.freeBytes <= before.totalBytes, after.excludedMenuID == nil,
              after.contextSHA256 == before.contextSHA256, after.hwid == before.hwid, after.catalogSHA256 == before.catalogSHA256,
              after.totalBytes == before.totalBytes, after.snapshotSHA256 == before.snapshotSHA256,
              after.selection == before.selection, after.files == before.files, after.directories == before.directories,
              after.capacity.namespaceReady, after.capacity.descriptionStoreReady else { throw SNESLibraryInventory.failure() }
        var objects = before.capacity.objects
        for record in menu.objectRecords {
            guard objects[record.name] == nil || objects[record.name] == record else { throw SNESLibraryInventory.failure() }
            objects[record.name] = record
        }
        let missing = Set(menu.objectRecords.map(\.name)).subtracting(before.capacity.objects.keys)
        guard request.objectNames == missing, request.fileCount == missing.count + menu.description.files.count + 2,
              after.capacity.objects == objects else { throw SNESLibraryInventory.failure() }
        let wire = try SNESLibraryStartupScripts.manifest(for: menu)
        let expected = SNESLibraryInventory.Menu(kind: .library, id: menu.id, treeSHA256: plan.wireSHA256,
            manifestBytes: wire.count, descriptionBytes: menu.manifest.count, descriptionSHA256: plan.descriptionSHA256,
            references: menu.objectRecords.map(\.name).sorted())
        var menus = Dictionary(uniqueKeysWithValues: before.menus.map { ($0.id, $0) })
        guard menus[menu.id] == nil else { throw SNESLibraryInventory.failure() }; menus[menu.id] = expected
        guard menus == Dictionary(uniqueKeysWithValues: after.menus.map { ($0.id, $0) }) else { throw SNESLibraryInventory.failure() }
        self.receipt = receipt; self.after = after; reviewSHA256 = plan.reviewSHA256
        evidenceSHA256 = BackupManifest.digest(Data((plan.reviewSHA256 + ":" + BackupManifest.digest(raw) + ":" + after.stateSHA256).utf8))
    }
}
enum SNESLibraryCopyTransaction {
    static func run(plan: SNESLibrarySyncPlan, journal: SNESLibraryJournal, device: any SNESLibraryCopyDevice) async throws -> SNESLibraryCopyResult {
        var dispatched = false
        do {
            try Task.checkCancellation(); try plan.requireSources()
            let permit = try await journal.beginCopy(); dispatched = true
            try Task.checkCancellation(); try permit.require(plan)
            let result = try await device.copy(plan: plan, permit: permit)
            try Task.checkCancellation(); try permit.require(plan)
            try await journal.noteCopied(result)
            await device.disconnect(); return result
        } catch {
            if dispatched {
                // Cancellation must stop USB work, but cannot cancel its small durable recovery record.
                // Await this one bounded task; it performs no console access and never retries copying.
                try? await Task.detached { try await journal.copyUncertain() }.value
            }
            await device.disconnect(); throw error
        }
    }
}

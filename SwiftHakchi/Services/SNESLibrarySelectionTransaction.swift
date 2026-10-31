import Foundation
import SwiftHakchiCore

protocol SNESLibrarySelectionDevice: Sendable {
    func selectionAttachment(plan: SNESLibrarySyncPlan) async throws -> RecoveryProbeUSBDevice
    func saveSelection(plan: SNESLibrarySyncPlan, permit: SNESLibrarySelectionPermit) async throws -> SNESLibrarySelectionResult
    func disconnect() async
}
enum SNESLibraryInactiveCheck {
    static func require(_ plan: SNESLibrarySyncPlan, inventory: SNESLibraryInventory) throws {
        let before = plan.before, menu = plan.material.menu
        guard inventory.excludedMenuID == nil, inventory.hwid == before.hwid, inventory.catalogSHA256 == before.catalogSHA256,
              inventory.totalBytes == before.totalBytes, inventory.capacity.blockSize == before.capacity.blockSize,
              inventory.snapshotSHA256 == before.snapshotSHA256, inventory.files == before.files, inventory.directories == before.directories,
              inventory.selection == before.selection, inventory.capacity.namespaceReady, inventory.capacity.descriptionStoreReady else { throw SNESLibraryInventory.failure() }
        var objects = before.capacity.objects
        for item in menu.objectRecords {
            guard objects[item.name] == nil || objects[item.name] == item else { throw SNESLibraryInventory.failure() }; objects[item.name] = item
        }
        guard inventory.capacity.objects == objects else { throw SNESLibraryInventory.failure() }
        var menus = Dictionary(uniqueKeysWithValues: before.menus.map { ($0.id, $0) })
        guard menus[menu.id] == nil else { throw SNESLibraryInventory.failure() }
        menus[menu.id] = try expectedMenu(plan)
        guard menus == Dictionary(uniqueKeysWithValues: inventory.menus.map { ($0.id, $0) }) else { throw SNESLibraryInventory.failure() }
    }
    static func expectedMenu(_ plan: SNESLibrarySyncPlan) throws -> SNESLibraryInventory.Menu {
        let menu = plan.material.menu, wire = try SNESLibraryStartupScripts.manifest(for: menu)
        return .init(kind: .library, id: menu.id, treeSHA256: plan.wireSHA256, manifestBytes: wire.count,
            descriptionBytes: menu.manifest.count, descriptionSHA256: plan.descriptionSHA256, references: menu.objectRecords.map(\.name).sorted())
    }
}
enum SNESLibraryActiveCheck {
    /// Profile changes during later gameplay are allowed; the next Mac backup captures those current saves.
    static func require(_ plan: SNESLibrarySyncPlan, inventory: SNESLibraryInventory, preserveProfiles: Bool) throws {
        let menu = plan.material.menu, before = plan.before
        let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(menu.id.uuidString)\n\(plan.wireSHA256)\n".utf8)
        let selection = SNESLibraryInventory.Selection(kind: .library, id: menu.id, treeSHA256: plan.wireSHA256, selectorSHA256: BackupManifest.digest(selector))
        guard inventory.excludedMenuID == nil, inventory.hwid == before.hwid, inventory.catalogSHA256 == before.catalogSHA256,
              inventory.totalBytes == before.totalBytes, inventory.capacity.blockSize == before.capacity.blockSize,
              inventory.selection == selection, inventory.capacity.namespaceReady, inventory.capacity.descriptionStoreReady else { throw SNESLibraryInventory.failure() }
        var objects = before.capacity.objects
        for record in menu.objectRecords {
            guard objects[record.name] == nil || objects[record.name] == record else { throw SNESLibraryInventory.failure() }; objects[record.name] = record
        }
        var menus = Dictionary(uniqueKeysWithValues: before.menus.filter { $0.kind == .library }.map { ($0.id, $0) })
        guard menus[menu.id] == nil else { throw SNESLibraryInventory.failure() }; menus[menu.id] = try SNESLibraryInactiveCheck.expectedMenu(plan)
        guard inventory.capacity.objects == objects, menus == Dictionary(uniqueKeysWithValues: inventory.menus.map { ($0.id, $0) }) else { throw SNESLibraryInventory.failure() }
        var files = Dictionary(uniqueKeysWithValues: menu.files.map { ("menus/" + menu.id.uuidString + "/" + $0.key, $0.value) })
        for record in menu.objectRecords { guard let data = menu.objects[record.name] else { throw SNESLibraryMenu.failure() }; files["objects/" + record.name] = data }
        files["menus/" + menu.id.uuidString + "/menu.manifest"] = try SNESLibraryStartupScripts.manifest(for: menu)
        files["descriptions/" + menu.id.uuidString + ".json"] = menu.manifest; files["active-menu"] = selector
        let actual = inventory.files.filter { !$0.path.hasPrefix("clover/") }
        guard actual.count == files.count else { throw SNESLibraryInventory.failure() }
        for record in actual {
            guard let expected = files[record.path], record.byteCount == expected.count, record.sha256 == BackupManifest.digest(expected) else { throw SNESLibraryInventory.failure() }
        }
        if preserveProfiles {
            guard inventory.files.filter({ $0.path.hasPrefix("clover/") }) == before.files.filter({ $0.path.hasPrefix("clover/") }),
                  inventory.directories == before.directories else { throw SNESLibraryInventory.failure() }
        }
    }
}
struct SNESLibrarySelectionResult: Sendable {
    let receipt: SNESLibrarySelectionReceipt, after: SNESLibraryInventory
    init(plan: SNESLibrarySyncPlan, permit: SNESLibrarySelectionPermit, request: SNESLibrarySelectionCommands.Request, raw: Data, after: SNESLibraryInventory) throws {
        try permit.require(plan, attachment: permit.attachment)
        guard request.id == plan.material.menu.id, request.challenge == permit.challenge, request.contextSHA256 == after.contextSHA256,
              request.hwid == plan.before.hwid, request.wireSHA256 == plan.wireSHA256, request.previousSHA256 == plan.before.selection.selectorSHA256 else { throw SNESLibraryInventory.failure() }
        let receipt = try SNESLibrarySelectionReceipt(raw, request: request)
        try SNESLibraryActiveCheck.require(plan, inventory: after, preserveProfiles: true)
        self.receipt = receipt; self.after = after
    }
}
enum SNESLibrarySelectionTransaction {
    static func run(plan: SNESLibrarySyncPlan, journal: SNESLibraryJournal, device: any SNESLibrarySelectionDevice) async throws -> SNESLibrarySelectionResult {
        var dispatched = false
        do {
            try Task.checkCancellation(); try plan.requireSources()
            let attachment = try await device.selectionAttachment(plan: plan)
            try Task.checkCancellation(); try plan.requireSources()
            let permit = try await journal.beginShow(attachment: attachment); dispatched = true
            try Task.checkCancellation(); try permit.require(plan, attachment: attachment)
            let result = try await device.saveSelection(plan: plan, permit: permit)
            try Task.checkCancellation(); try permit.require(plan, attachment: attachment)
            try await journal.noteSelectionSaved(result.receipt)
            await device.disconnect(); return result
        } catch {
            if dispatched { try? await Task.detached { try await journal.selectionUncertain() }.value }
            await device.disconnect(); throw error
        }
    }
}

import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct SNESLibraryPreparedMaterialCleanupTests {
    @Test(arguments: ["terminal", "prepared", "uncertain", "foreign", "changed", "live-source-removed", "outside"])
    func onlyTerminalOwnedCacheIsRemovedAndBackupsRemain(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, backup, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root.appendingPathComponent("input"))
        let transactions = root.appendingPathComponent("transactions"), parent = transactions.appendingPathComponent("Prepared")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let material = fault == "outside" ? initial : try SNESLibraryMaterial.freeze(menu: initial.menu, in: parent)
        let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: backup.inventory, capacity: backup.inventory.capacity,
            installation: reference, originals: originals)
        let operation = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: operation.operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        if fault == "uncertain" { _ = try await journal.beginCopy(); try await journal.copyUncertain() }
        else if fault != "prepared" { try await journal.cancelUnstarted() }
        if fault == "foreign" { try Data("keep".utf8).write(to: material.directory.appendingPathComponent("foreign")) }
        if fault == "changed" {
            let name = try #require(try FileManager.default.contentsOfDirectory(atPath: material.directory.path).first { $0.hasPrefix("object-") })
            try Data("changed".utf8).write(to: material.directory.appendingPathComponent(name))
        }
        if fault == "live-source-removed" {
            let source = try #require(material.menu.sources.first)
            try FileManager.default.removeItem(at: URL(fileURLWithPath: source.directory).appendingPathComponent(source.name))
        }
        if ["terminal", "live-source-removed"].contains(fault) {
            #expect(try await journal.purgePreparedMaterial())
            #expect(!FileManager.default.fileExists(atPath: material.directory.path))
            #expect(try await journal.purgePreparedMaterial() == false)
            #expect(try await journal.phase() == .discarded)
        } else {
            let before = try FileManager.default.contentsOfDirectory(atPath: material.directory.path).sorted()
            await #expect(throws: (any Error).self) { try await journal.purgePreparedMaterial() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: material.directory.path).sorted() == before)
        }
        try backup.validate()
        #expect(FileManager.default.fileExists(atPath: backup.directory.path))
        try await journal.close()
    }
}

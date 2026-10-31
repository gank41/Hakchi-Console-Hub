import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryBackupHistoryTests {
    func fixture(_ root: URL) async throws -> (WorkspacePaths, SNESLibraryBackup, SNESLibrarySyncPlan, URL) {
        let (material, saved, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root.appendingPathComponent("input"))
        let workspace = WorkspacePaths(root: root.appendingPathComponent("workspace"))
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let directory = workspace.backups.appendingPathComponent(saved.directory.lastPathComponent)
        try FileManager.default.copyItem(at: saved.directory, to: directory)
        let backup = try SNESLibraryBackup.open(directory: directory)
        let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: backup.inventory, capacity: backup.inventory.capacity,
            installation: reference, originals: originals)
        let journals = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        return (workspace, backup, plan, journals)
    }
    @Test func listingIsMetadataOnlyAndDoesNotPretendMissingPayloadsAreVerified() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, backup, _, journals) = try await fixture(root)
        let before = try SNESLibraryBackupHistory.scan(roots: workspace.knownBackupRoots)
        let row = try #require(before.first)
        #expect(row.summary?.hwid == backup.inventory.hwid && row.summary?.manifestSHA256 == backup.manifestSHA256)
        #expect(row.summary?.gameCount == 21)
        let payload = try #require(try FileManager.default.contentsOfDirectory(at: backup.directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("data-") })
        try FileManager.default.removeItem(at: payload)
        #expect(try SNESLibraryBackupHistory.scan(roots: workspace.knownBackupRoots).first?.summary != nil)
        #expect(throws: (any Error).self) { try SNESLibraryBackupHistory.preview(directory: backup.directory, workspace: workspace, journals: journals) }
    }
    @Test(arguments: ["trash", "changed", "pending", "unknown-file", "linked", "outside"])
    func removingOneMacBackupProtectsPendingRecoveryAndNeverTouchesConsole(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, backup, plan, journals) = try await fixture(root)
        if fault == "pending" { _ = try SNESLibraryJournal.prepare(plan: plan, root: journals) }
        if fault == "unknown-file" { try Data("keep".utf8).write(to: backup.directory.appendingPathComponent("foreign")) }
        var directory = backup.directory
        if fault == "linked" {
            let alternate = workspace.backups.appendingPathComponent("link"); try FileManager.default.moveItem(at: directory, to: alternate)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: alternate)
        }
        if fault == "outside" { directory = root.appendingPathComponent("input").appendingPathComponent(backup.directory.lastPathComponent) }
        if ["pending", "unknown-file", "linked", "outside"].contains(fault) {
            #expect(throws: (any Error).self) { try SNESLibraryBackupHistory.preview(directory: directory, workspace: workspace, journals: journals) }
            return
        }
        let preview = try SNESLibraryBackupHistory.preview(directory: directory, workspace: workspace, journals: journals)
        let trash = root.appendingPathComponent("Trash"); try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let destination = trash.appendingPathComponent(directory.lastPathComponent)
        if fault == "changed" { try Data("changed".utf8).write(to: directory.appendingPathComponent("manifest.json")) }
        let mover: @Sendable (URL) throws -> URL = { path in try FileManager.default.moveItem(at: path, to: destination); return destination }
        if fault == "changed" {
            #expect(throws: (any Error).self) { try SNESLibraryBackupHistory.moveToTrash(preview: preview, workspace: workspace, journals: journals, mover: mover) }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        } else {
            let moved = try SNESLibraryBackupHistory.moveToTrash(preview: preview, workspace: workspace, journals: journals, mover: mover)
            #expect(moved.path == destination.path && !FileManager.default.fileExists(atPath: directory.path))
            #expect(try SNESLibraryBackup.open(directory: moved).manifestSHA256 == backup.manifestSHA256)
        }
    }
}

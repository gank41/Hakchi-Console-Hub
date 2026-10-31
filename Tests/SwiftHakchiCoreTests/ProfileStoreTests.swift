import Foundation
import Testing
@testable import SwiftHakchiCore

struct ProfileStoreTests {
    @Test func persistsSeparateDeviceSelectionsAndRejectsCorruption() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConsoleProfileStore(directory: root)
        let first = ConsoleProfile(deviceID: "ONE", systemCode: "nes-usa", selectedCustomCodes: ["CLV-H-AAAAA"])
        let second = ConsoleProfile(deviceID: "TWO", systemCode: "nes-usa", selectedCustomCodes: ["CLV-H-BBBBB"])
        try store.save(first); try store.save(second)
        #expect(try store.load(deviceID: "ONE", systemCode: "nes-usa") == first)
        #expect(try store.load(deviceID: "TWO", systemCode: "nes-usa") == second)
        try Data("broken".utf8).write(to: root.appendingPathComponent(first.storageKey + ".json"))
        #expect(throws: (any Error).self) { try store.load(deviceID: "ONE", systemCode: "nes-usa") }
    }
    @Test func workspaceNeverUsesROMSourceAsManagedLibrary() {
        let root = URL(fileURLWithPath: "/example/NES")
        let workspace = WorkspacePaths(root: root)
        #expect(workspace.gamesDirectory(systemCode: "nes-usa").path == "/example/NES/Library/Games/nes-usa")
        #expect(workspace.backups.path == "/example/NES/Backups")
        #expect(workspace.logs.path == "/example/NES/Logs")
    }
    @Test func migrationCopiesWithoutChangingOrOverwritingSource() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old-library")
        let destination = root.appendingPathComponent("new-library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("game.nes"))
        try LibraryMigration.copy(from: source, to: destination)
        #expect(try Data(contentsOf: source.appendingPathComponent("game.nes")) == Data("original".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("game.nes")) == Data("original".utf8))
        #expect(throws: (any Error).self) { try LibraryMigration.copy(from: source, to: destination) }
        #expect(throws: (any Error).self) { try LibraryMigration.copy(from: source, to: source.appendingPathComponent("nested")) }
    }

}

import Foundation
import Testing
@testable import SwiftHakchi

struct SNESNativeSaveLayoutTests {
    private let prefix = "clover/profiles/0/CLV-U-ABCDE/"
    private var complete: [String] {
        ["cartridge.sram", "cartridge.sram.hash", "save/system-save.json/data", "save/system-save.json/hash",
         "suspendpoint1/state.png", "suspendpoint1/state.time", "suspendpoint1/rollback/sram.hash",
         "suspendpoint1/rollback/0.break", "suspendpoint1/rollback/0.inputs", "suspendpoint1/rollback/1.break"].map { prefix + $0 }
    }

    @Test func groupsCompleteNativeSavesAndSuspendPoints() throws {
        let layout = try SNESNativeSaveLayout(paths: complete)
        #expect(layout.gameCodes == ["CLV-U-ABCDE"])
        #expect(layout.groups.count == 3)
        #expect(layout.groups.flatMap(\.paths).sorted() == complete.sorted())
    }

    @Test func refusesIncompletePairsAndSuspendPointSets() throws {
        for missing in ["cartridge.sram.hash", "save/system-save.json/hash", "suspendpoint1/state.png", "suspendpoint1/state.time", "suspendpoint1/rollback/sram.hash", "suspendpoint1/rollback/0.break"] {
            #expect(throws: (any Error).self) { try SNESNativeSaveLayout(paths: complete.filter { $0 != prefix + missing }) }
        }
        #expect(throws: (any Error).self) { try SNESNativeSaveLayout(paths: [prefix + "suspendpoint1/state.png", prefix + "suspendpoint1/state.time"]) }
    }

    @Test func refusesUnknownOrUnsafeFilesAndBrokenRollbackSequences() throws {
        for extra in ["settings.json", "hakchi/other/session", "suspendpoint0/state.png", "suspendpoint5/state.png", "../other", "suspendpoint1/rollback/999999.break"] {
            #expect(throws: (any Error).self) { try SNESNativeSaveLayout(paths: complete + [prefix + extra]) }
        }
        #expect(throws: (any Error).self) { try SNESNativeSaveLayout(paths: complete + [complete[0]]) }
        #expect(throws: (any Error).self) { try SNESNativeSaveLayout(paths: complete + [prefix + "suspendpoint1/rollback/3.break"]) }
        #expect(throws: (any Error).self) { try SNESNativeSaveLayout(paths: complete + [prefix + "suspendpoint1/rollback/2.inputs"]) }
        #expect(throws: (any Error).self) { try SNESNativeSaveLayout(paths: complete + [prefix + "suspendpoint1/rollback/1.inputs"]) }
        #expect(throws: (any Error).self) { try SNESNativeSaveLayout(paths: []) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_NATIVE_SAVE_BACKUP"] != nil))
    func observedBackupContainsCompleteKnownSaveGroups() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_NATIVE_SAVE_BACKUP"])
        let backup = try SNESLibraryBackup.open(directory: URL(fileURLWithPath: path))
        var games: [String: [String]] = [:]
        for file in backup.inventory.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 5, parts[0] == "clover", parts[1] == "profiles", parts[2] == "0",
                  parts[3].hasPrefix("CLV-") else { continue }
            games[String(parts[3]), default: []].append(file.path)
        }
        #expect(!games.isEmpty)
        for paths in games.values { _ = try SNESNativeSaveLayout(paths: paths) }
    }
}

import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct SNESLibrarySetupCompletionFlowTests {
    @Test func captureRequiresTheConfirmedFolderStageAndReadyConsole() async throws {
        let upgrade = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/folder-update"), reviewSHA256: String(repeating: "a", count: 64))
        let menuUpdate = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/menu-update"), reviewSHA256: String(repeating: "b", count: 64))
        let menu = try SNESMenuSetupStageContext(stage: .menu, parent: nil)
        let folders = try #require(menu.next(after: menuUpdate))
        var calls = 0
        #expect(throws: (any Error).self) { try SNESLibrarySetupCompletionFlow(stage: menu, upgrade: upgrade, capture: { _ in URL(fileURLWithPath: "/tmp/result") }) }
        #expect(throws: (any Error).self) { try SNESLibrarySetupCompletionFlow(stage: folders, upgrade: menuUpdate, capture: { _ in URL(fileURLWithPath: "/tmp/result") }) }
        let flow = try SNESLibrarySetupCompletionFlow(stage: folders, upgrade: upgrade, capture: { received in
            calls += 1; #expect(received.operation == upgrade.operation); return URL(fileURLWithPath: "/tmp/catalog")
        })
        await flow.capture(ready: false); #expect(calls == 0 && flow.phase == .ready)
        await flow.capture(ready: true); await flow.capture(ready: true)
        #expect(calls == 1 && flow.phase == .complete && flow.catalog?.path == "/tmp/catalog")
    }

    @Test func failedCaptureCannotClaimSetupIsReady() async throws {
        let upgrade = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/folder-update"), reviewSHA256: String(repeating: "a", count: 64))
        let parent = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/menu-update"), reviewSHA256: String(repeating: "b", count: 64))
        let stage = try SNESMenuSetupStageContext(stage: .gameFolders, parent: parent)
        let flow = try SNESLibrarySetupCompletionFlow(stage: stage, upgrade: upgrade, capture: { _ in throw RecoveryProbeError.refused("Console not available") })
        await flow.capture(ready: true)
        #expect(flow.phase == .failed && flow.catalog == nil && flow.error != nil)
    }
}

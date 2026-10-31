import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct LibrarySyncRoutingTests {
    @Test func legacyNESReviewUsesItsExistingFlowAndDoesNotOpenSNESReview() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path
        let info = try await ConsoleRuntimeConnection.legacy(makeLegacyClient: { LegacyInspectionClient(transport: LegacyFakeUSB(.consoleReport)) })
        let manager = DeviceManager(connectRuntime: { _ in info })
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager, gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        await manager.inspectAttachments([ConsoleAttachmentTests.legacy()])
        #expect(app.canReviewLibrarySync)
        app.reviewLibrarySync()
        #expect(app.showLegacyFullSync && !app.showSNESLibrarySync && app.isPreparingSync)
        app.showLegacyFullSync = false; app.isPreparingSync = false
        await manager.inspectAttachments([])
        #expect(!app.canReviewLibrarySync)
        app.reviewLibrarySync()
        #expect(!app.showLegacyFullSync && !app.showSNESLibrarySync && !app.isPreparingSync)
    }
    @Test(arguments: ["snes", "genesis", "busy"])
    func genericConnectionFlagsCannotOpenTheWrongWorkflow(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path
        let console: ConsoleType = fault == "genesis" ? .megaDrive : .snesUsa
        let manager = DeviceManager(connectRuntime: { _ in
            var value = ConnectedConsoleInfo(consoleType: console); value.canSync = true; value.canInteract = true; return value
        })
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager, gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        await manager.inspectAttachments([SNESLibraryContextTests.device()])
        if fault == "busy" { app.isPreparingSync = true }
        #expect(!app.canReviewLibrarySync)
        app.reviewLibrarySync()
        #expect(!app.showLegacyFullSync && !app.showSNESLibrarySync)
        await manager.inspectAttachments([])
    }
}

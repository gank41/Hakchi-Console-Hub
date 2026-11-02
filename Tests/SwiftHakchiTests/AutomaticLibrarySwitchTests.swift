import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct AutomaticLibrarySwitchTests {
    @Test(.timeLimit(.minutes(1))) func recognizedConnectionUpdatesSelectedLibraryWithoutManualRefresh() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .snesUsa
        let manager = DeviceManager(connectRuntime: { _ in ConnectedConsoleInfo(consoleType: .nes) })
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager,
            gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        await manager.inspectAttachments([ConsoleAttachmentTests.legacy()])
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while config.lastConsoleType != .nes && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(manager.isConnected && config.lastConsoleType == .nes)
        _ = app
    }
    @Test func inventorySuppliesAuthoritativeIdentityWhenTheOptionalUIDFileIsAbsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path
        let manager = DeviceManager(connectRuntime: { _ in ConnectedConsoleInfo(consoleType: .nes) })
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager,
            gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        await manager.inspectAttachments([probeRNDIS()])
        let inventory = DeviceInventory(profile: ConsoleProfile(deviceID: "authoritative-device", systemCode: "nes-usa"),
            consoleType: .nes, activePage: "/var/lib/hakchi/games/nes-usa/000", syncBase: "/var/lib/hakchi/games/nes-usa",
            freeBytes: 100000, installedCodes: [], visibleCodes: [], versions: "", canSync: true)
        #expect(app.applyConnectedInventory(inventory, remote: [], session: manager.sessionID))
        #expect(config.lastDeviceId == "authoritative-device")
        #expect(manager.uniqueId == "authoritative-device")
        let stale = manager.sessionID
        await manager.inspectAttachments([])
        #expect(!app.applyConnectedInventory(inventory, remote: [], session: stale))
    }
    @Test func switchingLibrariesPreservesEditsAndSelectionsAndRejectsStaleSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path
        let legacyInfo = try await ConsoleRuntimeConnection.legacy(makeLegacyClient: {
            LegacyInspectionClient(transport: LegacyFakeUSB(.consoleReport))
        })
        await legacyInfo.close()
        let games = GameManagerService(config: config)
        let directory = config.gamesDirectory.appendingPathComponent("CLV-H-ABCDE")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[Desktop Entry]\nCode=CLV-H-ABCDE\nName=My edited title\nExec=/bin/clover-kachikachi game.nes\n".utf8)
            .write(to: directory.appendingPathComponent("CLV-H-ABCDE.desktop"))
        config.lastDeviceId = "0123456789abcdef0011223344556677"; games.loadGames()
        games.setSelection(true, codes: ["CLV-H-ABCDE"])
        let manager = DeviceManager(connectRuntime: { attachment in
            var info = ConnectedConsoleInfo(consoleType: attachment.registryEntryID == 44 ? .nes : .snesUsa)
            info.uniqueID = info.consoleType == .nes ? legacyInfo.uniqueID : "snes-device"
            return info
        })
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager, gameManager: games,
                           config: config, saveConfiguration: {})
        await manager.inspectAttachments([ConsoleAttachmentTests.legacy(id: 45)])
        let old = manager.sessionID
        await app.onConsoleConnected()
        #expect(config.lastConsoleType == .snesUsa)
        #expect(games.games.isEmpty)
        #expect(!manager.canSync)
        await manager.inspectAttachments([ConsoleAttachmentTests.legacy()])
        #expect(!app.adoptConnectedLibrary(session: old))
        await app.onConsoleConnected()
        #expect(config.lastConsoleType == .nes)
        #expect(games.games.first?.name == "My edited title")
        #expect(games.games.first?.isSelected == true)
        app.reviewLegacyFullSync()
        #expect(!app.showLegacyFullSync)
    }

    @Test func unknownConsoleDoesNotChangeLibraryChoice() async {
        let config = AppConfig(); config.lastConsoleType = .snesUsa
        let manager = DeviceManager(connectRuntime: { _ in ConnectedConsoleInfo(consoleType: .unknown) })
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager,
            gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        await manager.inspectAttachments([ConsoleAttachmentTests.legacy()])
        await app.onConsoleConnected()
        #expect(config.lastConsoleType == .snesUsa)
    }
}

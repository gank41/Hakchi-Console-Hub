import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct ConsoleRecoveryTests {
    @Test func connectedConsoleWinsAndDisconnectUsesSelectedLibrary() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .snesUsa
        let manager = DeviceManager(connectRuntime: { _ in ConnectedConsoleInfo(consoleType: .nes) })
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager,
            gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        #expect(app.recoveryContext.console == .snesUsa && !app.recoveryContext.isConnected)
        await manager.inspectAttachments([probeRNDIS()])
        #expect(app.recoveryContext.console == .nes && app.recoveryContext.isConnected)
        await manager.inspectAttachments([])
        #expect(app.recoveryContext.console == .snesUsa && !app.recoveryContext.isConnected)
    }
    @Test func everyModelOffersTheSameSeparateChoicesWithoutAWriteCapability() {
        for console in ConsoleType.allCases {
            let context = ConsoleRecoveryContext(connected: .unknown, selected: console)
            #expect(context.choices == [.returnToBuiltInGames, .restoreOriginalStartup, .eraseSavesAndSettings])
            #expect(!context.canExecute)
            #expect(context.choices.allSatisfy { !$0.effects.changesMacLibrary })
        }
    }
    @Test func unsupportedModelsNeverInspectNESMaterialOrLoadItsPayload() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = RecoveryPreflightService(payloadEvidence: {
            Issue.record("Unsupported model loaded Nintendo recovery payloads")
            throw RecoveryImageError.invalid("Unexpected payload inspection")
        })
        for console in [ConsoleType.megaDrive, .famicom, .snesEur, .superFamicom, .superFamicomShonenJump, .unknown] {
            let report = await service.inspect(backups: root, console: console)
            #expect(report.kernel.status == .unavailable && report.payload.status == .unavailable)
            #expect(report.kernel.path == nil && report.warnings.isEmpty && !report.canReset)
        }
    }
    @Test func SNESDoesNotMistakeAnNESRecoveryDirectoryForItsOwnBackup() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("RecoveryMaterial-old"), withIntermediateDirectories: false)
        let service = RecoveryPreflightService(payloadEvidence: { throw RecoveryImageError.invalid("No fixture payload") })
        let report = await service.inspect(backups: root, console: .snesUsa)
        #expect(report.kernel.status == .missing)
        #expect(report.warnings.isEmpty && !report.canReset)
    }
}

extension ConsoleRecoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil, "Requires a private SNES setup fixture"))
    func SNESInspectionReopensAndVerifiesItsPortableRecoveryPackage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"])
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let material = try SNESRecoveryMaterial.load(setup: URL(fileURLWithPath: path))
        let package = try await RecoveryBootSnapshotStore(root: root).saveSNESRecoveryMaterial(material)
        let service = RecoveryPreflightService(payloadEvidence: { throw RecoveryImageError.invalid("No fixture payload") })
        let valid = await service.inspect(backups: root, console: .snesUsa)
        #expect(valid.kernel.status == .verified && valid.kernel.path == package && !valid.canReset)
        try Data("corrupt".utf8).write(to: package.appendingPathComponent("recovery-review.json"))
        let corrupt = await service.inspect(backups: root, console: .snesUsa)
        #expect(corrupt.kernel.status == .failed && !corrupt.warnings.isEmpty && !corrupt.canReset)
    }
}

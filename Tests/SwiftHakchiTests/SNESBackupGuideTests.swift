import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct SNESBackupGuideTests {
    @Test func failedCheckKeepsDiagnosticSeparateFromCompletedBackup() async {
        let directory = URL(fileURLWithPath: "/private/tmp/SNES-Diagnostic")
        let guide = SNESBackupGuide { _ in throw SNESSetupDiagnosticSavedError(directory: directory) }
        await guide.start(ready: true)
        #expect(guide.phase == .returnToNormal)
        #expect(guide.backupDirectory == nil)
        #expect(guide.diagnosticDirectory == directory)
        guide.confirmNormalBoot()
        #expect(guide.phase == .failed)
    }

    @Test func anotherPreviewPreventsPreparationBeforeUSBOrBackupCreation() async throws {
        let config = AppConfig(); config.lastConsoleType = .snesUsa
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        config.workspacePath = root.path
        let manager = DeviceManager()
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager,
            gameManager: GameManagerService(config: config), config: config, saveConfiguration: {},
            checkRecoveryHost: { throw RecoveryProbeError.refused("Another preview is open") })
        app.isPreparingSync = true
        await #expect(throws: RecoveryProbeError.self) { try await app.captureSNESKernel(progress: { _ in }) }
        #expect(!manager.suppressAutoConnect)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func readinessAndNormalBootAreRequiredAndNoAutomaticRetryOccurs() async {
        let calls = ConnectionCallCounter()
        let guide = SNESBackupGuide { progress in
            await calls.record(1)
            await progress(.uploadingRecovery)
            return URL(fileURLWithPath: "/tmp/SNES-US-Kernel-test")
        }
        await guide.start(ready: false)
        #expect(await calls.ids.isEmpty)
        await guide.start(ready: true)
        #expect(guide.phase == .returnToNormal)
        #expect(guide.backupDirectory != nil)
        await guide.start(ready: true)
        #expect(await calls.ids.count == 1)
        guide.confirmNormalBoot()
        #expect(guide.phase == .complete)
    }
    @Test func failureAfterBootStillRequiresNormalBootAndPreservesError() async {
        let guide = SNESBackupGuide { progress in
            await progress(.uploadingRecovery)
            throw RecoveryProbeError.refused("Test failure")
        }
        await guide.start(ready: true)
        #expect(guide.phase == .returnToNormal && guide.errorMessage == "Test failure")
        #expect(guide.backupDirectory == nil)
        guide.confirmNormalBoot()
        #expect(guide.phase == .failed)
    }
}

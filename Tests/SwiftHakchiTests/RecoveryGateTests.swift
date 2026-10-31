import Foundation
import Testing
@testable import SwiftHakchi

actor RecoveryBootSpy: FELBooting {
    enum Unexpected: Error { case boot }
    private(set) var calls = 0
    func memboot(fes1Data: Data, ubootData: Data, bootImgData: Data,
                 progress: (@Sendable (String, Double) -> Void)?) async throws {
        calls += 1
        throw Unexpected.boot
    }
}

@MainActor
struct RecoveryGateTests {
    @Test(arguments: ["install", "uninstall", "reset"])
    func unvalidatedFirmwareMethodsRefuseBeforeAnyBootOrProgress(operation: String) async {
        let boot = RecoveryBootSpy()
        let manager = DeviceManager() // Deliberately never start its USB monitor.
        let service = FlashService(felService: boot, deviceManager: manager)
        let progress: @Sendable (String, Double) -> Void = { _, _ in Issue.record("Firmware gate emitted progress before refusing") }
        do {
            switch operation {
            case "install":
                try await service.installHakchi(fes1: Data(), uboot: Data(), bootImg: Data(), baseHmods: Data(), hakchiHmod: Data(), backupSettings: BackupSettings(enabled: true, directory: nil), progress: progress)
            case "uninstall":
                try await service.uninstallHakchi(fes1: Data(), uboot: Data(), bootImg: Data(), progress: progress)
            default:
                try await service.factoryReset(fes1: Data(), uboot: Data(), bootImg: Data(), kernelImage: nil, progress: progress)
            }
            Issue.record("Unvalidated firmware method returned success")
        } catch FlashError.recoveryNotValidated {
            // Expected before any console transport is touched.
        } catch { Issue.record("Wrong refusal: \(error)") }
        #expect(await boot.calls == 0)
    }
}

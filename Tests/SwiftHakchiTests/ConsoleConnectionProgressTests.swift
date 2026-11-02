import Testing
@testable import SwiftHakchi

struct ConsoleConnectionProgressTests {
    @Test func statusDoesNotSayDisconnectedWhileConnectingOrReadyInRecovery() {
        #expect(ConsoleConnectionStatus.resolve(connected: false, legacy: false, console: .unknown, stage: .openingUSB, recoveryUSB: false, hasError: false) == .connecting)
        #expect(ConsoleConnectionStatus.resolve(connected: false, legacy: false, console: .unknown, stage: nil, recoveryUSB: true, hasError: false) == .recoveryOrLegacyUSB)
        #expect(ConsoleConnectionStatus.resolve(connected: false, legacy: false, console: .unknown, stage: nil, recoveryUSB: false, hasError: true) == .failed)
        #expect(ConsoleConnectionStatus.resolve(connected: true, legacy: true, console: .nes, stage: nil, recoveryUSB: false, hasError: true) == .connectedLegacy)
        #expect(ConsoleConnectionStatus.resolve(connected: false, legacy: false, console: .unknown, stage: nil, recoveryUSB: false, hasError: false) == .disconnected)
    }
    @MainActor @Test func supersededProgressCannotReplaceTheNewConnectionsStatus() {
        let manager = DeviceManager(), old = manager.sessionID
        #expect(manager.updateConnectionStage(.openingUSB, session: old))
        manager.manualDisconnect()
        let current = manager.sessionID
        #expect(manager.updateConnectionStage(.identifyingConsole, session: current))
        #expect(!manager.updateConnectionStage(.verifyingConsole, session: old))
        #expect(manager.connectionStage == .identifyingConsole)
    }

    @MainActor @Test func disconnectClearsTheConnectingIndicator() {
        let manager = DeviceManager()
        #expect(manager.updateConnectionStage(.checkingSetupFiles, session: manager.sessionID))
        #expect(manager.isConnecting)
        manager.manualDisconnect()
        #expect(!manager.isConnecting && manager.connectionStage == nil)
    }
}

import Testing
@testable import SwiftHakchi

struct ConsoleConnectionProgressTests {
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

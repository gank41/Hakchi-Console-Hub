import Foundation
import Testing
@testable import SwiftHakchi


@MainActor
struct LegacyConnectionTests {
    @Test func legacyConnectionEnablesInspectionButNeverModernWrites() async throws {
        let usb = LegacyFakeUSB(.consoleReport)
        let client = LegacyInspectionClient(transport: usb)
        let manager = DeviceManager(makeLegacyClient: { client })
        manager.usbMonitor.felDevicePresent = true
        manager.usbMonitor.attachments = [ConsoleAttachmentTests.legacy()]
        #expect(await manager.reconnect())
        #expect(manager.isConnected)
        #expect(manager.legacyReport?.bootVersion == "1.0.1")
        #expect(manager.uniqueId == "0123456789abcdef0011223344556677")
        #expect(!manager.canInteract && !manager.canSync)
        #expect(manager.sshService == nil)
        manager.manualDisconnect()
        #expect(!manager.isConnected && manager.legacyReport == nil)
        await client.disconnect()
    }
}


extension LegacyConnectionTests {
    @Test func initialAbsentRNDISNotificationCannotCancelLegacyConnect() async throws {
        let usb = LegacyFakeUSB(.consoleReport)
        let client = LegacyInspectionClient(transport: usb)
        let manager = DeviceManager(makeLegacyClient: { client })
        manager.usbMonitor.felDevicePresent = true
        manager.usbMonitor.attachments = [ConsoleAttachmentTests.legacy()]
        let connecting = Task { await manager.reconnect() }
        await Task.yield()
        manager.handleRNDISPresence(false)
        #expect(await connecting.value)
        #expect(manager.legacyReport != nil)
        manager.manualDisconnect()
        await client.disconnect()
    }
}

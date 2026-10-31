import Foundation
import Testing
@testable import SwiftHakchi

struct ConsoleAttachmentTests {
    static func legacy(id: UInt64 = 44) -> RecoveryProbeUSBDevice {
        .init(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: 0x0233,
              deviceClass: 0, locationID: 123, product: "CLV-S-NESY", registryEntryID: id)
    }
    @Test func recoveryIsNeverChallengedAsNormalFirmware() {
        #expect(ConsoleAttachmentPolicy.kind(of: probeFEL()) == .recovery)
        #expect(ConsoleAttachmentPolicy.kind(of: Self.legacy()) == .legacy)
        #expect(ConsoleAttachmentPolicy.kind(of: probeRNDIS()) == .rndis)
    }
    @Test func incompleteOrUnknownDescriptorsAreNotAutoconnectTargets() {
        let unknown = RecoveryProbeUSBDevice(vendorID: 0x1f3a, productID: 0xefe8,
            deviceVersion: 0x0233, deviceClass: 0, locationID: 123, product: "", registryEntryID: 99)
        #expect(ConsoleAttachmentPolicy.kind(of: unknown) == .unsupported)
        #expect(ConsoleAttachmentPolicy.kind(of: probeFEL(registryID: nil)) == .unsupported)
        #expect(ConsoleAttachmentPolicy.single([Self.legacy(), probeRNDIS()]) == nil)
    }
    @Test func legacyBoardAndRegionAreAuthoritative() throws {
        #expect(try LegacyConsoleIdentity.parse(Data("SWIFTHAKCHI_CONSOLE_ID_V1\nBOARD=dp-nes\nREGION=EUR_USA\nEND\n".utf8)) == .nes)
        #expect(try LegacyConsoleIdentity.parse(Data("SWIFTHAKCHI_CONSOLE_ID_V1\nBOARD=dp-shvc\nREGION=USA\nEND\n".utf8)) == .snesUsa)
        #expect(try LegacyConsoleIdentity.parse(Data("SWIFTHAKCHI_CONSOLE_ID_V1\nBOARD=dp-shvc\nREGION=EUR\nEND\n".utf8)) == .snesEur)
        #expect(try LegacyConsoleIdentity.parse(Data("SWIFTHAKCHI_CONSOLE_ID_V1\nBOARD=dp-shvc\nREGION=JPN\nEND\n".utf8)) == .superFamicom)
        #expect(throws: (any Error).self) { try LegacyConsoleIdentity.parse(Data("SWIFTHAKCHI_CONSOLE_ID_V1\nBOARD=dp-shvc\nREGION=UNKNOWN\nEND\n".utf8)) }
    }
    @Test func legacyIdentityCommandFramesFilesWithOrWithoutFinalNewlines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for suffix in ["", "\n"] {
            try Data(("dp-nes" + suffix).utf8).write(to: root.appendingPathComponent("boardtype"))
            try Data(("EUR_USA" + suffix).utf8).write(to: root.appendingPathComponent("REGION"))
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", LegacyConsoleIdentity.command.replacingOccurrences(of: "/etc/clover", with: root.path)]
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(try LegacyConsoleIdentity.parse(output) == .nes)
        }
    }
    @Test @MainActor func newAttachmentConnectsButManualDisconnectStaysDisconnectedUntilReplacement() async throws {
        let calls = ConnectionCallCounter()
        let manager = DeviceManager(connectRuntime: { device in
            await calls.record(device.registryEntryID!)
            return ConnectedConsoleInfo(consoleType: .nes)
        })
        await manager.inspectAttachments([Self.legacy()])
        #expect(manager.isConnected && manager.consoleType == .nes)
        manager.manualDisconnect()
        await manager.inspectAttachments([Self.legacy()])
        #expect(!manager.isConnected)
        await manager.inspectAttachments([Self.legacy(id: 45)])
        #expect(manager.isConnected)
        #expect(await calls.ids == [44, 45])
    }
    @Test @MainActor func recoveryAndMultipleDevicesDoNotOpenRuntimeConnections() async {
        let calls = ConnectionCallCounter()
        let manager = DeviceManager(connectRuntime: { device in
            await calls.record(device.registryEntryID!)
            return ConnectedConsoleInfo(consoleType: .nes)
        })
        await manager.inspectAttachments([probeFEL()])
        await manager.inspectAttachments([Self.legacy(), probeRNDIS()])
        #expect(await calls.ids.isEmpty)
        #expect(!manager.isConnected)
    }
    @Test @MainActor func unvalidatedConsoleCannotEnableRetainedConsoleActions() async {
        let manager = DeviceManager(connectRuntime: { _ in
            var info = ConnectedConsoleInfo(consoleType: .snesUsa)
            info.canInteract = true; info.canSync = true
            return info
        })
        await manager.inspectAttachments([probeRNDIS()])
        #expect(manager.isConnected)
        #expect(!manager.canInteract && !manager.canSync)
    }
    @Test @MainActor func unplugClearsTheConnectedConsole() async {
        let manager = DeviceManager(connectRuntime: { _ in ConnectedConsoleInfo(consoleType: .snesUsa) })
        await manager.inspectAttachments([probeRNDIS()])
        #expect(manager.consoleType == .snesUsa)
        await manager.inspectAttachments([])
        #expect(!manager.isConnected && manager.consoleType == .unknown)
    }
    @Test @MainActor func lateConnectionCannotReplaceTheNewConsole() async throws {
        let gate = PendingConsoleConnection()
        let manager = DeviceManager(connectRuntime: { device in
            if device.registryEntryID == 44 { return await gate.wait() }
            return ConnectedConsoleInfo(consoleType: .snesUsa)
        })
        let first = Task { await manager.inspectAttachments([Self.legacy()]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !(await gate.entered) {
            guard ContinuousClock.now < deadline else { Issue.record("Connection did not start"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        await manager.inspectAttachments([Self.legacy(id: 45)])
        await gate.finish()
        await first.value
        #expect(manager.consoleType == .snesUsa && manager.isConnected)
    }
    @Test @MainActor func recoveryOwnershipBlocksAutoConnectUntilUnplug() async {
        let calls = ConnectionCallCounter()
        let manager = DeviceManager(connectRuntime: { device in
            await calls.record(device.registryEntryID!)
            return ConnectedConsoleInfo(consoleType: .snesUsa)
        })
        await manager.pauseForRecovery()
        await manager.inspectAttachments([probeRNDIS()])
        manager.waitForNormalBootAfterRecovery()
        await manager.inspectAttachments([probeRNDIS()])
        #expect(await calls.ids.isEmpty)
        await manager.inspectAttachments([])
        await manager.inspectAttachments([Self.legacy()])
        #expect(manager.isConnected)
    }
}

private actor PendingConsoleConnection {
    private(set) var entered = false
    private var continuation: CheckedContinuation<ConnectedConsoleInfo, Never>?
    func wait() async -> ConnectedConsoleInfo {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: ConnectedConsoleInfo(consoleType: .nes)); continuation = nil }
}

actor ConnectionCallCounter {
    private(set) var ids: [UInt64] = []
    func record(_ id: UInt64) { ids.append(id) }
}

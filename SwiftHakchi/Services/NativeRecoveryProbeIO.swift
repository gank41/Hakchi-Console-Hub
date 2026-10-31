import Foundation
import IOKit
import AppKit

/// Passive registry observations; exact entry IDs bind the later recovery opens.
enum RecoveryProbeUSBRegistry {
    static func device(from properties: [String: Any], registryEntryID: UInt64? = nil) throws -> RecoveryProbeUSBDevice? {
        guard let vid = properties["idVendor"] as? NSNumber, let pid = properties["idProduct"] as? NSNumber else { return nil }
        let pair = (vid.int64Value, pid.int64Value)
        guard pair == (0x1f3a, 0xefe8) || pair == (0x04e8, 0x6863) else { return nil }
        func number(_ key: String, maximum: Int64) throws -> Int64 {
            guard let value = properties[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: value.objCType)),
                  (0...maximum).contains(value.int64Value) else {
                throw RecoveryProbeError.refused("Incomplete console USB descriptor: \(key).")
            }
            return value.int64Value
        }
        let product: String
        if let value = properties["USB Product Name"] {
            guard let text = value as? String else { throw RecoveryProbeError.refused("Malformed console USB product descriptor.") }
            product = text
        } else { product = "" }
        return try RecoveryProbeUSBDevice(vendorID: UInt16(number("idVendor", maximum: 65535)), productID: UInt16(number("idProduct", maximum: 65535)),
            deviceVersion: UInt16(number("bcdDevice", maximum: 65535)),
            deviceClass: UInt8(number("bDeviceClass", maximum: 255)),
            locationID: UInt32(number("locationID", maximum: Int64(UInt32.max))),
            product: product, registryEntryID: registryEntryID)
    }
    static func inventory() throws -> [RecoveryProbeUSBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            throw RecoveryProbeError.refused("Cannot enumerate USB registry; no device was opened.")
        }
        defer { IOObjectRelease(iterator) }
        var devices: [RecoveryProbeUSBDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = properties?.takeRetainedValue() as? [String: Any] else {
                throw RecoveryProbeError.refused("Cannot read complete USB registry properties.")
            }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS, registryID > 0 else {
                throw RecoveryProbeError.refused("Cannot read the exact USB registry attachment identity.")
            }
            if let device = try device(from: properties, registryEntryID: registryID) { devices.append(device) }
        }
        return devices
    }
    @MainActor static func requireOrdinaryAppClosed() throws {
        let competing = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            (($0.bundleIdentifier?.hasPrefix("com.swifthakchi.") ?? false) || $0.executableURL?.lastPathComponent == "SwiftHakchi")
        }
        guard competing.isEmpty else {
            throw RecoveryProbeError.refused("Quit other Swift Hakchi apps and recovery tools, then try again. Only one app can use the console’s USB connection at a time.")
        }
    }
}

enum RecoveryProbeCommand {
    // No script sourcing or hakchi wrapper: that wrapper calls save_config after commands.
    static let observation = #"""
    printf 'SWIFTHAKCHI_RAM_PROBE_V1\nKERNEL='; uname -r
    printf 'CMDLINE='; cat /proc/cmdline
    printf 'INIT_SHA='; sha256sum /hakchi/init | cut -d' ' -f1
    printf 'BASE_SHA='; sha256sum /hakchi/rootfs/etc/preinit.d/b0000_defines | cut -d' ' -f1
    printf 'BOARD=%s\n' "$(cat /newroot/etc/clover/boardtype)"
    printf 'NES_DIRECTORY='; if test -d /newroot/usr/share/games/nes/kachikachi; then printf '1\n'; else printf '0\n'; fi
    printf 'HWID='; sntool devmem 0x01c23800 32 | hexdump -v -e '4/4 "%08x"' -n16; printf '\n'
    printf 'MOUNTS_BEGIN\n'; cat /proc/mounts; printf 'MOUNTS_END\nEND\n'
    """#
}

actor NativeRecoveryProbeIO: RecoveryProbeIO {
    static func redactedObservationMessage(_ raw: String) -> String {
        "Received recovery observation (private hardware identity omitted; \(raw.utf8.count) bytes)."
    }
    private let shell: SSHService
    private let observationCommand: String
    init(shell: SSHService = SSHService(), observationCommand: String = RecoveryProbeCommand.observation) {
        self.shell = shell; self.observationCommand = observationCommand
    }
    func inventory() throws -> [RecoveryProbeUSBDevice] {
        try Task.checkCancellation()
        return try RecoveryProbeUSBRegistry.inventory()
    }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws {
        try Task.checkCancellation()
        _ = try expected.nativeIdentity(for: .fel)
        let fel = FELService(makeSession: { IOKitFELSessionTransport(expected: expected) })
        print("One temporary RAM boot requested on the exact observed attachment. This RAM boot does not write firmware.")
        try await fel.memboot(fes1Data: inputs.fes1, ubootData: inputs.uboot, bootImgData: inputs.bootImage,
                              progress: { status, _ in print(status) })
    }
    func connect(expected: RecoveryProbeUSBDevice) async throws {
        try Task.checkCancellation()
        try await shell.connect(expected: expected)
    }
    func observe() async throws -> String {
        try Task.checkCancellation()
        let result = try await shell.execute(observationCommand, timeout: 15000)
        guard result.succeeded, result.stdoutData.count <= 65536,
              let text = String(data: result.stdoutData, encoding: .utf8) else {
            throw RecoveryProbeError.refused("Recovery query failed, was oversized or was not UTF-8. The recovery session was not accepted.")
        }
        print(Self.redactedObservationMessage(text))
        return text
    }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read {
        try Task.checkCancellation()
        print("Reading boot2 kernel at hex sector " + slot.offset + " (no burn command)…")
        let result = try await shell.execute(RecoveryBootSnapshotCommand.read(slot), timeout: 60000)
        try Task.checkCancellation()
        guard result.succeeded else { throw RecoveryProbeError.refused("Kernel read command failed; no complete snapshot was accepted.") }
        return try RecoveryBoot2Read.parse(result.stdoutData)
    }
    func readBoot1() async throws -> Data {
        try Task.checkCancellation()
        print("Reading boot1 at hex sector 8 (no burn command)…")
        let result = try await shell.execute(RecoveryBoot1SnapshotCommand.read, timeout: 60_000)
        try Task.checkCancellation()
        guard result.succeeded else { throw RecoveryProbeError.refused("Boot1 read failed; no install evidence was accepted.") }
        return try RecoveryBoot1Read.parse(result.stdoutData)
    }
    func readPartitions() async throws -> Data {
        try Task.checkCancellation()
        print("Reading validated legacy partition views (no changes)…")
        let result = try await shell.execute(StockRestoreCommands.partitions, timeout:15_000)
        try Task.checkCancellation()
        return try StockRestoreCompletion.partitionData(result)
    }
    func readDataSuperblock() async throws -> Data {
        try Task.checkCancellation()
        print("Reading the first 2 KiB of the data partition (no mount or write)…")
        let result = try await shell.execute(RecoveryDataSuperblockCommand.read, timeout:15_000)
        try Task.checkCancellation()
        guard result.succeeded else { throw RecoveryProbeError.refused("Data-partition header read failed. No inventory was accepted.") }
        return result.stdoutData
    }
    func readPersistentInventory() async throws -> Data {
        try Task.checkCancellation()
        print("Inspecting fixed hakchi paths via a checked ro,noload mount; no persistent write…")
        let result = try await shell.execute(RecoveryPersistentInventoryCommand.read, timeout:30_000)
        try Task.checkCancellation()
        if result.stderr.contains("SWIFTHAKCHI_UNMOUNT_FAILED_V1") ||
           result.stderr.contains("SWIFTHAKCHI_MOUNT_STATE_UNKNOWN_V1") {
            throw RecoveryProbeError.refused("Recovery could not confirm that the read-only data mount was removed. After this diagnostic closes, power off the NES and unplug USB for 10 seconds before normal boot. No file inventory was accepted.")
        }
        guard result.succeeded else {
            throw RecoveryProbeError.refused("Persistent fixed-path inventory failed or could not be safely unmounted (remoteExit=\(result.exitCode); stages=\(RecoveryPersistentInventory.stageTrace(result.stderr)); mount=\(RecoveryPersistentInventory.mountFlagTrace(result.stderr))). No file evidence was accepted.")
        }
        guard let printable = RecoveryPersistentInventory.safeDiagnosticText(result.stdoutData) else {
            throw RecoveryProbeError.refused("Persistent inventory returned oversized or non-printable data (\(RecoveryPersistentInventory.diagnosticSummary(result.stdoutData)); stages=\(RecoveryPersistentInventory.stageTrace(result.stderr))). No file evidence was accepted.")
        }
        print("Raw fixed-path inventory frame (private diagnostic):\n" + printable)
        return result.stdoutData
    }
    func disconnect() async { await shell.disconnect() }
    func readSNESRuntime() async throws -> Data {
        try Task.checkCancellation()
        let result = try await shell.execute(SNESRuntimeCommand.read, timeout: 30_000)
        guard result.succeeded, result.stdoutData.count <= 4*1024*1024+4096 else { throw SNESRuntimeBinding.failure() }
        return result.stdoutData
    }
}

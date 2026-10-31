import Foundation
import SwiftHakchiCore

struct RecoveryBootInputs: Sendable {
    let fes1: Data
    let uboot: Data
    let bootImage: Data
    func prepare() throws -> PreparedRecoveryBoot {
        try PreparedRecoveryBoot(fes1: fes1, uboot: uboot, bootImage: bootImage)
    }
}
struct RecoveryProbeUSBDevice: Codable, Equatable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let deviceVersion: UInt16
    let deviceClass: UInt8
    let locationID: UInt32
    let product: String
    let registryEntryID: UInt64?
    init(vendorID: UInt16, productID: UInt16, deviceVersion: UInt16, deviceClass: UInt8,
         locationID: UInt32, product: String, registryEntryID: UInt64? = nil) {
        self.vendorID = vendorID; self.productID = productID; self.deviceVersion = deviceVersion
        self.deviceClass = deviceClass; self.locationID = locationID; self.product = product
        self.registryEntryID = registryEntryID
    }
    var isFEL: Bool { vendorID == 0x1f3a && productID == 0xefe8 }
    var isRNDIS: Bool { vendorID == 0x04e8 && productID == 0x6863 }
}
struct RecoveryProbeObservation: Codable, Sendable {
    let kernel: String
    let board: String
    let hwid: String
    let mounts: [String]
}
struct RecoveryRAMProbeReport: Encodable, Sendable {
    let before: RecoveryProbeUSBDevice
    let after: RecoveryProbeUSBDevice
    let observation: RecoveryProbeObservation
    let bootSnapshot: RecoveryBootSnapshot?
    let boot1Snapshot: RecoveryBoot1Snapshot?
    let dataSuperblock: RecoveryDataSuperblock?
    let persistentInventory: RecoveryPersistentInventory?
    let partitionSHA256: String?
    let firmwareRestoreEligible = false
    init(before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation,
         bootSnapshot: RecoveryBootSnapshot?, boot1Snapshot: RecoveryBoot1Snapshot? = nil,
         dataSuperblock: RecoveryDataSuperblock? = nil, persistentInventory: RecoveryPersistentInventory? = nil,
         partitionSHA256: String? = nil) {
        self.before = before; self.after = after; self.observation = observation
        self.bootSnapshot = bootSnapshot; self.boot1Snapshot = boot1Snapshot
        self.dataSuperblock = dataSuperblock; self.persistentInventory = persistentInventory
        self.partitionSHA256 = partitionSHA256
    }
}
enum RecoveryProbeError: Error, LocalizedError {
    case refused(String)
    var errorDescription: String? { switch self { case .refused(let reason): return reason } }
}
protocol RecoveryProbeIO: Sendable {
    func inventory() async throws -> [RecoveryProbeUSBDevice]
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws
    func connect(expected: RecoveryProbeUSBDevice) async throws
    func observe() async throws -> String
    func disconnect() async
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read
    func readBoot1() async throws -> Data
    func readPartitions() async throws -> Data
    func readDataSuperblock() async throws -> Data
    func readPersistentInventory() async throws -> Data
    func readSNESRuntime() async throws -> Data
}
extension RecoveryProbeIO {
    func readSNESRuntime() async throws -> Data { throw SNESRuntimeBinding.failure() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read {
        throw RecoveryProbeError.refused("This recovery transport cannot capture boot kernels.")
    }
    func readBoot1() async throws -> Data {
        throw RecoveryProbeError.refused("This recovery transport cannot capture boot1 evidence.")
    }
    func readPartitions() async throws -> Data {
        throw RecoveryProbeError.refused("This recovery transport cannot inspect persistent partitions.")
    }
    func readDataSuperblock() async throws -> Data {
        throw RecoveryProbeError.refused("This recovery transport cannot inspect the data filesystem.")
    }
    func readPersistentInventory() async throws -> Data {
        throw RecoveryProbeError.refused("This recovery transport cannot inspect persistent files.")
    }
}

enum RecoveryProbePolicy {
    static func before(_ devices: [RecoveryProbeUSBDevice]) throws -> RecoveryProbeUSBDevice {
        guard devices.count == 1, let device = devices.first, device.isFEL,
              device.deviceVersion == 0x02b3, device.deviceClass == 0,
              device.product.isEmpty, device.locationID != 0, (device.registryEntryID ?? 0) > 0 else {
            throw RecoveryProbeError.refused("Expected exactly one genuine FEL bootloader and no other mini console. Normal Nintendo USB mode shares its identifiers.")
        }
        return device
    }
    static func after(_ devices: [RecoveryProbeUSBDevice], original: RecoveryProbeUSBDevice) throws -> RecoveryProbeUSBDevice? {
        guard original.locationID != 0, (original.registryEntryID ?? 0) > 0 else {
            throw RecoveryProbeError.refused("Recovery USB attachment identity is unknown.")
        }
        if devices.isEmpty { return nil }
        guard devices.count == 1, let device = devices.first, device.locationID == original.locationID,
              (device.registryEntryID ?? 0) > 0 else {
            throw RecoveryProbeError.refused("Console USB port or device count changed. No recovery connection was opened.")
        }
        if device == original { return nil }
        guard device.isRNDIS, device.deviceClass == 224 else {
            throw RecoveryProbeError.refused("Unexpected USB state after the boot request.")
        }
        return device
    }
    static func requireRAMScratch(_ observation: RecoveryProbeObservation) throws {
        var rootCount = 0
        for mount in observation.mounts {
            let fields = mount.split(separator:" ")
            guard fields.count == 6 else { throw RecoveryProbeError.refused("Recovery mount table changed or is malformed.") }
            let target = fields[1]
            if target == "/" {
                rootCount += 1
                let options = fields[3].split(separator:",")
                guard fields[0] == "rootfs", fields[2] == "rootfs",
                      options.contains("rw"), !options.contains("ro") else {
                    throw RecoveryProbeError.refused("Temporary recovery root is not RAM-backed rootfs.")
                }
            }
            guard target != "/tmp", !target.hasPrefix("/tmp/") else {
                throw RecoveryProbeError.refused("Temporary recovery directory is overmounted; no NAND query was started.")
            }
        }
        guard rootCount == 1 else { throw RecoveryProbeError.refused("Temporary recovery root mount is ambiguous.") }
    }
    static func observation(_ text: String) throws -> RecoveryProbeObservation {
        func refuse(_ reason: String) -> RecoveryProbeError { .refused("Recovery observation refused: " + reason) }
        guard text.utf8.count <= 65536, text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else {
            throw refuse("oversized or non-ASCII output")
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.first == "SWIFTHAKCHI_RAM_PROBE_V1", lines.last == "END",
              lines.count >= 12, lines[8] == "MOUNTS_BEGIN", lines[lines.count - 2] == "MOUNTS_END" else {
            throw refuse("incomplete or unexpected markers")
        }
        var fields: [String: String] = [:]
        for line in lines[1..<8] {
            guard let separator = line.firstIndex(of: "=") else { throw refuse("missing field separator") }
            let key = String(line[..<separator]), value = String(line[line.index(after: separator)...])
            guard fields[key] == nil, !value.isEmpty else { throw refuse("duplicate or empty field") }
            fields[key] = value
        }
        guard Set(fields.keys) == Set(["KERNEL","CMDLINE","INIT_SHA","BASE_SHA","BOARD","NES_DIRECTORY","HWID"]),
              fields["KERNEL"] == "3.4.113.29-madmonkey",
              fields["INIT_SHA"] == "ede443827300aff46995b97bb73c221aba2a1e9a38c710160a2fa28fdaec45b0",
              fields["BASE_SHA"] == "14a1dd7e3dae28339312fc379087c3e37119ce5684286e09a521f8cda318ae62",
              fields["NES_DIRECTORY"] == "1", let board = fields["BOARD"], board.count <= 64,
              let hwid = fields["HWID"], hwid.count == 32, hwid.allSatisfy({ $0.isHexDigit }),
              hwid.contains(where: { $0 != "0" }) else { throw refuse("build, NES root or HWID did not match") }
        let flags = fields["CMDLINE", default: ""].split(separator: " ").filter { $0.contains("hakchi-") }.map(String.init).sorted()
        guard flags == ["hakchi-memboot", "hakchi-shell"] else { throw refuse("unexpected recovery flags") }
        let mounts = Array(lines[9..<(lines.count - 2)])
        var readOnlyRoot = false
        for mount in mounts {
            let columns = mount.split(separator: " ")
            guard columns.count == 6 else { throw refuse("malformed mount entry") }
            let device = String(columns[0]), target = String(columns[1]), options = columns[3].split(separator: ",")
            let ro = options.contains("ro") && !options.contains("rw")
            if target == "/newroot" {
                guard columns[2] == "squashfs", ro else { throw refuse("root image is not read-only squashfs") }
                readOnlyRoot = true
            }
            guard target != "/var/lib", !target.hasPrefix("/var/lib/"),
                  target != "/newroot/var/lib", !target.hasPrefix("/newroot/var/lib/") else {
                throw refuse("persistent library storage is mounted")
            }
            if device.hasPrefix("/dev/nand") || device.hasPrefix("/dev/mapper/") {
                guard ro else { throw refuse("writable persistent device is mounted") }
            }
        }
        guard readOnlyRoot else { throw refuse("no read-only original root mount") }
        return RecoveryProbeObservation(kernel: fields["KERNEL"]!, board: board, hwid: hwid.lowercased(), mounts: mounts)
    }
}

actor RecoveryRAMProbe {
    private let session: RecoverySessionCoordinator
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        session = RecoverySessionCoordinator(wait: wait)
    }
    func run(inputs: RecoveryBootInputs, io: any RecoveryProbeIO, pollLimit: Int = 60, captureBoot2: Bool = false,
             captureInstallEvidence: Bool = false, captureDataLayout: Bool = false, capturePersistentInventory: Bool = false,
             progress: @escaping RecoveryProgressSink = { _ in }) async throws -> RecoveryRAMProbeReport {
        let (context, captured) = try await session.run(inputs: inputs, io: io, pollLimit: pollLimit, progress:progress) { context in
            let observation = context.observation
            var snapshot: RecoveryBootSnapshot?
            var boot1: RecoveryBoot1Snapshot?
            var dataHeader: RecoveryDataSuperblock?
            var persistentInventory: RecoveryPersistentInventory?
            var partitionSHA256: String?
            if captureBoot2 || captureInstallEvidence || captureDataLayout || capturePersistentInventory {
                guard observation.board == "dp-nes" else { throw RecoveryProbeError.refused("Read-only evidence currently supports only the Western NES board dp-nes.") }
                try Task.checkCancellation()
                let beforeRead = try RecoveryProbePolicy.observation(await io.observe())
                guard beforeRead.hwid == observation.hwid, beforeRead.board == observation.board else {
                    throw RecoveryProbeError.refused("Recovery identity changed before evidence reads.")
                }
                if captureBoot2 || captureInstallEvidence {
                    try Task.checkCancellation()
                    await progress(.readingCurrentKernel)
                    let active = try await io.readBoot2(.active)
                    try Task.checkCancellation()
                    let backup = try await io.readBoot2(.backup)
                    try Task.checkCancellation()
                    snapshot = try RecoveryBootSnapshot(active: active, backup: backup)
                    if captureInstallEvidence {
                        try Task.checkCancellation()
                        await progress(.readingBootloader)
                        boot1 = try RecoveryBoot1Snapshot(await io.readBoot1())
                    }
                }
                if captureDataLayout || capturePersistentInventory {
                    try RecoveryProbePolicy.requireRAMScratch(beforeRead)
                    try Task.checkCancellation()
                    let partitions = try await io.readPartitions()
                    guard let text = String(data:partitions,encoding:.ascii) else {
                        throw RecoveryProbeError.refused("Partition evidence was not ASCII.")
                    }
                    let sectors = try StockRestorePartitions.dataSectors(text)
                    partitionSHA256 = BackupManifest.digest(partitions)
                    try Task.checkCancellation()
                    dataHeader = try RecoveryDataSuperblock.parse(await io.readDataSuperblock(),partitionSectors:sectors)
                    if capturePersistentInventory {
                        guard dataHeader?.isClean == true else {
                            throw RecoveryProbeError.refused("Data ext4 filesystem is unclean or needs journal recovery. No persistent files were mounted or accepted.")
                        }
                        try Task.checkCancellation()
                        persistentInventory = try RecoveryPersistentInventory.parse(await io.readPersistentInventory())
                    }
                }
                await progress(.verifying)
                let afterRead = try RecoveryProbePolicy.observation(await io.observe())
                try Task.checkCancellation()
                guard afterRead.hwid == observation.hwid, afterRead.board == observation.board else {
                    throw RecoveryProbeError.refused("Recovery identity changed after evidence reads. No complete inventory was accepted.")
                }
                if capturePersistentInventory {
                    guard afterRead.mounts == beforeRead.mounts else {
                        throw RecoveryProbeError.refused("Recovery mounts changed during persistent inventory. No file evidence was accepted.")
                    }
                }
            }
            return (snapshot, boot1, dataHeader, partitionSHA256, persistentInventory)
        }
        return RecoveryRAMProbeReport(before: context.before, after: context.after, observation: context.observation,
            bootSnapshot: captured.0, boot1Snapshot: captured.1, dataSuperblock: captured.2,
            persistentInventory: captured.4, partitionSHA256: captured.3)
    }
}

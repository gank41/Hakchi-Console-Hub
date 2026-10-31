import Foundation
import USBBridge
import SwiftHakchiCore

struct SNESRAMProbeExpectation: Sendable {
    let binding: SNESRuntimeBinding, nonce: String, hashes: [String: String]
    static let labels = Set(["INIT_SHA", "REPORT_SHA", "LOADER_SHA", "LIBC_SHA", "DAEMON_SHA", "BUSYBOX_SHA"])
    func validate() throws {
        try binding.validate()
        guard UUID(uuidString: nonce)?.uuidString == nonce, Set(hashes.keys) == Self.labels,
              hashes.values.allSatisfy({ $0.count == 64 && SNESRuntimeBinding.hex($0) }) else { throw SNESRuntimeBinding.failure() }
    }
}
extension PreparedSNESRAMProbe {
    var expectation: SNESRAMProbeExpectation { .init(binding: binding, nonce: nonce, hashes: hashes) }
}
enum SNESRAMProbeUSBPolicy {
    static let product = "Swift Hakchi SNES RAM Probe"
    static func nativeIdentity(_ device: RecoveryProbeUSBDevice) throws -> hakchi_usb_identity_t {
        guard device.vendorID == 0x1f3a, device.productID == 0xefe8, device.deviceVersion == 0x6a01,
              device.deviceClass == 0, device.product == product, device.locationID != 0,
              let entry = device.registryEntryID, entry > 0 else { throw SNESRuntimeBinding.failure() }
        return hakchi_usb_identity_t(registry_entry_id: entry, location_id: device.locationID, vendor_id: device.vendorID,
            product_id: device.productID, device_version: device.deviceVersion, device_class: device.deviceClass, require_empty_product: false)
    }
    static func after(_ devices: [RecoveryProbeUSBDevice], original: RecoveryProbeUSBDevice) throws -> RecoveryProbeUSBDevice? {
        _ = try RecoveryProbePolicy.before([original])
        if devices.isEmpty || devices == [original] { return nil }
        guard devices.count == 1, let device = devices.first, device.locationID == original.locationID,
              device.registryEntryID != original.registryEntryID else { throw SNESRuntimeBinding.failure() }
        _ = try nativeIdentity(device); return device
    }
}
struct SNESRAMProbeReport: Sendable {
    let raw: Data
    init(_ bytes: Data, expected: SNESRAMProbeExpectation) throws {
        try expected.validate()
        guard bytes.count <= 65536, bytes.allSatisfy({ $0 == 10 || (32...126).contains($0) }),
              let text = String(data: bytes, encoding: .ascii), text.hasSuffix("\n") else { throw SNESRuntimeBinding.failure() }
        let lines = Array(text.dropLast().components(separatedBy: "\n"))
        guard lines.count >= 18, lines.first == "SWIFTHAKCHI_SNES_RAM_REPORT_V1", lines.last == "END",
              let begin = lines.firstIndex(of: "MOUNTS_BEGIN"), begin == 13,
              lines[lines.count-2] == "MOUNTS_END" else { throw SNESRuntimeBinding.failure() }
        var fields: [String: String] = [:]
        for line in lines[1..<begin] {
            guard let equal = line.firstIndex(of: "=") else { throw SNESRuntimeBinding.failure() }
            let name = String(line[..<equal]), value = String(line[line.index(after: equal)...])
            guard fields[name] == nil else { throw SNESRuntimeBinding.failure() }; fields[name] = value
        }
        guard Set(fields.keys) == SNESRAMProbeExpectation.labels.union(["NONCE", "KERNEL", "BOARD", "REGION", "HWID", "STATUS"]),
              fields["NONCE"] == expected.nonce, fields["KERNEL"] == "3.4.112.madmonkey",
              fields["BOARD"] == "dp-shvc", fields["REGION"] == "USA", fields["HWID"] == expected.binding.expectedHWID,
              fields["STATUS"] == "ready", expected.hashes.allSatisfy({ fields[$0.key] == $0.value }) else { throw SNESRuntimeBinding.failure() }
        var targets: Set<String> = []
        for line in lines[(begin+1)..<(lines.count-2)] {
            let f = line.split(separator: " ")
            guard f.count == 6, targets.insert(String(f[1])).inserted else { throw SNESRuntimeBinding.failure() }
            switch f[1] {
            case "/": guard f[0] == "rootfs", f[2] == "rootfs", f[3].split(separator: ",").contains("rw") else { throw SNESRuntimeBinding.failure() }
            case "/dev": guard f[2] == "devtmpfs" else { throw SNESRuntimeBinding.failure() }
            case "/proc": guard f[2] == "proc" else { throw SNESRuntimeBinding.failure() }
            case "/sys": guard f[2] == "sysfs" else { throw SNESRuntimeBinding.failure() }
            case "/newroot":
                guard ["/dev/mapper/swifthakchi-probe-root", "/dev/dm-0"].contains(String(f[0])), f[2] == "squashfs",
                      f[3].split(separator: ",").contains("ro"), !f[3].split(separator: ",").contains("rw") else { throw SNESRuntimeBinding.failure() }
            default: throw SNESRuntimeBinding.failure()
            }
        }
        guard targets == ["/", "/dev", "/proc", "/sys", "/newroot"] else { throw SNESRuntimeBinding.failure() }
        raw = bytes
    }
}
protocol SNESRAMProbeIO: Sendable {
    func inventory() async throws -> [RecoveryProbeUSBDevice]
    func boot(expected: RecoveryProbeUSBDevice) async throws
    func connect(expected: RecoveryProbeUSBDevice) async throws
    func report() async throws -> Data
    func disconnect() async
}
struct SNESRAMProbeResult: Sendable {
    let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice
    let report: SNESRAMProbeReport
    let expectation: SNESRAMProbeExpectation
}
actor SNESRAMProbeService {
    private let wait: @Sendable () async throws -> Void
    private var busy = false
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) { self.wait = wait }
    func run(expected: SNESRAMProbeExpectation, io: any SNESRAMProbeIO,
             progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESRAMProbeResult {
        guard !busy else { throw SNESRuntimeBinding.failure() }; busy = true; defer { busy = false }
        do {
            try Task.checkCancellation(); try expected.validate(); await progress(.checkingUSB)
            let before = try RecoveryProbePolicy.before(await io.inventory())
            try Task.checkCancellation(); await progress(.uploadingRecovery)
            try await io.boot(expected: before) // One request only, including uncertain execution failures.
            await progress(.waitingForRecovery)
            var after: RecoveryProbeUSBDevice?
            for _ in 0..<60 {
                try Task.checkCancellation()
                after = try SNESRAMProbeUSBPolicy.after(await io.inventory(), original: before)
                if after != nil { break }; try await wait()
            }
            guard let after, try SNESRAMProbeUSBPolicy.after(await io.inventory(), original: before) == after else { throw SNESRuntimeBinding.failure() }
            try Task.checkCancellation(); try await io.connect(expected: after); await progress(.checkingIdentity)
            let bytes = try await io.report(); let report = try SNESRAMProbeReport(bytes, expected: expected)
            try Task.checkCancellation()
            guard try await io.report() == bytes else { throw SNESRuntimeBinding.failure() }
            try Task.checkCancellation(); await progress(.closing); await io.disconnect()
            return SNESRAMProbeResult(before: before, after: after, report: report, expectation: expected)
        } catch { await io.disconnect(); throw error }
    }
}

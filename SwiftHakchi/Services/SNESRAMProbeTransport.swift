import Foundation
import USBBridge

/// New probe path only. Existing NES transport defaults remain unchanged.
actor SNESRAMProbeUSBTransport: LegacyUSBTransport {
    private let expected: RecoveryProbeUSBDevice
    private var device: OpaquePointer?
    init(expected: RecoveryProbeUSBDevice) { self.expected = expected }
    func open() throws {
        try Task.checkCancellation(); guard device == nil else { throw LegacyInspectionError.busy }
        var identity = try SNESRAMProbeUSBPolicy.nativeIdentity(expected), error = HAKCHI_USB_OK
        let opened = SNESRAMProbeUSBPolicy.product.withCString { hakchi_usb_open_passive_bound(&identity, $0, &error) }
        guard let opened else { throw LegacyInspectionError.usb(Int(error.rawValue)) }
        device = opened
    }
    func packetSize() throws -> Int { guard let device else { throw LegacyInspectionError.disconnected }; return Int(hakchi_usb_get_packet_size_in(device)) }
    func close() { if let device { hakchi_usb_close(device) }; device = nil }
    func write(_ bytes: Data, timeoutMilliseconds: Int) throws {
        guard let device, (1...65539).contains(bytes.count), timeoutMilliseconds > 0 else { throw LegacyInspectionError.invalidResponse }
        let count = bytes.withUnsafeBytes { hakchi_usb_bulk_write(device, 1, $0.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count), Int32(timeoutMilliseconds)) }
        guard count == bytes.count else { throw LegacyInspectionError.usb(Int(count)) }
    }
    func read(maximumBytes: Int, timeoutMilliseconds: Int) throws -> Data {
        guard let device, (1...65540).contains(maximumBytes), timeoutMilliseconds > 0 else { throw LegacyInspectionError.invalidResponse }
        var bytes = Data(count: maximumBytes)
        let count = bytes.withUnsafeMutableBytes { hakchi_usb_bulk_read(device, 0x81, $0.bindMemory(to: UInt8.self).baseAddress, Int32(maximumBytes), Int32(timeoutMilliseconds)) }
        if count == HAKCHI_USB_ERROR_TIMEOUT.rawValue { return Data() }
        guard count >= 0, count <= maximumBytes else { throw LegacyInspectionError.usb(Int(count)) }
        bytes.count = Int(count); return bytes
    }
}
actor NativeSNESRAMProbeIO: SNESRAMProbeIO {
    private let probe: PreparedSNESRAMProbe
    private var client: LegacyInspectionClient?
    init(probe: PreparedSNESRAMProbe) { self.probe = probe }
    func inventory() throws -> [RecoveryProbeUSBDevice] { try Task.checkCancellation(); return try RecoveryProbeUSBRegistry.inventory() }
    func boot(expected: RecoveryProbeUSBDevice) async throws {
        try probe.validateCurrent()
        let fel = FELService(makeSession: { IOKitFELSessionTransport(expected: expected) })
        try await fel.memboot(probe: probe, progress: { status, _ in print(status) })
    }
    func connect(expected: RecoveryProbeUSBDevice) async throws {
        _ = try SNESRAMProbeUSBPolicy.nativeIdentity(expected)
        let next = LegacyInspectionClient(transport: SNESRAMProbeUSBTransport(expected: expected), maximumOutputBytes: 65536)
        client = next; try await next.connect(timeoutMilliseconds: 10_000)
    }
    func report() async throws -> Data {
        guard let client else { throw LegacyInspectionError.disconnected }
        let result = try await client.execute(.snesRAMProbeReport, timeoutMilliseconds: 15_000)
        guard result.succeeded, result.stdoutData.count <= 65536 else { throw SNESRuntimeBinding.failure() }
        return result.stdoutData
    }
    func disconnect() async { await client?.disconnect(); client = nil }
}

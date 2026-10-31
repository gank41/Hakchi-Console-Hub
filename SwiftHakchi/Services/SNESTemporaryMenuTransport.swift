import Foundation
import USBBridge

actor SNESTemporaryMenuUSBTransport: LegacyUSBTransport {
    private let expected: RecoveryProbeUSBDevice
    private var device: OpaquePointer?
    init(expected: RecoveryProbeUSBDevice) { self.expected = expected }
    func open() throws {
        try Task.checkCancellation(); guard device == nil else { throw LegacyInspectionError.busy }
        var identity = try SNESTemporaryMenuUSBPolicy.nativeIdentity(expected), error = HAKCHI_USB_OK
        let opened = SNESTemporaryMenuUSBPolicy.product.withCString { hakchi_usb_open_passive_bound(&identity, $0, &error) }
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
struct SNESTemporaryMenuReadFailure: Error, Sendable { let received: Data; let details: Data }
actor NativeSNESTemporaryMenuIO: SNESTemporaryMenuIO {
    private let menu: PreparedSNESTemporaryMenu
    private var client: LegacyInspectionClient?
    init(menu: PreparedSNESTemporaryMenu) { self.menu = menu }
    func inventory() throws -> [RecoveryProbeUSBDevice] { try Task.checkCancellation(); return try RecoveryProbeUSBRegistry.inventory() }
    func boot(expected: RecoveryProbeUSBDevice) async throws {
        try menu.validateCurrent()
        let fel = FELService(makeSession: { IOKitFELSessionTransport(expected: expected) })
        try await fel.memboot(menu: menu, progress: { status, _ in print(status) })
    }
    func connect(expected: RecoveryProbeUSBDevice) async throws {
        try menu.validateCurrent(); _ = try SNESTemporaryMenuUSBPolicy.nativeIdentity(expected)
        let next = LegacyInspectionClient(transport: SNESTemporaryMenuUSBTransport(expected: expected), maximumOutputBytes: 65536, retainIncompleteOutput: true)
        client = next; try await next.connect(timeoutMilliseconds: 10_000)
    }
    func startReport(challenge: UUID) async throws -> Data { try await readReport(challenge: challenge, starting: true) }
    func report(challenge: UUID) async throws -> Data { try await readReport(challenge: challenge, starting: false) }
    private func readReport(challenge: UUID, starting: Bool) async throws -> Data {
        try menu.validateCurrent()
        guard let client else { throw LegacyInspectionError.disconnected }
        let result: SSHResult
        do {
            if starting { result = try await client.startTemporarySNESMenu(.init(menu: menu, challenge: challenge), timeoutMilliseconds: 180_000) }
            else { result = try await client.execute(.snesTemporaryMenuReport(challenge: challenge), timeoutMilliseconds: 120_000) }
        }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let partial = await client.incompleteOutput()
            throw SNESTemporaryMenuReadFailure(received: partial.stdout, details: partial.stderr)
        }
        guard result.succeeded, result.stdoutData.count <= 65536 else {
            throw SNESTemporaryMenuReadFailure(received: Data(result.stdoutData.prefix(65536)), details: Data(result.stderr.utf8.prefix(65536)))
        }
        return result.stdoutData
    }
    func diagnostics() async throws -> Data {
        guard let client else { throw LegacyInspectionError.disconnected }
        let result = try await client.execute(.snesTemporaryMenuDiagnostics, timeoutMilliseconds: 10_000)
        return Data(result.stdoutData.prefix(65536))
    }
    func disconnect() async { await client?.disconnect(); client = nil }
}

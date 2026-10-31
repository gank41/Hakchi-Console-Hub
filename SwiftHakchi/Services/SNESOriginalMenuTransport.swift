import Foundation
import USBBridge

actor SNESOriginalMenuUSBTransport: LegacyUSBTransport {
    private let expected: RecoveryProbeUSBDevice
    private var device: OpaquePointer?
    init(expected: RecoveryProbeUSBDevice) { self.expected = expected }
    func open() throws {
        try Task.checkCancellation(); guard device == nil else { throw LegacyInspectionError.busy }
        var identity = try SNESOriginalMenuUSBPolicy.nativeIdentity(expected), error = HAKCHI_USB_OK
        let opened = SNESOriginalMenuUSBPolicy.product.withCString { hakchi_usb_open_passive_bound(&identity, $0, &error) }
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
actor NativeSNESOriginalMenuIO: SNESOriginalMenuIO {
    private let menu: PreparedSNESOriginalMenu
    private var client: LegacyInspectionClient?
    private var receivedStderr=Data()
    init(menu: PreparedSNESOriginalMenu) { self.menu = menu }
    func inventory() throws -> [RecoveryProbeUSBDevice] { try Task.checkCancellation(); return try RecoveryProbeUSBRegistry.inventory() }
    func boot(expected: RecoveryProbeUSBDevice) async throws {
        try menu.validateCurrent()
        let fel = FELService(makeSession: { IOKitFELSessionTransport(expected: expected) })
        try await fel.memboot(originalMenu: menu, progress: { status, _ in print(status) })
    }
    func connect(expected: RecoveryProbeUSBDevice) async throws {
        try menu.validateCurrent(); _ = try SNESOriginalMenuUSBPolicy.nativeIdentity(expected)
        let next = LegacyInspectionClient(transport: SNESOriginalMenuUSBTransport(expected: expected), maximumOutputBytes: 65536, retainIncompleteOutput: true)
        client = next; try await next.connect(timeoutMilliseconds: 10_000)
    }
    private func perform(_ body: @Sendable (LegacyInspectionClient) async throws -> SSHResult) async throws -> Data {
        try Task.checkCancellation(); try menu.validateCurrent()
        guard let client else { throw LegacyInspectionError.disconnected }
        let result: SSHResult
        do { result = try await body(client) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let partial = await client.incompleteOutput()
            throw SNESOriginalMenuReadFailure(received: partial.stdout, details: Data((receivedStderr+partial.stderr).prefix(8192)))
        }
        receivedStderr=Data((receivedStderr+Data(result.stderr.utf8)).prefix(8192))
        guard result.succeeded, result.stdoutData.count <= 65536 else {
            throw SNESOriginalMenuReadFailure(received: Data(result.stdoutData.prefix(65536)), details: receivedStderr)
        }
        return result.stdoutData
    }
    func checkpoint(challenge: UUID) async throws -> Data {
        let menu = menu
        return try await perform { try await $0.checkpointOriginalSNESMenu(menu, challenge: challenge) }
    }
    func launch(_ request: SNESOriginalMenuLaunchRequest) async throws {
        try request.validateCurrent()
        let acknowledgement = try await perform { try await $0.launchOriginalSNESMenu(request) }
        guard acknowledgement == request.acknowledgement else { throw SNESOriginalMenuReadFailure(received: acknowledgement, details: Data()) }
    }
    func report(challenge: UUID) async throws -> Data {
        try await perform { try await $0.execute(.snesOriginalMenuReport(challenge: challenge), timeoutMilliseconds: 120_000) }
    }
    func diagnostics() async throws -> Data {
        let raw=try await perform { try await $0.execute(.snesOriginalMenuDiagnostics, timeoutMilliseconds: 10_000) }
        _=try SNESOriginalMenuDiagnostics(raw,nonce:menu.nonce)
        return try SNESOriginalMenuDiagnostics.appendingStderr(receivedStderr,to:raw,nonce:menu.nonce)
    }
    func disconnect() async { await client?.disconnect(); client = nil }
}

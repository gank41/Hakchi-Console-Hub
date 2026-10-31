import Foundation
import USBBridge

actor SNESStartupTrialUSBTransport: LegacyUSBTransport {
    private let expected: RecoveryProbeUSBDevice
    private var device: OpaquePointer?
    init(expected: RecoveryProbeUSBDevice) { self.expected = expected }
    func open() throws {
        try Task.checkCancellation(); guard device == nil else { throw LegacyInspectionError.busy }
        var identity = try SNESStartupTrialUSBPolicy.nativeIdentity(expected), error = HAKCHI_USB_OK
        let opened = SNESStartupTrialUSBPolicy.product.withCString { hakchi_usb_open_passive_bound(&identity, $0, &error) }
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
actor NativeSNESStartupTrialIO:SNESStartupTrialIO {
    private let trial:PreparedSNESStartupTrial
    private var client:LegacyInspectionClient?
    init(trial:PreparedSNESStartupTrial){self.trial=trial}
    func inventory()throws->[RecoveryProbeUSBDevice] {try Task.checkCancellation();return try RecoveryProbeUSBRegistry.inventory()}
    func boot(expected:RecoveryProbeUSBDevice) async throws {
        try trial.validateCurrent()
        let fel=FELService(makeSession:{IOKitFELSessionTransport(expected:expected)})
        try await fel.memboot(startupTrial:trial,progress:{status,_ in print(status)})
    }
    func connect(expected:RecoveryProbeUSBDevice) async throws {
        try trial.validateCurrent();_=try SNESStartupTrialUSBPolicy.nativeIdentity(expected)
        guard expected.deviceVersion == (try SNESStartupTrialExpectation.checked(trial).deviceVersion) else {throw SNESRuntimeBinding.failure()}
        let next=LegacyInspectionClient(transport:SNESStartupTrialUSBTransport(expected:expected),maximumOutputBytes:16384,retainIncompleteOutput:true)
        client=next;try await next.connect(timeoutMilliseconds:10000)
    }
    func report(challenge:UUID) async throws -> Data {
        try trial.validateCurrent();guard let client else {throw LegacyInspectionError.disconnected}
        do {
            let result=try await client.readSNESStartupTrial(trial,challenge:challenge)
            try trial.validateCurrent()
            guard result.succeeded,result.stdoutData.count<=16384 else {throw SNESStartupTrialReadFailure(raw:Data(result.stdoutData.prefix(16384)))}
            return result.stdoutData
        } catch {
            if error is CancellationError || Task.isCancelled {throw CancellationError()}
            if let failure=error as? SNESStartupTrialReadFailure {throw failure}
            let partial=await client.incompleteOutput()
            throw SNESStartupTrialReadFailure(raw:Data(partial.stdout.prefix(16384)))
        }
    }
    func disconnect() async {await client?.disconnect();client=nil}
}

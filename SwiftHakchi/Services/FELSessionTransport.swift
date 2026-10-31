import Foundation
import USBBridge

/// One owned FEL handle per operation; tests inject actors without hardware access.
protocol FELSessionTransport: Sendable {
    func open() async throws
    func close() async
    func verifyBoard() async throws -> UInt32
    func initializeDRAM(fes1: Data) async throws
    func write(address: UInt32, data: Data) async throws
    func read(address: UInt32, count: Int) async throws -> Data
    func execute(address: UInt32) async throws
    func readHardwareIdentity() async throws -> Data
}

extension FELSessionTransport {
    func readHardwareIdentity() async throws -> Data {try await FELSIDReader.read(from:self)}
}

actor IOKitFELSessionTransport: FELSessionTransport {
    private var device: UnsafeMutablePointer<fel_device_t>?
    private let expected: RecoveryProbeUSBDevice?
    init(expected: RecoveryProbeUSBDevice? = nil) { self.expected = expected }

    func open() throws {
        try Task.checkCancellation()
        guard device == nil else { throw FELError.busy }
        let opened: UnsafeMutablePointer<fel_device_t>?
        if let expected {
            var identity = try expected.nativeIdentity(for: .fel)
            opened = fel_open_bound(&identity)
        } else { opened = fel_open() }
        guard let opened else { throw FELError.deviceNotFound }
        device = opened
    }
    func close() {
        if let device { fel_close(device) }
        device = nil
    }
    func verifyBoard() throws -> UInt32 {
        try Task.checkCancellation()
        guard let device else { throw FELError.deviceNotFound }
        var response = aw_fel_verify_response_t()
        let result = fel_verify_device(device, &response)
        guard result == 0 else { throw FELError.communicationError(result) }
        return response.board
    }
    func initializeDRAM(fes1: Data) throws {
        try Task.checkCancellation()
        guard let device else { throw FELError.deviceNotFound }
        guard fes1.count >= 128, fes1.count <= Int(FES1_MAX_SIZE) else { throw FELError.invalidTransfer }
        let result = fes1.withUnsafeBytes {
            fel_init_dram(device, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(fes1.count))
        }
        guard result == 0 else { throw FELError.dramInitFailed(result) }
    }
    func write(address: UInt32, data: Data) throws {
        try Task.checkCancellation()
        guard let device else { throw FELError.deviceNotFound }
        guard !data.isEmpty, data.count <= Int(FEL_MAX_TRANSFER_SIZE) else { throw FELError.invalidTransfer }
        let result = data.withUnsafeBytes {
            fel_write_memory(device, address, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count), nil, nil)
        }
        guard result == 0 else { throw FELError.writeError(result) }
    }
    func read(address: UInt32, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard let device else { throw FELError.deviceNotFound }
        guard count > 0, count <= Int(FEL_MAX_TRANSFER_SIZE) else { throw FELError.invalidTransfer }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes {
            fel_read_memory(device, address, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(count), nil, nil)
        }
        guard result == 0 else { throw FELError.readError(result) }
        return data
    }
    func execute(address: UInt32) throws {
        // Recheck after the cross-actor suspension, immediately before native execution.
        try Task.checkCancellation()
        guard let device else { throw FELError.deviceNotFound }
        let result = fel_exec(device, address)
        guard result == 0 else { throw FELError.execError(result) }
    }
}

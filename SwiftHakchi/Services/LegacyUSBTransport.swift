import Foundation
import USBBridge

protocol LegacyUSBTransport: Sendable {
    func open() async throws
    func packetSize() async throws -> Int
    func close() async
    func write(_ data: Data, timeoutMilliseconds: Int) async throws
    func read(maximumBytes: Int, timeoutMilliseconds: Int) async throws -> Data
}

/// Owns the pointer on one actor; bounded reads keep cancellation responsive.
actor IOKitLegacyUSBTransport: LegacyUSBTransport {
    private var device: OpaquePointer?
    func open() throws {
        guard device == nil else { throw LegacyInspectionError.busy }
        var error = HAKCHI_USB_OK
        guard let opened = hakchi_usb_open_passive(0x1f3a, 0xefe8, &error) else {
            throw LegacyInspectionError.usb(Int(error.rawValue))
        }
        device = opened
    }
    func packetSize() throws -> Int {
        guard let device else { throw LegacyInspectionError.disconnected }
        return Int(hakchi_usb_get_packet_size_in(device))
    }
    func close() {
        if let device { hakchi_usb_close(device) }
        device = nil
    }
    func write(_ data: Data, timeoutMilliseconds: Int) throws {
        guard let device else { throw LegacyInspectionError.disconnected }
        guard data.count <= 65539, timeoutMilliseconds > 0 else { throw LegacyInspectionError.invalidResponse }
        let written = data.withUnsafeBytes { bytes in
            hakchi_usb_bulk_write(device, 1, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(data.count), Int32(timeoutMilliseconds))
        }
        guard written == data.count else { throw LegacyInspectionError.usb(Int(written)) }
    }
    func read(maximumBytes: Int, timeoutMilliseconds: Int) throws -> Data {
        guard let device else { throw LegacyInspectionError.disconnected }
        guard maximumBytes > 0, maximumBytes <= 65540, timeoutMilliseconds > 0 else { throw LegacyInspectionError.invalidResponse }
        var data = Data(count: maximumBytes)
        let count = data.withUnsafeMutableBytes { bytes in
            hakchi_usb_bulk_read(device, 0x81, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(maximumBytes), Int32(timeoutMilliseconds))
        }
        if count == HAKCHI_USB_ERROR_TIMEOUT.rawValue { return Data() }
        guard count >= 0, count <= maximumBytes else { throw LegacyInspectionError.usb(Int(count)) }
        data.count = Int(count)
        return data
    }
}

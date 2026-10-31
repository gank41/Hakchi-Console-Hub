import Foundation

public enum ClovershellFrameError: Error { case invalidSize }

public struct ClovershellFrame: Equatable, Sendable {
    public let command: UInt8
    public let connectionID: UInt8
    public let payload: Data
    public init(command: UInt8, connectionID: UInt8, payload: Data) {
        self.command = command; self.connectionID = connectionID; self.payload = payload
    }
    public func encoded() throws -> Data {
        guard payload.count <= 65535 else { throw ClovershellFrameError.invalidSize }
        return Data([command, connectionID, UInt8(payload.count & 255), UInt8(payload.count >> 8)]) + payload
    }
}

/// USB transfers can contain part of a frame, one frame, or several frames.
public struct ClovershellFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func feed(_ bytes: Data) throws -> [ClovershellFrame] {
        guard bytes.count <= 65540, buffer.count + bytes.count <= 131080 else { throw ClovershellFrameError.invalidSize }
        buffer.append(contentsOf: bytes)
        var offset = 0
        var frames: [ClovershellFrame] = []
        while buffer.count - offset >= 4 {
            let length = Int(buffer[offset + 2]) | (Int(buffer[offset + 3]) << 8)
            guard buffer.count - offset >= length + 4 else { break }
            frames.append(ClovershellFrame(command: buffer[offset], connectionID: buffer[offset + 1], payload: Data(buffer[(offset + 4)..<(offset + 4 + length)])))
            offset += length + 4
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return frames
    }
}

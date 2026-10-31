import Foundation

/// Cartridge identity only. Parsing does not certify a dump or its emulator compatibility.
struct NESROMIdentity: Sendable {
    let content: Range<Int>
    let trainerBytes: Int
    let trailingBytes: Int
    let mapper: Int

    enum ParseError: Error { case invalidHeader, unsupportedNES2, emptyProgram, truncated }

    init(data: Data) throws {
        guard data.count >= 16, Array(data.prefix(4)) == [78, 69, 83, 26] else { throw ParseError.invalidHeader }
        // NES 2.0 has different size and mapper encodings; do not guess its identity.
        guard data[7] & 0x0C != 0x08 else { throw ParseError.unsupportedNES2 }
        guard data[4] > 0 else { throw ParseError.emptyProgram }
        trainerBytes = data[6] & 4 == 0 ? 0 : 512
        let start = 16 + trainerBytes
        let length = Int(data[4]) * 16_384 + Int(data[5]) * 8_192
        guard start + length <= data.count else { throw ParseError.truncated }
        content = start..<(start + length)
        trailingBytes = data.count - content.upperBound
        // Old DiskDude headers misuse byte 7; expose, but do not repair, those bytes.
        mapper = Int(data[6] >> 4) | Int(data[7] & 0xF0)
    }
}

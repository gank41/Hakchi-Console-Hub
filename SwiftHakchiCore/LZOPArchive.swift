import Foundation
import NativeLZO

/// Bounded LZO1X container codec. Filenames are metadata only; nothing is extracted.
public enum LZOPArchive {
    public static let maximumSize = 16 * 1024 * 1024
    private static let blockSize = 256 * 1024
    private static let magic: [UInt8] = [0x89, 0x4c, 0x5a, 0x4f, 0, 13, 10, 26, 10]
    private static func failure() -> RecoveryImageError { .invalid("The startup archive is damaged or uses an unsupported compression format.") }

    public static func decode(_ data: Data) throws -> Data {
        guard data.count <= maximumSize else { throw failure() }
        var reader = BootByteReader(data)
        guard try reader.take(9) == magic else { throw failure() }
        let headerStart = reader.position
        let version = try reader.number(2)
        _ = try reader.number(2) // Encoder library version, not used for dispatch.
        let needed = try reader.number(2), method = try reader.number(1)
        guard (0x0940...0x1030).contains(version), needed <= 0x1030,
              (1...3).contains(method) else { throw failure() }
        let level = try reader.number(1)
        let flags = try reader.number(4)
        guard level <= 9, flags & ~UInt32(0x0300131f) == 0,
              [UInt32(0), 3].contains(flags >> 24), flags & 0x101 != 0 else { throw failure() }
        _ = try reader.take(12) // Mode, time and GMT fields; never applied on the Mac.
        let nameLength = try reader.number(1)
        _ = try reader.take(Int(nameLength))
        let header = Array(reader.bytes[headerStart..<reader.position])
        guard try reader.number(4) == checksum(header, crc: flags & 0x1000 != 0) else { throw failure() }
        var output = Data(), blocks = 0
        while true {
            let decodedSize = Int(try reader.number(4))
            if decodedSize == 0 { break }
            blocks += 1
            guard blocks <= 256, decodedSize <= blockSize, decodedSize <= maximumSize - output.count else { throw failure() }
            let storedSize = Int(try reader.number(4))
            guard storedSize > 0, storedSize <= decodedSize else { throw failure() }
            var decodedChecks: [(Bool, UInt32)] = [], storedChecks: [(Bool, UInt32)] = []
            for (mask, crc) in [(UInt32(1), false), (0x100, true)] where flags & mask != 0 {
                decodedChecks.append((crc, try reader.number(4)))
            }
            if storedSize < decodedSize {
                for (mask, crc) in [(UInt32(2), false), (0x200, true)] where flags & mask != 0 {
                    storedChecks.append((crc, try reader.number(4)))
                }
            }
            let raw = try reader.take(storedSize)
            for (crc, expected) in storedChecks where checksum(raw, crc: crc) != expected { throw failure() }
            let decoded: [UInt8]
            if storedSize == decodedSize { decoded = raw }
            else {
                var buffer = [UInt8](repeating: 0, count: decodedSize)
                let status = raw.withUnsafeBufferPointer { source in
                    buffer.withUnsafeMutableBufferPointer { target in
                        swift_hakchi_lzo_decode(source.baseAddress, raw.count, target.baseAddress, decodedSize)
                    }
                }
                guard status == 0 else { throw failure() }
                decoded = buffer
            }
            for (crc, expected) in decodedChecks where checksum(decoded, crc: crc) != expected { throw failure() }
            output.append(contentsOf: decoded)
        }
        guard reader.position == reader.bytes.count else { throw failure() }
        return output
    }

    public static func compress(_ data:Data) throws -> Data {
        guard data.count <= maximumSize else {throw failure()}
        // LZOP 1.03, LZO 2.10, method 3 (LZO1X-999), level 8, Adler32.
        var header:[UInt8]=[0x10,0x30,0x20,0xa0,0x09,0x40,3,8]
        header += bigEndian(1) + [UInt8](repeating:0,count:13)
        var result=magic + header + bigEndian(checksum(header,crc:false))
        let bytes=Array(data)
        for start in stride(from:0,to:bytes.count,by:blockSize) {
            try Task.checkCancellation()
            let block=Array(bytes[start..<min(start+blockSize,bytes.count)])
            var encoded=[UInt8](repeating:0,count:block.count+block.count/16+64+3),written=0
            let capacity=encoded.count
            let status=block.withUnsafeBufferPointer { source in
                encoded.withUnsafeMutableBufferPointer { target in
                    swift_hakchi_lzo_encode(source.baseAddress,block.count,target.baseAddress,capacity,&written)
                }
            }
            guard status==0,written>0,written<=capacity else {throw failure()}
            let packed=written<block.count ? Array(encoded.prefix(written)):block
            guard result.count<=maximumSize-12-packed.count else {throw failure()}
            result += bigEndian(UInt32(block.count)) + bigEndian(UInt32(packed.count))
            result += bigEndian(checksum(block,crc:false)) + packed
        }
        guard result.count<=maximumSize-4 else {throw failure()}
        result += [0,0,0,0]
        return Data(result)
    }

    public static func store(_ data: Data) throws -> Data {
        guard data.count <= maximumSize else { throw failure() }
        // LZOP 1.03, LZO 2.10, method 1, level 1, Adler32 of decoded blocks.
        var header: [UInt8] = [0x10, 0x30, 0x20, 0xa0, 0x09, 0x40, 1, 1]
        header += bigEndian(1) + [UInt8](repeating: 0, count: 13)
        var result = magic + header + bigEndian(checksum(header, crc: false))
        let bytes = Array(data)
        for start in stride(from: 0, to: bytes.count, by: blockSize) {
            let block = Array(bytes[start..<min(start + blockSize, bytes.count)])
            result += bigEndian(UInt32(block.count)) + bigEndian(UInt32(block.count))
            result += bigEndian(checksum(block, crc: false)) + block
        }
        result += [0, 0, 0, 0]
        guard result.count <= maximumSize else { throw failure() }
        return Data(result)
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }
    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func checksum(_ bytes: [UInt8], crc: Bool) -> UInt32 {
        if crc {
            var value: UInt32 = 0xffffffff
            for byte in bytes { value = crcTable[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
            return value ^ 0xffffffff
        }
        return bytes.withUnsafeBufferPointer { buffer in
            swift_hakchi_lzo_adler32(buffer.baseAddress, buffer.count)
        }
    }
}

/// A bounded cursor shared by the file-only codecs. No untrusted value becomes an allocation before checking.
struct BootByteReader {
    let bytes: [UInt8]
    var position = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - position else { throw RecoveryImageError.invalid("The startup file is truncated.") }
        let range = position..<(position + count); position += count
        return Array(bytes[range])
    }
    mutating func number(_ count: Int) throws -> UInt32 {
        try take(count).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

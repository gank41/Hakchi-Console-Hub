import Foundation
import Compression

/// The single-block LZMA2/XZ subset emitted by macOS and accepted by the stock kernel.
/// Length, dictionary and check types are bounded before entering the native decoder.
public enum BootXZArchive {
    public static let maximumSize = 16 * 1024 * 1024
    private static let magic: [UInt8] = [0xfd,0x37,0x7a,0x58,0x5a,0]
    private static func failure() -> RecoveryImageError { .invalid("The XZ startup archive is damaged, too large or unsupported.") }

    public static func encode(_ data: Data) throws -> Data {
        let packed = try process(data, operation: COMPRESSION_STREAM_ENCODE)
        guard try decodedSize(packed) == data.count else { throw failure() }
        return packed
    }
    public static func decode(_ data: Data) throws -> Data {
        let expected = try decodedSize(data)
        let unpacked = try process(data, operation: COMPRESSION_STREAM_DECODE)
        guard unpacked.count == expected else { throw failure() }
        return unpacked
    }
    private static func decodedSize(_ data: Data) throws -> Int {
        guard (32...maximumSize).contains(data.count) else { throw failure() }
        let b = Array(data), end = b.count
        guard b.starts(with:magic), b[6] == 0, [UInt8(0),1].contains(b[7]),
              b[end-2] == 0x59, b[end-1] == 0x5a, b[end-4] == b[6], b[end-3] == b[7] else { throw failure() }
        let backwards = (0..<4).reduce(UInt64(0)) { $0 | UInt64(b[end-8+$1]) << ($1*8) }
        let indexSize = (backwards+1)*4
        guard indexSize >= 8, indexSize <= 64, indexSize <= UInt64(end-24) else { throw failure() }
        let index = end-12-Int(indexSize), indexEnd = end-16
        guard b[index] == 0 else { throw failure() }
        var position = index+1
        func variable(_ limit:Int) throws -> UInt64 {
            var value:UInt64 = 0
            for shift in stride(from:0,through:56,by:7) {
                guard position < limit else { throw failure() }
                let byte=b[position];position += 1
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 {
                    guard shift == 0 || byte != 0 else { throw failure() }
                    return value
                }
            }
            throw failure()
        }
        let records = try variable(indexEnd)
        guard records <= 1 else { throw failure() }
        var decoded:UInt64 = 0
        if records == 1 {
            let unpadded = try variable(indexEnd)
            decoded = try variable(indexEnd)
            guard decoded <= maximumSize, unpadded >= 8, unpadded <= UInt64(index-12),
                  UInt64(index) == 12 + ((unpadded+3)/4)*4 else { throw failure() }
            let blockEnd = 12 + (Int(b[12])+1)*4
            guard b[12] != 0, blockEnd <= index, blockEnd <= 1036, b[13] & 0x3f == 0 else { throw failure() }
            let indexPosition=position;position=14
            if b[13] & 0x40 != 0 { _ = try variable(blockEnd-4) }
            if b[13] & 0x80 != 0 { guard try variable(blockEnd-4) == decoded else { throw failure() } }
            guard try variable(blockEnd-4) == 0x21, try variable(blockEnd-4) == 1,
                  position < blockEnd-4, b[position] <= 22 else { throw failure() } // LZMA2 dictionary <= 8 MiB.
            position += 1
            guard b[position..<blockEnd-4].allSatisfy({$0 == 0}) else { throw failure() }
            position=indexPosition
        } else {
            guard index == 12 else { throw failure() }
        }
        guard b[position..<indexEnd].allSatisfy({$0 == 0}) else { throw failure() }
        return Int(decoded)
    }
    private static func process(_ data:Data,operation:compression_stream_operation) throws -> Data {
        guard data.count <= maximumSize else { throw failure() }
        let stream=UnsafeMutablePointer<compression_stream>.allocate(capacity:1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream,operation,COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else { throw failure() }
        defer { compression_stream_destroy(stream) }
        let source=Array(data)+[0] // Keeps a valid pointer for an empty input.
        var output=Data(),chunk=[UInt8](repeating:0,count:65536)
        return try source.withUnsafeBufferPointer { input in
            stream.pointee.src_ptr=input.baseAddress!;stream.pointee.src_size=data.count
            while true {
                let remaining=stream.pointee.src_size
                let (status,count)=chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.pointee.dst_ptr=buffer.baseAddress!;stream.pointee.dst_size=buffer.count
                    let status=compression_stream_process(stream,Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    return (status,buffer.count-stream.pointee.dst_size)
                }
                guard status != COMPRESSION_STATUS_ERROR, count <= maximumSize-output.count else { throw failure() }
                output.append(contentsOf:chunk.prefix(count))
                if status == COMPRESSION_STATUS_END {
                    guard stream.pointee.src_size == 0 else { throw failure() }
                    return output
                }
                guard count > 0 || stream.pointee.src_size < remaining else { throw failure() }
            }
        }
    }
}

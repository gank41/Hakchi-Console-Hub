import Foundation
import CryptoKit

public struct LegacyBootImageContents: Sendable {
    public let kernel: Data
    public let archive: NewcArchive
    public let header: Data
}

/// File construction only. A valid image never grants RAM-boot or flash eligibility.
public enum LegacyBootImageBuilder {
    public enum RamdiskEncoding: Sendable { case lzopStored, lzopCompressed, xz }
    private static func failure() -> RecoveryImageError { .invalid("The startup image header, sections or checksum could not be verified.") }

    public static func inspect(_ data: Data) throws -> LegacyBootImageContents {
        let layout = try LegacyAndroidBootImage(data: data)
        let bytes = Data(data)
        let kernel = bytes.subdata(in: layout.kernelRange), ramdisk = bytes.subdata(in: layout.ramdiskRange)
        for range in [608..<layout.pageSize, layout.kernelRange.upperBound..<layout.ramdiskRange.lowerBound,
                      layout.ramdiskRange.upperBound..<bytes.count, 596..<608] {
            guard bytes[range].allSatisfy({ $0 == 0 }) else { throw failure() }
        }
        for range in [48..<64, 64..<576] {
            let window = bytes[range]
            guard let end = window.firstIndex(of: 0), window[..<end].allSatisfy({ (32...126).contains($0) }),
                  window[end...].allSatisfy({ $0 == 0 }) else { throw failure() }
        }
        guard bytes[576..<596] == identifier(kernel: kernel, ramdisk: ramdisk) else { throw failure() }
        let archiveBytes = try ramdisk.starts(with:[0xfd,0x37,0x7a,0x58,0x5a,0]) ? BootXZArchive.decode(ramdisk) : LZOPArchive.decode(ramdisk)
        let archive = try NewcArchive(data: archiveBytes)
        return LegacyBootImageContents(kernel: kernel, archive: archive, header: Data(bytes.prefix(608)))
    }

    public static func build(source: Data, kernel: Data, archive: NewcArchive, ramdiskEncoding: RamdiskEncoding = .lzopStored) throws -> Data {
        let original = try inspect(source)
        let layout = try LegacyAndroidBootImage(data: source)
        guard !kernel.isEmpty, kernel.count <= LegacyAndroidBootImage.maximumSize else { throw failure() }
        let encoded = try archive.encoded()
        let ramdisk: Data
        switch ramdiskEncoding {
        case .lzopStored: ramdisk = try LZOPArchive.store(encoded)
        case .lzopCompressed: ramdisk = try LZOPArchive.compress(encoded)
        case .xz: ramdisk = try BootXZArchive.encode(encoded)
        }
        let page = layout.pageSize
        func padded(_ n: Int) -> Int { ((n + page - 1) / page) * page }
        let length = page + padded(kernel.count) + padded(ramdisk.count)
        guard length <= LegacyAndroidBootImage.maximumSize else { throw failure() }
        var result = original.header
        for (offset, size) in [(8, kernel.count), (16, ramdisk.count)] {
            result.replaceSubrange(offset..<offset+4, with: littleEndian(UInt32(size)))
        }
        result.replaceSubrange(576..<596, with: identifier(kernel: kernel, ramdisk: ramdisk))
        result.append(Data(count: page - result.count))
        result.append(kernel); result.append(Data(count: padded(kernel.count) - kernel.count))
        result.append(ramdisk); result.append(Data(count: padded(ramdisk.count) - ramdisk.count))
        let checked = try inspect(result)
        guard checked.kernel == kernel, checked.archive == archive else { throw failure() }
        return result
    }

    public static func identifier(kernel: Data, ramdisk: Data) -> Data {
        var hash = Insecure.SHA1()
        // Classic mkbootimg ID includes an empty second section followed by its zero size.
        for section in [kernel, ramdisk, Data()] {
            hash.update(data: section)
            hash.update(data: Data(littleEndian(UInt32(clamping: section.count))))
        }
        return Data(hash.finalize())
    }
    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

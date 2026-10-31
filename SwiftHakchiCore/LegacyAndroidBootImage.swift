import Foundation

public enum RecoveryImageError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

/// Structure of the Nintendo legacy Android boot format, not proof of stock content.
/// Section ranges are offsets relative to the beginning of the supplied image.
public struct LegacyAndroidBootImage: Equatable, Sendable {
    public let pageSize: Int
    public let kernelSize: Int
    public let ramdiskSize: Int
    public let kernelRange: Range<Int>
    public let ramdiskRange: Range<Int>
    public let paddedSize: Int
    public static let maximumSize = 16 * 1024 * 1024

    public init(data: Data) throws {
        guard data.count >= 608, data.count <= Self.maximumSize else {
            throw RecoveryImageError.invalid("The boot image is truncated or exceeds 16 MiB.")
        }
        let header = Array(data.prefix(608))
        guard header.prefix(8).elementsEqual("ANDROID!".utf8) else {
            throw RecoveryImageError.invalid("The file has no Android boot header.")
        }
        func field(_ offset: Int) -> UInt64 {
            (0..<4).reduce(UInt64(0)) { $0 | (UInt64(header[offset + $1]) << ($1 * 8)) }
        }
        let page = field(36), kernel = field(8), ramdisk = field(16)
        guard [2048, 4096, 8192, 16384].contains(page), kernel > 0, ramdisk > 0,
              field(24) == 0, field(40) == 0, field(44) == 0 else {
            throw RecoveryImageError.invalid("Unsupported Nintendo boot header: page, section sizes or format version.")
        }
        // Header values are UInt32, promoted before arithmetic. No allocation uses a claimed size.
        func aligned(_ count: UInt64) -> UInt64 { ((count + page - 1) / page) * page }
        let ramdiskStart = page + aligned(kernel)
        let length = ramdiskStart + aligned(ramdisk)
        guard length == UInt64(data.count), length <= UInt64(Self.maximumSize),
              page + kernel <= ramdiskStart, ramdiskStart + ramdisk <= length else {
            throw RecoveryImageError.invalid("Boot sections do not match the complete page-aligned file length.")
        }
        pageSize = Int(page); kernelSize = Int(kernel); ramdiskSize = Int(ramdisk)
        kernelRange = Int(page)..<Int(page + kernel)
        ramdiskRange = Int(ramdiskStart)..<Int(ramdiskStart + ramdisk)
        paddedSize = Int(length)
    }
}

/// Recognition of one audited stock image; never unique console identity or restore permission.
public struct StockKernelEvidence: Equatable, Sendable {
    public let sha256: String
    public let family: String
    public let byteCount: Int

    public init(data: Data) throws {
        _ = try LegacyAndroidBootImage(data: data)
        let digest = BackupManifest.digest(data)
        guard data.count == 2_826_240,
              digest == "83efe33290867ec6e6b5c5a18e21f8cfe6f97b079c2e3c5039c628e729755888" else {
            throw RecoveryImageError.invalid("This structurally valid image is not the audited Western NES stock kernel. Keep it as a backup; it cannot establish stock restore readiness.")
        }
        sha256 = digest; family = "NES Classic (Western)"; byteCount = data.count
    }
}

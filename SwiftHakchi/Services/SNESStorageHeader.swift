import Foundation
import SwiftHakchiCore

/// Header inspection only. This does not mount ext4 or authorize a filesystem writer.
/// Separate from the deliberately 32-bit-only NES recovery policy.
struct SNESStorageHeader {
    let bytes: Data
    let summary: RecoveryDataSuperblock

    init(frame: Data, partitionSectors: UInt64) throws {
        func refuse() -> RecoveryProbeError {
            .refused("The SNES storage header, supported format, or partition size did not verify. No console changes were made.")
        }
        guard frame.count <= 2208, let newline = frame.prefix(160).firstIndex(of: 10),
              let line = String(data: frame[..<newline], encoding: .ascii) else { throw refuse() }
        let fields = line.components(separatedBy: " ")
        guard fields.count == 3, fields[0] == "SWIFTHAKCHI_DATA_SUPERBLOCK_V1", fields[1] == "2048",
              fields[2].count == 64, fields[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw refuse() }
        let bytes = Data(frame[(newline + 1)...])
        guard bytes.count == 2048, BackupManifest.digest(bytes) == fields[2],
              bytes[1080] == 0x53, bytes[1081] == 0xef else { throw refuse() }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset+$1]) << ($1*8) }
        }
        func half(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8 }
        // Linux ext4 superblock: offsets are relative to the 1-KiB superblock at 1024.
        // https://www.kernel.org/doc/html/latest/filesystems/ext4/super.html
        let revision = word(1100), shift = word(1048), incompatible = word(1120)
        guard revision <= 1, shift <= 2,
              word(1116) & ~UInt32(0x3c) == 0,
              incompatible & ~UInt32(0x2c2) == 0,
              word(1124) & ~UInt32(0x7b) == 0,
              (4...UInt64(UInt32.max)).contains(partitionSectors) else { throw refuse() }
        let wide = incompatible & 0x80 != 0
        if wide {
            // The captured stock SNES uses 64-byte descriptors and the standard high counters.
            guard revision == 1, half(1278) == 64 else { throw refuse() }
        } else {
            guard word(1360) == 0, word(1368) == 0, [0, 32].contains(half(1278)) else { throw refuse() }
        }
        let blocks = UInt64(word(1028)) | (wide ? UInt64(word(1360)) << 32 : 0)
        let free = UInt64(word(1036)) | (wide ? UInt64(word(1368)) << 32 : 0)
        let blockSize = UInt64(1024) << shift, partitionBytes = partitionSectors * 512
        // Bound before multiplying; hostile high counters must never overflow into a small size.
        guard blocks > 0, free <= blocks, blocks <= partitionBytes / blockSize,
              blocks * blockSize >= 1_048_576 else { throw refuse() }
        self.bytes = bytes
        summary = RecoveryDataSuperblock(blockSize: blockSize, blocks: blocks, freeBlocks: free,
            sha256: fields[2], isClean: half(1082) == 1 && incompatible & 0x4 == 0)
    }
}

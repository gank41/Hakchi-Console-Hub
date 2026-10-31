import Foundation
import SwiftHakchiCore

/// A bounded read of the data partition's ext4 superblock. The source command
/// reads NAND into RAM only; this model refuses unsupported on-disk formats.
struct RecoveryDataSuperblock: Encodable, Sendable {
    let blockSize: UInt64
    let blocks: UInt64
    let freeBlocks: UInt64
    let sha256: String
    let isClean: Bool

    static func parse(_ frame: Data, partitionSectors: UInt64) throws -> Self {
        func refused() -> RecoveryProbeError {
            .refused("Data-partition header framing, SHA256, ext4 format or geometry did not verify. No inventory was accepted.")
        }
        guard frame.count <= 2048 + 160,
              let newline = frame.prefix(160).firstIndex(of: 10),
              let header = String(data:frame[..<newline],encoding:.ascii) else { throw refused() }
        let fields = header.components(separatedBy:" ")
        guard fields.count == 3, fields[0] == "SWIFTHAKCHI_DATA_SUPERBLOCK_V1",
              fields[1] == "2048", fields[2].count == 64,
              fields[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw refused() }
        let bytes = Data(frame[(newline+1)...])
        guard bytes.count == 2048, BackupManifest.digest(bytes) == fields[2],
              bytes[1080] == 0x53, bytes[1081] == 0xef else { throw refused() }
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 |
            UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
        }
        let blocks = UInt64(word(1028)), free = UInt64(word(1036))
        let shift = word(1048), incompatible = word(1120)
        guard shift <= 2, incompatible & 0x80 == 0,
              blocks > 0, free <= blocks, partitionSectors >= 2048/512,
              partitionSectors <= UInt32.max else { throw refused() }
        let blockSize = UInt64(1024) << shift
        let size = blocks * blockSize
        guard size >= 1_048_576, size <= partitionSectors * 512 else { throw refused() }
        let state = UInt16(bytes[1082]) | UInt16(bytes[1083]) << 8
        return Self(blockSize:blockSize,blocks:blocks,freeBlocks:free,sha256:fields[2],
                    isClean:state == 1 && incompatible & 0x4 == 0)
    }
}

enum RecoveryDataSuperblockCommand {
    static let read = #"""
        set -eu
        test "$(sha256sum /bin/sntool | cut -d' ' -f1)" = 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9' || exit 20
        test -b /dev/nandc || exit 21
        test -d /tmp && test ! -L /tmp || exit 22
        awk '$2 == "/" { roots++; good = ($1 == "rootfs" && $3 == "rootfs" && index("," $4 ",", ",rw,") > 0) } $2 == "/tmp" || index($2, "/tmp/") == 1 { bad = 1 } END { if (roots != 1 || !good || bad) exit 1 }' /proc/mounts || exit 23
        if grep -q '^/dev/nandc ' /proc/mounts; then
          exit 24
        else
          status=$?
          test "$status" = 1 || exit 25
        fi
        umask 077
        d=$(mktemp -d /tmp/swifthakchi-data-header.XXXXXX) || exit 23
        trap 'rm -f "$d/header" "$d/read.err"; rmdir "$d"' EXIT
        (ulimit -f 4096 || exit 24; dd if=/dev/nandc of="$d/header" bs=2048 count=1 2> "$d/read.err") || exit 25
        test "$(wc -c < "$d/header" | tr -d '[:space:]')" = 2048 || exit 26
        sha=$(sha256sum "$d/header" | cut -d' ' -f1)
        printf 'SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 %s\n' "$sha"
        cat "$d/header"
        """#
}

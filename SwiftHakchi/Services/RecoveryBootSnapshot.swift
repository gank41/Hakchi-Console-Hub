import Foundation
import SwiftHakchiCore

/// Only these two audited hexadecimal boot2 offsets can reach the reader.
enum RecoveryBootSlot: Sendable { case active, backup
    var offset: String { self == .active ? "30" : "68" }
}
enum RecoveryBoot2Read: Equatable, Sendable {
    case unavailable
    case image(Data)

    static func parse(_ frame: Data) throws -> Self {
        func refused() -> RecoveryProbeError { .refused("Boot2 read framing, length or SHA256 did not verify. No snapshot was completed.") }
        guard frame.count <= LegacyAndroidBootImage.maximumSize + 160 else { throw refused() }
        let data = Data(frame)
        if data == Data("SWIFTHAKCHI_BOOT2_UNAVAILABLE_V1\n".utf8) { return .unavailable }
        guard let newline = data.prefix(160).firstIndex(of: 10),
              let header = String(data: data[..<newline], encoding: .ascii) else { throw refused() }
        let fields = header.components(separatedBy: " ")
        guard fields.count == 3, fields[0] == "SWIFTHAKCHI_BOOT2_V1",
              let count = Int(fields[1]), count > 0, count <= LegacyAndroidBootImage.maximumSize,
              String(count) == fields[1], fields[2].count == 64,
              fields[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw refused() }
        let bytes = Data(data[(newline + 1)...])
        guard bytes.count == count, BackupManifest.digest(bytes) == fields[2] else { throw refused() }
        return .image(bytes)
    }
}

/// Boot1 is raw evidence, not an Android boot image or an installable bootloader.
enum RecoveryBoot1Read {
    static let maximumSize = 8 * 1024 * 1024
    static func parse(_ frame: Data) throws -> Data {
        func refused() -> RecoveryProbeError {
            .refused("Boot1 read framing, length or SHA256 did not verify. No install evidence was completed.")
        }
        guard frame.count <= maximumSize + 160,
              let newline = frame.prefix(160).firstIndex(of: 10),
              let header = String(data: frame[..<newline], encoding: .ascii) else { throw refused() }
        let fields = header.components(separatedBy: " ")
        guard fields.count == 3, fields[0] == "SWIFTHAKCHI_BOOT1_V1",
              let count = Int(fields[1]), (1...maximumSize).contains(count), String(count) == fields[1],
              fields[2].count == 64,
              fields[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw refused() }
        let bytes = Data(frame[(newline + 1)...])
        guard bytes.count == count, BackupManifest.digest(bytes) == fields[2] else { throw refused() }
        return bytes
    }
}

struct RecoveryBoot1Snapshot: Encodable, Sendable {
    let data: Data
    init(_ data: Data) throws {
        guard (1...RecoveryBoot1Read.maximumSize).contains(data.count) else {
            throw RecoveryProbeError.refused("Boot1 evidence is empty or oversized.")
        }
        self.data = data
    }
    private enum CodingKeys: String, CodingKey { case status, byteCount, sha256 }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("raw-unvalidated", forKey: .status)
        try values.encode(data.count, forKey: .byteCount)
        try values.encode(BackupManifest.digest(data), forKey: .sha256)
    }
}

/// Raw bytes stay in private files; JSON contains only checks and digests.
struct RecoveryBootSnapshot: Encodable, Sendable {
    let active: Data
    let backup: Data?
    var activeIsKnownStock: Bool { (try? StockKernelEvidence(data: active)) != nil }
    var backupIsKnownStock: Bool { backup.map { (try? StockKernelEvidence(data: $0)) != nil } ?? false }
    var backupIsStructurallyValid: Bool { backup.map { (try? LegacyAndroidBootImage(data: $0)) != nil } ?? false }

    init(active: RecoveryBoot2Read, backup: RecoveryBoot2Read) throws {
        guard case .image(let bytes) = active else { throw RecoveryProbeError.refused("The active kernel could not be read. No complete snapshot exists.") }
        _ = try LegacyAndroidBootImage(data: bytes)
        self.active = bytes
        if case .image(let bytes) = backup {
            guard !bytes.isEmpty, bytes.count <= LegacyAndroidBootImage.maximumSize else {
                throw RecoveryProbeError.refused("Backup-slot bytes are empty or oversized.")
            }
            self.backup = bytes
        } else { self.backup = nil }
    }
    private struct ImageSummary: Encodable {
        let status: String
        let byteCount: Int
        let sha256: String?
        let isKnownStock: Bool
    }
    private enum CodingKeys: String, CodingKey { case active, backup }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ImageSummary(status: "valid-boot-image", byteCount: active.count,
            sha256: BackupManifest.digest(active), isKnownStock: activeIsKnownStock), forKey: .active)
        try values.encode(ImageSummary(status: backup == nil ? "unavailable" : (backupIsStructurallyValid ? "valid-boot-image" : "invalid-boot-image"),
            byteCount: backup?.count ?? 0, sha256: backup.map(BackupManifest.digest), isKnownStock: backupIsKnownStock), forKey: .backup)
    }
}

enum RecoveryBootSnapshotCommand {
    static func read(_ slot: RecoveryBootSlot) -> String {
        #"""
        set -eu
        test "$(sha256sum /bin/sntool | cut -d' ' -f1)" = 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9' || exit 20
        umask 077
        d=$(mktemp -d /tmp/swifthakchi-boot2.XXXXXX) || exit 21
        trap 'rm -f "$d/image" "$d/read.err"; rmdir "$d"' EXIT
        if (ulimit -f 16384 || exit 22; /bin/sunxi-flash read_boot2 \#(slot.offset) > "$d/image" 2> "$d/read.err"); then
          size=$(wc -c < "$d/image" | tr -d '[:space:]')
          test "$size" -gt 0 && test "$size" -le 16777216 || exit 23
          sha=$(sha256sum "$d/image" | cut -d' ' -f1)
          printf 'SWIFTHAKCHI_BOOT2_V1 %s %s\n' "$size" "$sha"
          cat "$d/image"
        else
          printf 'SWIFTHAKCHI_BOOT2_UNAVAILABLE_V1\n'
        fi
        """#
    }
}

/// A bounded, typed read from the documented boot1 offset. This yields evidence
/// only; it does not assert the bytes are a safe replacement bootloader.
enum RecoveryBoot1SnapshotCommand {
    static let read = #"""
        set -eu
        test "$(sha256sum /bin/sntool | cut -d' ' -f1)" = 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9' || exit 20
        umask 077
        d=$(mktemp -d /tmp/swifthakchi-boot1.XXXXXX) || exit 21
        trap 'rm -f "$d/image" "$d/read.err"; rmdir "$d"' EXIT
        if (ulimit -f 16384 || exit 22; /bin/sunxi-flash read_boot1 8 > "$d/image" 2> "$d/read.err"); then
          size=$(wc -c < "$d/image" | tr -d '[:space:]')
          test "$size" -gt 0 && test "$size" -le 8388608 || exit 23
          sha=$(sha256sum "$d/image" | cut -d' ' -f1)
          printf 'SWIFTHAKCHI_BOOT1_V1 %s %s\n' "$size" "$sha"
          cat "$d/image"
        else
          exit 24
        fi
        """#
}

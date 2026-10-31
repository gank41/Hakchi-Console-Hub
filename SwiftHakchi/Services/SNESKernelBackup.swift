import Foundation
import CryptoKit
import SwiftHakchiCore

/// A separate stock US SNES gate. Shared SoC/USB identifiers never establish this identity.
enum SNESBackupPolicy {
    static let command = #"""
    set -eu
    printf 'SWIFTHAKCHI_SNES_PROBE_V1\nKERNEL='; uname -r
    printf 'CMDLINE='; cat /proc/cmdline
    printf 'INIT_SHA='; sha256sum /hakchi/init | cut -d' ' -f1
    printf 'BASE_SHA='; sha256sum /hakchi/rootfs/etc/preinit.d/b0000_defines | cut -d' ' -f1
    printf 'BOARD=%s\n' "$(cat /newroot/etc/clover/boardtype)"
    printf 'REGION=%s\n' "$(cat /newroot/etc/clover/REGION)"
    found=0; for d in /newroot/usr/share/games/CLV-*; do if test -d "$d"; then found=1; break; fi; done
    printf 'SNES_DIRECTORY=%s\n' "$found"
    printf 'NES_DIRECTORY='; if test -d /newroot/usr/share/games/nes/kachikachi; then printf '1\n'; else printf '0\n'; fi
    printf 'HWID='; sntool devmem 0x01c23800 32 | hexdump -v -e '4/4 "%08x"' -n16; printf '\n'
    printf 'MOUNTS_BEGIN\n'; cat /proc/mounts; printf 'MOUNTS_END\nEND\n'
    """#

    static func observation(_ text: String) throws -> RecoveryProbeObservation {
        func refuse() -> RecoveryProbeError { .refused("The temporary recovery session did not verify as a read-only US SNES. No kernel backup was accepted.") }
        guard text.utf8.count <= 65536, text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else { throw refuse() }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 14, lines.first == "SWIFTHAKCHI_SNES_PROBE_V1", lines.last == "END",
              lines[10] == "MOUNTS_BEGIN", lines[lines.count - 2] == "MOUNTS_END" else { throw refuse() }
        var fields: [String: String] = [:]
        for line in lines[1..<10] {
            guard let separator = line.firstIndex(of: "=") else { throw refuse() }
            let key = String(line[..<separator]), value = String(line[line.index(after: separator)...])
            guard fields[key] == nil, !value.isEmpty else { throw refuse() }
            fields[key] = value
        }
        guard Set(fields.keys) == Set(["KERNEL", "CMDLINE", "INIT_SHA", "BASE_SHA", "BOARD", "REGION", "SNES_DIRECTORY", "NES_DIRECTORY", "HWID"]),
              fields["BOARD"] == "dp-shvc", fields["REGION"] == "USA", fields["SNES_DIRECTORY"] == "1", fields["NES_DIRECTORY"] == "0",
              fields["KERNEL"] == "3.4.113.29-madmonkey",
              fields["INIT_SHA"] == "ede443827300aff46995b97bb73c221aba2a1e9a38c710160a2fa28fdaec45b0",
              fields["BASE_SHA"] == "14a1dd7e3dae28339312fc379087c3e37119ce5684286e09a521f8cda318ae62",
              let hwid = fields["HWID"], hwid.count == 32, hwid.allSatisfy({ $0.isHexDigit }), hwid.contains(where: { $0 != "0" }) else { throw refuse() }
        let flags = fields["CMDLINE", default: ""].split(separator: " ").filter { $0.contains("hakchi-") }.map(String.init).sorted()
        guard flags == ["hakchi-memboot", "hakchi-shell"] else { throw refuse() }
        let mounts = Array(lines[11..<(lines.count - 2)])
        let result = RecoveryProbeObservation(kernel: fields["KERNEL"]!, board: "dp-shvc", hwid: hwid.lowercased(), mounts: mounts)
        try requireReadOnlyObservation(result)
        return result
    }

    /// Reused at the private export boundary, without inventing absent raw-frame evidence.
    static func requireReadOnlyObservation(_ observation: RecoveryProbeObservation) throws {
        func refuse() -> RecoveryProbeError { .refused("The SNES recovery identity or read-only mounts did not verify.") }
        guard observation.kernel == "3.4.113.29-madmonkey", observation.board == "dp-shvc",
              observation.hwid.count == 32, observation.hwid.allSatisfy({ $0.isHexDigit }),
              observation.hwid.contains(where: { $0 != "0" }) else { throw refuse() }
        var roots = 0
        for mount in observation.mounts {
            let columns = mount.split(separator: " ")
            guard columns.count == 6 else { throw refuse() }
            let device = columns[0], target = columns[1], options = columns[3].split(separator: ",")
            let readOnly = options.contains("ro") && !options.contains("rw")
            if target == "/newroot" {
                roots += 1
                guard columns[2] == "squashfs", readOnly else { throw refuse() }
            }
            guard target != "/var/lib", !target.hasPrefix("/var/lib/"), target != "/newroot/var/lib", !target.hasPrefix("/newroot/var/lib/") else { throw refuse() }
            if device.hasPrefix("/dev/nand") || device.hasPrefix("/dev/mapper/") || ["ext2", "ext3", "ext4", "vfat", "squashfs"].contains(String(columns[2])) {
                guard readOnly else { throw refuse() }
            }
        }
        guard roots == 1 else { throw refuse() }
        try RecoveryProbePolicy.requireRAMScratch(observation)
    }

}

struct SNESKernelBackupReport: Encodable, Sendable {
    let before: RecoveryProbeUSBDevice
    let after: RecoveryProbeUSBDevice
    let observation: RecoveryProbeObservation
    let active: Data
    let backup: Data?
    let firmwareRestoreEligible = false
    let region = "USA"
    private struct Image: Encodable {
        let status: String
        let byteCount: Int
        let sha256: String?
        let matchesUpstreamUSStockCatalog: Bool
    }
    static func knownStock(_ bytes: Data) -> Bool {
        let digest = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        // Provenance only: hakchi2 2.30 WorkerForm.cs correctKernels[SNES], USA entries.
        return ["449b711238575763c6701f5958323d48", "5296e64818bf2d1dbdc6b594f3eefd17", "228967ab1035a347caa9c880419df487"].contains(digest)
    }
    private enum CodingKeys: String, CodingKey { case before, after, observation, region, active, backup, firmwareRestoreEligible }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(before, forKey: .before); try container.encode(after, forKey: .after)
        try container.encode(observation, forKey: .observation); try container.encode(region, forKey: .region)
        try container.encode(false, forKey: .firmwareRestoreEligible)
        try container.encode(Image(status: "valid-boot-image-read-twice", byteCount: active.count, sha256: BackupManifest.digest(active), matchesUpstreamUSStockCatalog: Self.knownStock(active)), forKey: .active)
        let validBackup = backup.map { (try? LegacyAndroidBootImage(data: $0)) != nil } ?? false
        try container.encode(Image(status: backup == nil ? "unavailable" : (validBackup ? "valid-boot-image" : "invalid-boot-image"), byteCount: backup?.count ?? 0, sha256: backup.map(BackupManifest.digest), matchesUpstreamUSStockCatalog: backup.map(Self.knownStock) ?? false), forKey: .backup)
    }
}

actor SNESKernelBackupService {
    private let session: RecoverySessionCoordinator
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        session = RecoverySessionCoordinator(wait: wait)
    }
    func capture(inputs: RecoveryBootInputs, io: any RecoveryProbeIO, progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESKernelBackupReport {
        let (context, images) = try await session.run(inputs: inputs, io: io, progress: progress,
            validateObservation: { try SNESBackupPolicy.observation($0) }) { context in
            let before = try SNESBackupPolicy.observation(await io.observe())
            guard before.hwid == context.observation.hwid, before.mounts == context.observation.mounts else { throw RecoveryProbeError.refused("The SNES identity or mounts changed before the backup.") }
            try Task.checkCancellation()
            await progress(.readingCurrentKernel)
            let active = try await io.readBoot2(.active)
            try Task.checkCancellation()
            let backup = try await io.readBoot2(.backup)
            let snapshot = try RecoveryBootSnapshot(active: active, backup: backup)
            try Task.checkCancellation()
            await progress(.verifying)
            guard try await io.readBoot2(.active) == active else { throw RecoveryProbeError.refused("The two kernel reads differ. No complete SNES backup was accepted.") }
            let after = try SNESBackupPolicy.observation(await io.observe())
            guard after.hwid == before.hwid, after.mounts == before.mounts else { throw RecoveryProbeError.refused("The SNES identity or mounts changed during the backup.") }
            try Task.checkCancellation()
            return snapshot
        }
        return SNESKernelBackupReport(before: context.before, after: context.after, observation: context.observation, active: images.active, backup: images.backup)
    }
}

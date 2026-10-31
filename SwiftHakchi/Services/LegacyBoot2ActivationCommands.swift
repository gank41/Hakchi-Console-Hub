import Foundation
import SwiftHakchiCore

/// Direct recovery-RAM commands. These do not source the installed hakchi
/// wrapper, which can persist configuration as a side effect.
enum LegacyBoot2ActivationCommands {
    static let directory = "/tmp/swifthakchi-legacy-boot2"
    static var partitions: String { StockRestoreCommands.partitions }

    static func created(id: UUID) -> String { "SWIFTHAKCHI_LEGACY_STAGE_CREATED_V1 " + id.uuidString + "\n" }
    static func staged(id: UUID, sha: String) -> String { "SWIFTHAKCHI_LEGACY_STAGE_CHECKED_V1 " + id.uuidString + " " + sha + "\n" }
    static func marker(id: UUID, sha: String) -> String { "SWIFTHAKCHI_LEGACY_BOOT2_V1 " + id.uuidString + " " + sha + "\n" }

    static func create(id: UUID) -> String {
        "set -eu\n" + StockRestoreCommands.pins + "\n" + #"""
        umask 077
        d='/tmp/swifthakchi-legacy-boot2'
        mkdir "$d" || exit 30
        chmod 700 "$d"
        printf '%s\n' '\#(id.uuidString)' > "$d/owner"
        : > "$d/legacy.img"
        chmod 600 "$d/owner" "$d/legacy.img"
        printf '%s\n' 'SWIFTHAKCHI_LEGACY_STAGE_CREATED_V1 \#(id.uuidString)'
        """#
    }

    private static func validation(id: UUID, sha: String, count: Int) throws -> String {
        guard sha.count == 64, StockRestoreMaterial.hex(sha),
              (1...LegacyAndroidBootImage.maximumSize).contains(count) else { throw RestoreDirectory.failure() }
        return "set -eu\n" + StockRestoreCommands.pins + "\n" + #"""
        d='/tmp/swifthakchi-legacy-boot2'
        test -d "$d" && test ! -L "$d" || exit 31
        for file in owner legacy.img; do
          test -f "$d/$file" && test ! -L "$d/$file" && test "$(stat -c %h "$d/$file")" = 1 || exit 32
        done
        test "$(cat "$d/owner")" = '\#(id.uuidString)' || exit 33
        validate_image() {
          test "$(wc -c < "$d/legacy.img" | tr -d '[:space:]')" = '\#(count)' || exit 34
          test "$(sha256sum "$d/legacy.img" | cut -d' ' -f1)" = '\#(sha)' || exit 35
        }
        validate_image
        (ulimit -f 16384 || exit 24; /bin/sntool check "$d/legacy.img") > "$d/check.out" 2> "$d/check.err" || exit 36
        validate_image
        """#
    }

    static func checkedStage(id: UUID, sha: String, count: Int) throws -> String {
        try validation(id: id, sha: sha, count: count) + "\n" + #"""
        printf '%s\n' 'SWIFTHAKCHI_LEGACY_STAGE_CHECKED_V1 \#(id.uuidString) \#(sha)'
        """#
    }

    static func burn(id: UUID, sha: String, count: Int, partitionSHA256: String) throws -> String {
        guard partitionSHA256.count == 64, StockRestoreMaterial.hex(partitionSHA256) else { throw RestoreDirectory.failure() }
        return try validation(id: id, sha: sha, count: count) + "\n" + #"""
        (ulimit -f 16384 || exit 24; \#(StockRestoreCommands.partitionQuery)) > "$d/partitions.write" 2> "$d/partitions.err" || exit 37
        test "$(wc -c < "$d/partitions.write")" -le 16384 && test "$(wc -c < "$d/partitions.err")" -le 16384 || exit 26
        test "$(sha256sum "$d/partitions.write" | cut -d' ' -f1)" = '\#(partitionSHA256)' || exit 38
        validate_image
        (ulimit -f 16384 || exit 24; /bin/sunxi-flash burn_boot2 30 < "$d/legacy.img") > "$d/burn.out" 2> "$d/burn.err" || exit 39
        printf '%s\n' 'SWIFTHAKCHI_LEGACY_BOOT2_V1 \#(id.uuidString) \#(sha)'
        """#
    }
}

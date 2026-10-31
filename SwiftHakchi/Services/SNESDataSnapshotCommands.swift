import Foundation

/// Fixed logical-data reads. No filesystem mount, remote files, writer, or shell input path.
enum SNESDataSnapshotCommands {
    static let busyboxSHA256 = "d5c96520b02920b331ec8b7f232c662e53f97add208741f65500b0512bf87d44"
    private static func checks(plan: SNESDataSnapshotPlan) -> String {
        #"""
        set -eu
        set -o pipefail
        B=/bin/busybox
        test -f "$B" && test ! -L "$B" || exit 41
        pin=$("$B" sha256sum "$B") || exit 42
        test "${pin%% *}" = '\#(busyboxSHA256)' || exit 42
        test -b /dev/nandc && test ! -L /dev/nandc || exit 43
        test "$("$B" cat /sys/class/block/nandc/size)" = '\#(plan.byteCount/512)' || exit 44
        "$B" awk '$1 ~ /^\/dev\/nandc/ || $3=="ext2" || $3=="ext3" || $3=="ext4" || $3=="vfat" { bad=1 } $2=="/newroot" { roots++; good=($3=="squashfs" && index("," $4 ",",",ro,") && !index("," $4 ",",",rw,")) } END { if(bad || roots!=1 || !good) exit 1 }' /proc/mounts || exit 45
        """#
    }
    static func read(plan: SNESDataSnapshotPlan, index: Int, challenge: UUID) throws -> String {
        let range = try plan.range(index)
        return checks(plan: plan) + "\n" + #"""
        read_hash() {
          value=$("$B" dd if=/dev/nandc bs=1048576 skip=\#(range.lowerBound/SNESDataSnapshotPlan.unit) count=\#(range.count/SNESDataSnapshotPlan.unit) | "$B" sha256sum) || return 1
          printf '%s' "${value%% *}"
        }
        before=$(read_hash) || exit 46
        test "${#before}" = 64 || exit 46
        printf 'SWIFTHAKCHI_SNES_DATA_CHUNK_V1 %s %s %s %s\n' '\#(challenge.uuidString)' '\#(index)' '\#(range.count)' "$before"
        "$B" dd if=/dev/nandc bs=1048576 skip=\#(range.lowerBound/SNESDataSnapshotPlan.unit) count=\#(range.count/SNESDataSnapshotPlan.unit) || exit 47
        after=$(read_hash) || exit 48
        test "$before" = "$after" || exit 49
        printf '\nSWIFTHAKCHI_SNES_DATA_END_V1 %s %s %s\n' '\#(challenge.uuidString)' '\#(index)' "$after"
        """#
    }
    static func hash(plan: SNESDataSnapshotPlan, challenge: UUID) -> String {
        checks(plan: plan) + "\n" + #"""
        value=$("$B" sha256sum /dev/nandc) || exit 46
        value=${value%% *}
        test "${#value}" = 64 || exit 46
        printf 'SWIFTHAKCHI_SNES_DATA_HASH_V1 %s %s %s\n' '\#(challenge.uuidString)' '\#(plan.byteCount)' "$value"
        """#
    }
}

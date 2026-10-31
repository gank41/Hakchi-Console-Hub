import Foundation
import SwiftHakchiCore

enum StockRestorePartitions {
    static func validate(_ text: String) throws {
        func refuse() -> RecoveryProbeError { .refused("Live compact and detailed legacy partition views did not establish matching, bounded Western NES ranges and four valid MBR copies.") }
        guard text.utf8.count <= 16384, text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else { throw refuse() }
        let lines = text.components(separatedBy:"\n")
        guard lines.count == 19, lines[0] == "SWIFTHAKCHI_COMPACT_PARTITIONS_V1",
              lines[2] == "SWIFTHAKCHI_DETAILED_PARTITIONS_V1", lines.last == "" else { throw refuse() }
        let header = "mbr: version 0x00000200, magic softw411"
        for copy in 0..<4 {
            guard lines[3 + copy * 2] == "check partition table copy \(copy): " + header,
                  lines[4 + copy * 2] == "OK" else { throw refuse() }
        }
        guard lines[11] == header, lines[12] == "5 partitions" else { throw refuse() }
        func number(_ value: String, zero: Bool = false) throws -> UInt64 {
            guard let n = UInt64(value), n <= UInt32.max, String(n) == value, zero || n > 0 else { throw refuse() }
            return n
        }
        let compact = lines[1].components(separatedBy:" ")
        guard compact.count == 6, compact[0].hasPrefix("mbr::") else { throw refuse() }
        var expectedStart = try number(String(compact[0].dropFirst(5)))
        // The raw boot2 reserve precedes the first named partition.
        guard expectedStart >= 32768 else { throw refuse() }
        let expression = try NSRegularExpression(pattern: #"^partition +([0-9]+): class = +([A-Za-z0-9_]+), name = +([A-Za-z0-9_]+), partition start = +([0-9]+), partition size = +([0-9]+) user_type=([0-9]+)$"#)
        let names = ["boot","rootfs","data","private","UDISK"]
        let devices = ["nanda","nandb","nandc","nandd","nande"]
        for index in 0..<5 {
            let prefix = devices[index] + ":" + names[index] + ":"
            guard compact[index + 1].hasPrefix(prefix) else { throw refuse() }
            let resolvedSize = try number(String(compact[index + 1].dropFirst(prefix.count)))
            let line = lines[13 + index], range = NSRange(line.startIndex..., in:line)
            guard let match = expression.firstMatch(in:line,range:range) else { throw refuse() }
            func field(_ n: Int) -> String { String(line[Range(match.range(at:n),in:line)!]) }
            guard field(1) == String(index + 1), field(2) == "DISK", field(3) == names[index] else { throw refuse() }
            let start = try number(field(4)), declaredSize = try number(field(5),zero:true)
            let userType = try number(field(6),zero:true)
            guard start == expectedStart, start + resolvedSize <= UInt32.max else { throw refuse() }
            // The final UDISK may store an auto-size zero; only a positive live
            // compact length can resolve it. Every other declared length must agree.
            guard declaredSize == resolvedSize || (index == 4 && declaredSize == 0 && userType == 0) else { throw refuse() }
            expectedStart = start + resolvedSize
        }
    }
    static func dataSectors(_ text: String) throws -> UInt64 {
        try validate(text)
        let line = text.split(separator:"\n")[1]
        let token = line.split(separator:" ")[3]
        let prefix = "nandc:data:"
        guard token.hasPrefix(prefix), let sectors = UInt64(token.dropFirst(prefix.count)) else {
            throw RecoveryProbeError.refused("Validated partition metadata did not contain a data range.")
        }
        return sectors
    }
}
/// A signalled SSH command can lack exit-status and appear as zero to libssh2.
/// Require positive script completion in addition to the reported status.
enum StockRestoreCompletion {
    static func created(id: UUID) -> String { "SWIFTHAKCHI_STAGE_CREATED_V1 " + id.uuidString + "\n" }
    static func staged(id: UUID, sha: String) -> String { "SWIFTHAKCHI_STAGE_CHECKED_V1 " + id.uuidString + " " + sha + "\n" }
    static func require(_ result: SSHResult, marker: String) throws {
        guard result.succeeded, result.stdoutData == Data(marker.utf8) else {
            throw RecoveryProbeError.refused("Recovery command completion proof is missing or does not match. No further operation is authorized.")
        }
    }
    static func partitionData(_ result: SSHResult) throws -> Data {
        let data = result.stdoutData
        guard result.succeeded, data.count <= 16544, data.last == 10,
              let split = data.dropLast().lastIndex(of:10),
              let footer = String(data:data[(split + 1)..<(data.count - 1)],encoding:.ascii) else {
            throw RecoveryProbeError.refused("Partition query completion proof is missing, failed or oversized.")
        }
        let fields = footer.components(separatedBy:" "), body = Data(data[...split])
        guard fields.count == 3, fields[0] == "SWIFTHAKCHI_PARTITIONS_END_V1",
              fields[1] == String(body.count), fields[2] == BackupManifest.digest(body),
              let text = String(data:body,encoding:.ascii) else {
            throw RecoveryProbeError.refused("Partition query framing, length or digest did not verify.")
        }
        try StockRestorePartitions.validate(text)
        return body
    }
}
enum StockRestoreCommands {
    static let directory = "/tmp/swifthakchi-stock-restore"
    static let pins = #"""
    test "$(sha256sum /bin/sntool | cut -d' ' -f1)" = 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9' || exit 20
    test -L /bin/sunxi-flash && test "$(readlink -f /bin/sunxi-flash)" = /bin/sntool || exit 21
    test -L /bin/sunxi-part && test "$(readlink -f /bin/sunxi-part)" = /bin/sntool || exit 22
    """#
    static let partitionQuery = #"""
    set +e
    /bin/sntool ismd >/dev/null 2>&1
    md=$?
    set -e
    test "$md" = 1 || exit 23
    printf 'SWIFTHAKCHI_COMPACT_PARTITIONS_V1\n'
    /bin/sunxi-part || exit 27
    printf 'SWIFTHAKCHI_DETAILED_PARTITIONS_V1\n'
    /bin/sunxi-part --nand-part
    """#
    static var partitions: String {
        "set -eu\n" + pins + "\n" + #"""
        test -d /tmp && test ! -L /tmp || exit 28
        awk '$2 == "/" { roots++; good = ($1 == "rootfs" && $3 == "rootfs" && index("," $4 ",", ",rw,") > 0) } $2 == "/tmp" || index($2, "/tmp/") == 1 { bad = 1 } END { if (roots != 1 || !good || bad) exit 1 }' /proc/mounts || exit 29
        umask 077
        d=$(mktemp -d /tmp/swifthakchi-part.XXXXXX) || exit 24
        trap 'rm -f "$d/part" "$d/err"; rmdir "$d"' EXIT
        status=0
        (ulimit -f 16384 || exit 24; \#(partitionQuery)) > "$d/part" 2> "$d/err" || status=$?
        head -c 16384 "$d/part"
        head -c 16384 "$d/err" >&2
        test "$(wc -c < "$d/part")" -le 16384 && test "$(wc -c < "$d/err")" -le 16384 || exit 26
        test "$status" = 0 || exit "$status"
        printf 'SWIFTHAKCHI_PARTITIONS_END_V1 %s %s\n' "$(wc -c < "$d/part" | tr -d '[:space:]')" "$(sha256sum "$d/part" | cut -d' ' -f1)"
        """#
    }
    static func create(id: UUID) -> String {
        "set -eu\n" + pins + "\n" + #"""
        umask 077
        d='/tmp/swifthakchi-stock-restore'
        mkdir "$d" || exit 30
        chmod 700 "$d"
        printf '%s\n' '\#(id.uuidString)' > "$d/owner"
        : > "$d/stock.img"
        chmod 600 "$d/owner" "$d/stock.img"
        printf '%s\n' 'SWIFTHAKCHI_STAGE_CREATED_V1 \#(id.uuidString)'
        """#
    }
    static func validation(id: UUID, sha: String, count: Int) throws -> String {
        guard sha.count == 64, StockRestoreMaterial.hex(sha), (1...LegacyAndroidBootImage.maximumSize).contains(count) else { throw RestoreDirectory.failure() }
        return "set -eu\n" + pins + "\n" + #"""
        d='/tmp/swifthakchi-stock-restore'
        test -d "$d" && test ! -L "$d" || exit 31
        for file in owner stock.img; do
          test -f "$d/$file" && test ! -L "$d/$file" && test "$(stat -c %h "$d/$file")" = 1 || exit 32
        done
        test "$(cat "$d/owner")" = '\#(id.uuidString)' || exit 33
        validate_image() {
          test "$(wc -c < "$d/stock.img" | tr -d '[:space:]')" = '\#(count)' || exit 34
          test "$(sha256sum "$d/stock.img" | cut -d' ' -f1)" = '\#(sha)' || exit 35
        }
        validate_image
        (ulimit -f 16384 || exit 24; /bin/sntool check "$d/stock.img") > "$d/check.out" 2> "$d/check.err" || exit 36
        validate_image
        """#
    }
    static func checkedStage(id: UUID, sha: String, count: Int) throws -> String {
        try validation(id:id,sha:sha,count:count) + "\n" + #"""
        printf '%s\n' 'SWIFTHAKCHI_STAGE_CHECKED_V1 \#(id.uuidString) \#(sha)'
        """#
    }
    static func marker(id: UUID, sha: String) -> String { "SWIFTHAKCHI_STOCK_BOOT2_V1 " + id.uuidString + " " + sha + "\n" }
    static func burn(id: UUID, sha: String, count: Int, partitionSHA256: String) throws -> String {
        guard partitionSHA256.count == 64, StockRestoreMaterial.hex(partitionSHA256) else { throw RestoreDirectory.failure() }
        return try validation(id: id, sha: sha, count: count) + "\n" + #"""
        (ulimit -f 16384 || exit 24; \#(partitionQuery)) > "$d/partitions.write" 2> "$d/partitions.err" || exit 37
        test "$(wc -c < "$d/partitions.write")" -le 16384 && test "$(wc -c < "$d/partitions.err")" -le 16384 || exit 26
        test "$(sha256sum "$d/partitions.write" | cut -d' ' -f1)" = '\#(partitionSHA256)' || exit 38
        validate_image
        (ulimit -f 16384 || exit 24; /bin/sunxi-flash burn_boot2 30 < "$d/stock.img") > "$d/burn.out" 2> "$d/burn.err" || exit 39
        printf '%s\n' 'SWIFTHAKCHI_STOCK_BOOT2_V1 \#(id.uuidString) \#(sha)'
        """#
    }
}

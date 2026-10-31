import Foundation
import SwiftHakchiCore

struct RecoveryPersistentInventory: Encodable, Sendable {
    static let paths = [
        "clover", "hakchi", "hakchi/games", "hakchi/rootfs", "hakchi/rootfs/bin/hakchi",
        "hakchi/rootfs/etc/preinit", "hakchi/rootfs/etc/preinit.d/b0000_defines",
        "hakchi/rootfs/etc/preinit.d/b0010_functions", "hakchi/rootfs/etc/preinit.d/b0030_package",
        "hakchi/rootfs/etc/preinit.d/b0050_boot"
    ]
    private static let directories: Set<String> = ["clover", "hakchi", "hakchi/games", "hakchi/rootfs"]

    struct Entry: Encodable, Sendable {
        let path: String
        let kind: String
        let uid: UInt32?
        let gid: UInt32?
        let mode: String?
        let size: UInt64?
        let sha256: String?
    }

    let entries: [Entry]

    static func safeDiagnosticText(_ frame: Data) -> String? {
        guard !frame.isEmpty, frame.count <= 4096,
              frame.allSatisfy({ $0 == 9 || $0 == 10 || (32...126).contains($0) }) else { return nil }
        return String(data:frame,encoding:.ascii)
    }
    static func diagnosticSummary(_ frame: Data) -> String {
        let invalid = frame.enumerated().first { _,byte in
            byte != 9 && byte != 10 && !(32...126).contains(byte)
        }?.offset
        let prefix = frame.prefix(32).map { String(format:"%02x",$0) }.joined()
        return "bytes=\(frame.count) firstControl=\(invalid.map(String.init) ?? "none") prefixHex=\(prefix)"
    }
    static func stageTrace(_ stderr: String) -> String {
        let lines = Set(stderr.split(separator:"\n").map(String.init))
        let stages: [(String,String)] = [
            ("SWIFTHAKCHI_INV_STAGE_BEGIN_V1","begin"),
            ("SWIFTHAKCHI_INV_STAGE_MOUNTED_V1","mounted"),
            ("SWIFTHAKCHI_INV_STAGE_BODY_V1","body"),
            ("SWIFTHAKCHI_INV_STAGE_UNMOUNTED_V1","unmounted"),
            ("SWIFTHAKCHI_INV_STAGE_EMITTED_V1","emitted")
        ]
        let found = stages.compactMap { marker,name in lines.contains(marker) ? name : nil }
        return found.isEmpty ? "none" : found.joined(separator:",")
    }
    static func mountFlagTrace(_ stderr: String) -> String {
        for line in stderr.split(separator:"\n") {
            let parts = line.split(separator:" ")
            guard parts.count == 3, parts[0] == "SWIFTHAKCHI_INV_MOUNT_FLAGS_V1",
                  let count = Int(parts[1]), (0...9).contains(count),
                  parts[2].count == 8, parts[2].allSatisfy({ $0 == "0" || $0 == "1" }) else { continue }
            return "count=\(count) flags=\(parts[2])"
        }
        return "none"
    }

    static func parse(_ frame: Data) throws -> Self {
        func refused() -> RecoveryProbeError {
            .refused("Persistent inventory framing, fixed paths, metadata or SHA256 did not verify.")
        }
        guard frame.count <= 4096,
              frame.allSatisfy({ $0 == 9 || $0 == 10 || (32...126).contains($0) }),
              let text = String(data:frame,encoding:.ascii), text.hasSuffix("\n") else { throw refused() }
        let lines = text.components(separatedBy:"\n")
        guard lines.count == paths.count + 3, lines.last == "",
              lines[0] == "SWIFTHAKCHI_PERSISTENT_INVENTORY_V1" else { throw refused() }
        let body = lines.prefix(paths.count + 1).joined(separator:"\n") + "\n"
        let footer = lines[paths.count + 1].components(separatedBy:" ")
        guard footer.count == 3, footer[0] == "SWIFTHAKCHI_PERSISTENT_INVENTORY_END_V1",
              Int(footer[1]) == body.utf8.count,
              footer[2] == BackupManifest.digest(Data(body.utf8)) else { throw refused() }

        func number(_ value: String) throws -> UInt32 {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = UInt32(value) else { throw refused() }
            return parsed
        }
        func mode(_ value: String) throws -> String {
            guard (3...4).contains(value.count), value.utf8.allSatisfy({ (48...55).contains($0) }),
                  let parsed = UInt16(value,radix:8), parsed <= 0o7777 else { throw refused() }
            return value
        }
        func digest(_ value: String) throws -> String {
            guard value.count == 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw refused() }
            return value
        }
        var entries: [Entry] = []
        for (index,path) in paths.enumerated() {
            let fields = lines[index+1].components(separatedBy:"\t")
            guard fields.count >= 2, fields[1] == path else { throw refused() }
            switch fields[0] {
            case "A":
                guard fields.count == 2 else { throw refused() }
                entries.append(Entry(path:path,kind:"absent",uid:nil,gid:nil,mode:nil,size:nil,sha256:nil))
            case "D":
                guard fields.count == 5, directories.contains(path) else { throw refused() }
                entries.append(try Entry(path:path,kind:"directory",uid:number(fields[2]),gid:number(fields[3]),
                                         mode:mode(fields[4]),size:nil,sha256:nil))
            case "F":
                guard fields.count == 7, !directories.contains(path),
                      let size = UInt64(fields[5]), size <= 5_000_000 else { throw refused() }
                entries.append(try Entry(path:path,kind:"file",uid:number(fields[2]),gid:number(fields[3]),
                                         mode:mode(fields[4]),size:size,sha256:digest(fields[6])))
            default: throw refused()
            }
        }
        let kinds = Dictionary(uniqueKeysWithValues:entries.map { ($0.path,$0.kind) })
        if kinds["hakchi"] == "absent" && entries.contains(where: { $0.path.hasPrefix("hakchi/") && $0.kind != "absent" }) {
            throw refused()
        }
        if kinds["hakchi/rootfs"] == "absent" && entries.contains(where: { $0.path.hasPrefix("hakchi/rootfs/") && $0.kind != "absent" }) {
            throw refused()
        }
        return Self(entries:entries)
    }
}

enum RecoveryPersistentInventoryCommand {
    static var read: String {
        let fixedPaths = RecoveryPersistentInventory.paths.joined(separator:" ")
        return #"""
        set -eu
        printf 'SWIFTHAKCHI_INV_STAGE_BEGIN_V1\n' >&2
        test "$(sha256sum /bin/sntool | cut -d' ' -f1)" = 'f7eeecdeb94863364593fe9da55f499bfa13915a74fa2b2049e18209a65f57e9' || exit 20
        test -b /dev/nandc || exit 21
        test -d /tmp && test ! -L /tmp || exit 22
        awk '$2 == "/" { roots++; good = ($1 == "rootfs" && $3 == "rootfs" && index("," $4 ",", ",rw,") > 0) } $2 == "/tmp" || index($2, "/tmp/") == 1 { bad = 1 } END { if (roots != 1 || !good || bad) exit 1 }' /proc/mounts || exit 23
        if grep -q '^/dev/nandc ' /proc/mounts; then exit 24; else status=$?; test "$status" = 1 || exit 25; fi
        umask 077
        d=$(mktemp -d /tmp/swifthakchi-inventory.XXXXXX) || exit 26
        mnt="$d/mount"
        cleanup() {
          original=$?
          set +e
          trap - EXIT
          if awk -v target="$mnt" '$2 == target { found = 1 } END { exit !found }' /proc/mounts; then
            if ! umount "$mnt" >/dev/null 2>&1; then
              printf 'SWIFTHAKCHI_UNMOUNT_FAILED_V1\n' >&2
              exit 90
            fi
          else
            mount_status=$?
            if test "$mount_status" != 1; then
              printf 'SWIFTHAKCHI_MOUNT_STATE_UNKNOWN_V1\n' >&2
              exit 91
            fi
          fi
          rm -f "$d/body"
          rmdir "$mnt" "$d" >/dev/null 2>&1
          exit "$original"
        }
        trap cleanup EXIT
        mkdir "$mnt" || exit 27
        mount -t ext4 -o ro,noload,nodev,nosuid,noexec /dev/nandc "$mnt" || exit 28
        awk -v target="$mnt" '
          $2 == target {
            count++
            options = "," $4 ","
            if ($1 != "/dev/nandc" || $3 != "ext4" ||
                index(options, ",ro,") == 0 || index(options, ",rw,") != 0 ||
                (index(options, ",noload,") == 0 && index(options, ",norecovery,") == 0) ||
                index(options, ",nodev,") == 0 ||
                index(options, ",nosuid,") == 0 || index(options, ",noexec,") == 0) bad = 1
          }
          END { if (count != 1 || bad) exit 1 }
        ' /proc/mounts || {
          flags=$(awk -v target="$mnt" '
            $2 == target {
              count++
              options = "," $4 ","
              source = ($1 == "/dev/nandc")
              type = ($3 == "ext4")
              ro = (index(options, ",ro,") > 0)
              noRW = (index(options, ",rw,") == 0)
              noJournal = (index(options, ",noload,") > 0 || index(options, ",norecovery,") > 0)
              nodev = (index(options, ",nodev,") > 0)
              nosuid = (index(options, ",nosuid,") > 0)
              noexec = (index(options, ",noexec,") > 0)
            }
            END { printf "%d %d%d%d%d%d%d%d%d", count, source, type, ro, noRW, noJournal, nodev, nosuid, noexec }
          ' /proc/mounts) || exit 29
          printf 'SWIFTHAKCHI_INV_MOUNT_FLAGS_V1 %s\n' "$flags" >&2
          exit 29
        }
        printf 'SWIFTHAKCHI_INV_STAGE_MOUNTED_V1\n' >&2
        for ancestor in hakchi hakchi/rootfs hakchi/rootfs/bin hakchi/rootfs/etc hakchi/rootfs/etc/preinit.d; do
          test ! -L "$mnt/$ancestor" || exit 30
        done
        printf 'SWIFTHAKCHI_PERSISTENT_INVENTORY_V1\n' > "$d/body"
        for path in \#(fixedPaths); do
          target="$mnt/$path"
          test ! -L "$target" || exit 31
          case "$path" in
            clover|hakchi|hakchi/games|hakchi/rootfs) expected=directory ;;
            *) expected=file ;;
          esac
          if test -e "$target"; then
            uid=$(stat -c %u "$target") || exit 32
            gid=$(stat -c %g "$target") || exit 32
            mode=$(stat -c %a "$target") || exit 32
            if test "$expected" = directory; then
              test -d "$target" || exit 33
              printf 'D\t%s\t%s\t%s\t%s\n' "$path" "$uid" "$gid" "$mode" >> "$d/body"
            else
              test -f "$target" || exit 34
              size=$(stat -c %s "$target") || exit 35
              test "$size" -le 5000000 || exit 36
              sha=$(sha256sum "$target" | cut -d' ' -f1) || exit 37
              printf 'F\t%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$uid" "$gid" "$mode" "$size" "$sha" >> "$d/body"
            fi
          else
            printf 'A\t%s\n' "$path" >> "$d/body"
          fi
        done
        test "$(wc -c < "$d/body" | tr -d '[:space:]')" -le 4000 || exit 38
        bytes=$(wc -c < "$d/body" | tr -d '[:space:]')
        sha=$(sha256sum "$d/body" | cut -d' ' -f1)
        body=$(cat "$d/body")
        printf 'SWIFTHAKCHI_INV_STAGE_BODY_V1\n' >&2
        umount "$mnt" || exit 39
        if awk -v target="$mnt" '$2 == target { found = 1 } END { exit !found }' /proc/mounts; then exit 40; else status=$?; test "$status" = 1 || exit 41; fi
        rmdir "$mnt" || exit 42
        rm "$d/body" || exit 43
        rmdir "$d" || exit 44
        printf 'SWIFTHAKCHI_INV_STAGE_UNMOUNTED_V1\n' >&2
        trap - EXIT
        printf '%s\n' "$body"
        printf 'SWIFTHAKCHI_PERSISTENT_INVENTORY_END_V1 %s %s\n' "$bytes" "$sha"
        printf 'SWIFTHAKCHI_INV_STAGE_EMITTED_V1\n' >&2
        """#
    }
}

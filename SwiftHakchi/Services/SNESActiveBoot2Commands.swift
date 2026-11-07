import Foundation

enum SNESActiveBoot2Commands {
    static func directory(_ id:UUID)->String {"/tmp/swifthakchi-snes-active-"+id.uuidString}
    static func created(_ id:UUID)->String {"SWIFTHAKCHI_SNES_PHYSICAL_CREATED_V1 "+id.uuidString+"\n"}
    static func checked(_ id:UUID)->String {"SWIFTHAKCHI_SNES_PHYSICAL_HELPER_V1 "+id.uuidString+"\n"}
    private static let checks = #"""
    set -eu
    set -o pipefail
    B=/bin/busybox
    M=/lib/modules/3.4.113.29-madmonkey/kernel/drivers/block/nand/nand.ko
    test -f "$B" && test ! -L "$B" || exit 40
    value=$("$B" sha256sum "$B") || exit 40
    test "${value%% *}" = 'd5c96520b02920b331ec8b7f232c662e53f97add208741f65500b0512bf87d44' || exit 40
    test "$("$B" uname -r)" = '3.4.113.29-madmonkey' || exit 41
    test -f "$M" && test ! -L "$M" && test -d /sys/module/nand || exit 41
    value=$("$B" sha256sum "$M") || exit 41
    test "${value%% *}" = '5d67ca0977370a04f46edbf1c02aa1dcbb2fc964781775d906125c40eb7d29d5' || exit 41
    test -b /dev/nanda && test ! -L /dev/nanda || exit 42
    test -d /tmp && test ! -L /tmp || exit 43
    "$B" awk '$2=="/" { roots++; ram=($1=="rootfs" && $3=="rootfs" && index(","$4",",",rw,")) } $2=="/tmp" || index($2,"/tmp/")==1 {bad=1} $2=="/newroot" {systemRoots++; good=($3=="squashfs" && index(","$4",",",ro,") && !index(","$4",",",rw,"))} $1 ~ /^\/dev\/nand/ || $3=="ext2" || $3=="ext3" || $3=="ext4" || $3=="vfat" {if(!index(","$4",",",ro,") || index(","$4",",",rw,")) bad=1} END {if(roots!=1 || !ram || systemRoots!=1 || !good || bad) exit 1}' /proc/mounts || exit 43
    umask 077
    """#
    static var recoveryReadOnlyChecks:String {checks}
    static func create(id:UUID)->String {
        checks+"\n" + #"""
        d='\#(directory(id))'
        mkdir "$d" || exit 44
        chmod 700 "$d" || exit 44
        printf '%s\n' '\#(id.uuidString)' > "$d/owner" || exit 44
        chmod 600 "$d/owner" || exit 44
        printf '%s\n' 'SWIFTHAKCHI_SNES_PHYSICAL_CREATED_V1 \#(id.uuidString)'
        """# + "\n"
    }
    private static func owned(id:UUID)->String {
        checks+"\n" + #"""
        d='\#(directory(id))'
        H="$d/reader"
        test -d "$d" && test ! -L "$d" || exit 45
        test "$("$B" stat -c '%u' "$d")" = 0 && test "$("$B" stat -c '%a' "$d")" = 700 || exit 45
        for f in "$d/owner" "$H"; do
          test -f "$f" && test ! -L "$f" || exit 46
          test "$("$B" stat -c '%h' "$f")" = 1 && test "$("$B" stat -c '%u' "$f")" = 0 || exit 46
        done
        test "$("$B" cat "$d/owner")" = '\#(id.uuidString)' || exit 47
        """# + "\n"
    }
    private static func helperChecks(byteCount:Int,digest:String)->String { #"""
    test "$("$B" wc -c < "$H" | "$B" tr -d '[:space:]')" = \#(byteCount) || exit 48
    value=$("$B" sha256sum "$H") || exit 48
    test "${value%% *}" = '\#(digest)' || exit 48
    test "$("$B" stat -c '%a' "$H")" = 500 || exit 48
    """# }
    static func validation(id:UUID)->String {
        validation(id:id,byteCount:11928,digest:SNESBoundedReadHelper.sha256)
    }
    static func validation(id:UUID,helper:SNESBoundedReadHelper)->String {
        validation(id:id,byteCount:helper.bytes.count,digest:helper.digest)
    }
    private static func validation(id:UUID,byteCount:Int,digest:String)->String {
        owned(id:id)+"chmod 500 \"$H\" || exit 48\n"+helperChecks(byteCount:byteCount,digest:digest)+"\n" + #"""
        printf '%s\n' 'SWIFTHAKCHI_SNES_PHYSICAL_HELPER_V1 \#(id.uuidString)'
        """# + "\n"
    }
    static func read(id:UUID,kind:SNESPhysicalFrame.Kind,challenge:UUID)->String {
        read(id:id,kind:kind,challenge:challenge,byteCount:11928,digest:SNESBoundedReadHelper.sha256)
    }
    static func read(id:UUID,kind:SNESPhysicalFrame.Kind,challenge:UUID,helper:SNESBoundedReadHelper)->String {
        read(id:id,kind:kind,challenge:challenge,byteCount:helper.bytes.count,digest:helper.digest)
    }
    private static func read(id:UUID,kind:SNESPhysicalFrame.Kind,challenge:UUID,byteCount:Int,digest:String)->String {
        let invocation=kind == .geometry ? "\"$H\" geometry":"\"$H\" read-active 56"
        return owned(id:id)+helperChecks(byteCount:byteCount,digest:digest)+"\n" + #"""
        f="$d/result-\#(challenge.uuidString)"
        test ! -e "$f" && test ! -L "$f" || exit 49
        trap '"$B" rm -f "$f"' EXIT
        (set -C; ulimit -f 16384 || exit 50; \#(invocation) < /dev/null > "$f") || exit 50
        test -f "$f" && test ! -L "$f" || exit 51
        test "$("$B" stat -c '%h' "$f")" = 1 && test "$("$B" stat -c '%u' "$f")" = 0 || exit 51
        count=$("$B" wc -c < "$f" | "$B" tr -d '[:space:]') || exit 52
        test "$count" = '\#(kind.count)' || exit 52
        value=$("$B" sha256sum "$f") || exit 53
        digest=${value%% *}
        test "${#digest}" = 64 || exit 53
        printf '\#(kind.label) %s %s %s\n' '\#(challenge.uuidString)' "$count" "$digest"
        "$B" cat "$f" || exit 54
        value=$("$B" sha256sum "$f") || exit 55
        test "${value%% *}" = "$digest" || exit 55
        printf '\nSWIFTHAKCHI_SNES_PHYSICAL_END_V1 %s %s\n' '\#(challenge.uuidString)' "$digest"
        """# + "\n"
    }
}

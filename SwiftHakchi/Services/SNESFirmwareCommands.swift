import Foundation
import SwiftHakchiCore

enum SNESFirmwareCommands {
    static func directory(_ id:UUID)->String {"/tmp/swifthakchi-snes-firmware-"+id.uuidString}
    static func created(_ id:UUID)->String {"SWIFTHAKCHI_SNES_FIRMWARE_CREATED_V1 "+id.uuidString+"\n"}
    static func staged(_ m:SNESFirmwareMaterial)->String {"SWIFTHAKCHI_SNES_FIRMWARE_STAGED_V1 "+m.id.uuidString+"\n"}
    static func marker(_ m:SNESFirmwareMaterial,writing:Bool)->String {"SWIFTHAKCHI_SNES_WRITE_"+(writing ? "VERIFIED":"PREFLIGHT")+"_V1 "+m.id.uuidString+" "+BackupManifest.digest(m.target)+"\n"}
    private static func memory(_ minimum:Int)->String {
        #"""
        "$B" awk '$1=="MemFree:" { n++;good=($2 ~ /^[0-9]+$/ && $3=="kB" && $2>=\#(minimum)) } END {if(n!=1 || !good) exit 1}' /proc/meminfo || exit 60
        """# + "\n"
    }
    static func create(_ id:UUID)->String {
        SNESActiveBoot2Commands.recoveryReadOnlyChecks+"\n"+memory(49152) + #"""
        d='\#(directory(id))'
        mkdir "$d" || exit 61
        chmod 700 "$d" || exit 61
        (set -C; printf '%s\n' '\#(id.uuidString)' > "$d/owner") || exit 61
        chmod 600 "$d/owner" || exit 61
        printf '%s\n' 'SWIFTHAKCHI_SNES_FIRMWARE_CREATED_V1 \#(id.uuidString)'
        """# + "\n"
    }
    private static func owned(_ m:SNESFirmwareMaterial)->String {
        SNESActiveBoot2Commands.recoveryReadOnlyChecks+"\n"  + #"""
        d='\#(directory(m.id))'
        H="$d/writer"
        P="$d/input"
        test -d "$d" && test ! -L "$d" || exit 62
        test "$("$B" stat -c '%u' "$d")" = 0 && test "$("$B" stat -c '%a' "$d")" = 700 || exit 62
        for f in "$d/owner" "$H" "$P"; do
          test -f "$f" && test ! -L "$f" || exit 63
          test "$("$B" stat -c '%h' "$f")" = 1 && test "$("$B" stat -c '%u' "$f")" = 0 || exit 63
        done
        test "$("$B" cat "$d/owner")" = '\#(m.id.uuidString)' || exit 64
        test "$("$B" stat -c '%a' "$d/owner")" = 600 || exit 64
        """# + "\n"
    }
    private static func hashes(_ m:SNESFirmwareMaterial)->String {
        #"""
        test "$("$B" wc -c < "$H" | "$B" tr -d '[:space:]')" = 1594072 || exit 65
        test "$("$B" wc -c < "$P" | "$B" tr -d '[:space:]')" = 14680088 || exit 65
        value=$("$B" sha256sum "$H") || exit 65
        test "${value%% *}" = '\#(SNESBoundedWriteHelper.sha256)' || exit 65
        value=$("$B" sha256sum "$P") || exit 66
        test "${value%% *}" = '\#(BackupManifest.digest(m.geometry+m.preimage+m.target))' || exit 66
        """# + "\n"
    }
    static func checked(_ m:SNESFirmwareMaterial)->String {
        owned(m)+hashes(m) + #"""
        chmod 500 "$H" || exit 67
        chmod 400 "$P" || exit 67
        printf '%s\n' 'SWIFTHAKCHI_SNES_FIRMWARE_STAGED_V1 \#(m.id.uuidString)'
        """# + "\n"
    }
    static func invoke(_ m:SNESFirmwareMaterial,writing:Bool)->String {
        let claim=writing ? #"""
        test ! -e "$d/write-requested" && test ! -L "$d/write-requested" || exit 69
        (set -C; printf '%s\n' '\#(m.id.uuidString)' > "$d/write-requested") || exit 69
        """# + "\n":""
        return owned(m)+hashes(m)+memory(32768) + #"""
        test "$("$B" stat -c '%a' "$H")" = 500 && test "$("$B" stat -c '%a' "$P")" = 400 || exit 68
        """# + "\n"+claim + #"""
        "$H" \#(writing ? "replace-active":"verify-active") '\#(BackupManifest.digest(m.preimage))' '\#(BackupManifest.digest(m.target))' '\#(BackupManifest.digest(m.geometry))' '\#(m.id.uuidString)' < "$P"
        """# + "\n"
    }
}
enum SSHExclusiveUpload {
    static func command(path:String)throws->String {
        guard path.hasPrefix("/tmp/swifthakchi-"),path.utf8.count<=4096,!path.contains("\0"),
              URL(fileURLWithPath:path).standardizedFileURL.path==path else {throw RecoveryProbeError.refused("The temporary upload path is invalid.")}
        return "set -eu\nset -C\numask 077\n/bin/busybox cat > "+LaunchCommand.shellQuote(path)+"\n"
    }
}

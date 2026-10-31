import Foundation

enum SNESStartupPreflightCommands {
    static func directory(_ id:UUID) -> String { "/tmp/swifthakchi-snes-startup-"+id.uuidString }
    static func created(_ id:UUID) -> String { "SWIFTHAKCHI_SNES_STARTUP_RAM_CREATED_V1 "+id.uuidString+"\n" }
    static func staged(_ id:UUID,imageSHA:String,stockSHA:String) -> String { "SWIFTHAKCHI_SNES_STARTUP_RAM_CHECKED_V1 "+id.uuidString+" "+imageSHA+" "+stockSHA+"\n" }
    private static func prefix(id:UUID,imageBytes:Int,stockBytes:Int) throws -> String {
        guard (1...7*1024*1024).contains(imageBytes),stockBytes==2736128 else {throw SNESRuntimeBinding.failure()}
        return #"""
        set -eu
        set -o pipefail
        umask 077
        B=/bin/busybox
        D='\#(directory(id))'
        test -f "$B" && test ! -L "$B"
        pin=$("$B" sha256sum "$B")
        test "${pin%% *}" = '\#(SNESDataSnapshotCommands.busyboxSHA256)'
        test -d /tmp && test ! -L /tmp
        "$B" awk '
          NF!=6 { bad=1 }
          $2=="/" { roots++; if($1!="rootfs" || $3!="rootfs" || !index("," $4 ",",",rw,")) bad=1 }
          $2=="/tmp" || index($2,"/tmp/")==1 { bad=1 }
          $1 ~ /^\/dev\/nandc/ || $3=="ext2" || $3=="ext3" || $3=="ext4" || $3=="vfat" { bad=1 }
          END { if(bad || roots!=1) exit 1 }
        ' /proc/mounts
        """# + "\n"
    }
    static func create(id:UUID,imageBytes:Int,stockBytes:Int) throws -> String {
        let start=try prefix(id:id,imageBytes:imageBytes,stockBytes:stockBytes),required=(imageBytes+stockBytes+1023)/1024+8192
        return start + #"""
        "$B" awk '$1=="MemFree:" { seen++; if($2 !~ /^[0-9]+$/ || $3!="kB" || $2 < \#(required)) bad=1 } END { if(bad || seen!=1) exit 1 }' /proc/meminfo
        test ! -e "$D" && test ! -L "$D"
        "$B" mkdir -m 0700 "$D"
        printf '%s\n' '\#(id.uuidString)' > "$D/operation"
        : > "$D/startup.img"
        : > "$D/stock.img"
        printf '%s\n' 'SWIFTHAKCHI_SNES_STARTUP_RAM_CREATED_V1 \#(id.uuidString)'
        """# + "\n"
    }
    static func check(id:UUID,imageBytes:Int,stockBytes:Int,imageSHA:String,stockSHA:String) throws -> String {
        guard SNESDataSnapshotChunk.isDigest(imageSHA),SNESDataSnapshotChunk.isDigest(stockSHA) else {throw SNESRuntimeBinding.failure()}
        return try prefix(id:id,imageBytes:imageBytes,stockBytes:stockBytes) + #"""
        test -d "$D" && test ! -L "$D"
        test "$("$B" stat -c '%a' "$D")" = 700
        test "$("$B" stat -c '%u' "$D")" = 0
        for file in "$D"/* "$D"/.[!.]* "$D"/..?*; do
          if test ! -e "$file" && test ! -L "$file"; then continue; fi
          case "$file" in "$D/operation"|"$D/startup.img"|"$D/stock.img") :;; *) exit 41;; esac
        done
        for name in operation startup.img stock.img; do
          test -f "$D/$name" && test ! -L "$D/$name"
          test "$("$B" stat -c '%h' "$D/$name")" = 1
          test "$("$B" stat -c '%u' "$D/$name")" = 0
          test "$("$B" stat -c '%a' "$D/$name")" = 600
        done
        test "$("$B" stat -c '%s' "$D/operation")" = 37
        test "$("$B" cat "$D/operation")" = '\#(id.uuidString)'
        test "$("$B" stat -c '%s' "$D/startup.img")" = '\#(imageBytes)'
        test "$("$B" stat -c '%s' "$D/stock.img")" = '\#(stockBytes)'
        value=$("$B" sha256sum "$D/startup.img")
        test "${value%% *}" = '\#(imageSHA)'
        value=$("$B" sha256sum "$D/stock.img")
        test "${value%% *}" = '\#(stockSHA)'
        printf '%s\n' 'SWIFTHAKCHI_SNES_STARTUP_RAM_CHECKED_V1 \#(id.uuidString) \#(imageSHA) \#(stockSHA)'
        """# + "\n"
    }
}

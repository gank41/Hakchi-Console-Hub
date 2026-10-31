import Foundation
import SwiftHakchiCore

/// Fixed, bounded normal-mode commands. No activation, deletion, reset or firmware command.
struct SNESOneGameStageCommands {
    static func context(menu:SNESOneGameMenu,binding:SNESRuntimeBinding)throws->String {
        try binding.validate()
        return #"""
        set -eu
        set -o pipefail
        umask 077
        export LC_ALL=C
        B=/mnt/swifthakchi/busybox
        N=/var/lib/swifthakchi/snes-v1
        test -f "$B" && test ! -L "$B" || exit 1
        value=$("$B" sha256sum "$B");test "${value%% *}" = '__BUSYBOX__' || exit 1
        test "$("$B" uname -r)" = 3.4.113 || exit 1
        test "$("$B" cat /etc/clover/boardtype)" = dp-shvc || exit 1
        test "$("$B" cat /etc/clover/REGION)" = USA || exit 1
        chip=''
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32);chip="$chip$(printf '%08x' "$word")"
        done
        test "$chip" = '__HWID__' || exit 1
        test -d /var/lib && test ! -L /var/lib || exit 1
        "$B" awk '$2=="/var/lib" {n++;if($1!="/dev/nandc" || $3!="ext4" || $4 !~ /(^|,)rw(,|$)/ || $4 ~ /(^|,)ro(,|$)/)bad=1}END{exit !(n==1&&!bad)}' /proc/mounts || exit 1
        capacity() {
          values=$("$B" df -Pk /var/lib | "$B" awk 'NR==2 && NF==6 && $1=="/dev/nandc" && $6=="/var/lib" {print $2 " " $4;n++}END{if(n!=1)exit 1}') || return 1
          set -- $values;test "$#" -eq 2 || return 1
          total=$1;available=$2
          for number in "$total" "$available"; do
            case "$number" in ''|*[!0-9]*) return 1;; 0) ;; 0*) return 1;; esac
          done
          test "$total" -ge 200000 && test "$total" -le 400000 && test "$available" -le "$total" || return 1
          free=$((available*1024))
        }
        directory() {
          test -d "$1" && test ! -L "$1" || return 1
          test "$("$B" stat -c '%u' "$1")" = 0 && test "$("$B" stat -c '%a' "$1")" = 700 || return 1
        }
        for parent in "${N%/*}" "$N" "$N/menus"; do
          if test -e "$parent" || test -L "$parent"; then directory "$parent" || exit 1; fi
        done
        capacity || exit 1
        """#.replacingOccurrences(of:"__BUSYBOX__",with:SNESRAMProbeScripts.busyboxSHA256)
            .replacingOccurrences(of:"__HWID__",with:binding.expectedHWID)+"\n"
    }
    static func originalChecks(_ originals:SNESOriginalGamesFrame)throws->String {
        var rows=[BackupManifest.digest(originals.launcher)+"  /usr/bin/clover-canoe-shvc"]
        for e in originals.entries {
            guard let f=e.files.first(where:{$0.name==e.code+".desktop"}) else {throw SNESOneGameMenu.failure()}
            rows.append(BackupManifest.digest(f.data)+"  /usr/share/games/"+e.code+"/"+f.name)
        }
        let codes=originals.entries.map(\.code).joined(separator:"\n")
        let inventory="""
        test -d /usr/share/games && test ! -L /usr/share/games || exit 1
        codes=$(for directory in /usr/share/games/CLV-P-*; do
          test -d "$directory" && test ! -L "$directory" || exit 1
          printf '%s\\n' "${directory##*/}"
        done) || exit 1
        test "$codes" = \(LaunchCommand.shellQuote(codes)) || exit 1

        """
        return inventory+"printf '%s' "+LaunchCommand.shellQuote(rows.joined(separator:"\n")+"\n")+" | \"$B\" sha256sum -c - >/dev/null || exit 1\n"
    }
    private static func absent(_ menu:SNESOneGameMenu)->String {
        """
        target='\(menu.consoleRoot)'
        test ! -e "$target" && test ! -L "$target" || exit 1
        test ! -e /var/lib/clover/profiles/0/\(menu.code) && test ! -L /var/lib/clover/profiles/0/\(menu.code) || exit 1
        test "$free" -ge \(menu.requiredFreeBytes) || exit 1

        """
    }
    private static func receipt(menu:SNESOneGameMenu,challenge:UUID,preflight:Bool)->String {
        let header=preflight ? "SWIFTHAKCHI_SNES_GAME_PREFLIGHT_V1":"SWIFTHAKCHI_SNES_GAME_INACTIVE_V1"
        return """
        printf '%s\\n' '\(header)' 'CHALLENGE=\(challenge.uuidString)'
        printf 'HWID=%s\\n' "$chip"
        printf '%s\\n' 'ID=\(menu.id.uuidString)' 'TREE=\(menu.treeSHA256)' 'FILES=\(menu.files.count+1)' 'BYTES=\(menu.byteCount)'
        printf 'FREE_BYTES=%s\\nSELECTOR_CHANGED=0\\nEND\\n' "$free"

        """
    }
    private static func copyLimitBlocks(_ menu:SNESOneGameMenu)throws->Int {
        guard let largest=menu.files.values.map(\.count).max(),largest>0,largest<=4194400 else {throw SNESOneGameMenu.failure()}
        return (largest+511)/512
    }
    static func inspect(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding,challenge:UUID,includeProcesses:Bool=false)throws->String {
        var script=try context(menu:menu,binding:binding)+originalChecks(originals)
        let blocks=try copyLimitBlocks(menu)
        script += """
        target='\(menu.consoleRoot)'
        printf '%s\\n' 'SWIFTHAKCHI_SNES_GAME_INSPECTION_V2' 'CHALLENGE=\(challenge.uuidString)' 'HWID=\(binding.expectedHWID)' 'ID=\(menu.id.uuidString)'
        if test -e "$N/active-menu" || test -L "$N/active-menu"; then
          test -f "$N/active-menu" && test ! -L "$N/active-menu" || exit 1
          test "$("$B" stat -c '%h' "$N/active-menu")" = 1 || exit 1
          test "$("$B" wc -c < "$N/active-menu")" -le 192 || exit 1
          value=$("$B" sha256sum "$N/active-menu");printf 'SELECTOR=%s\\n' "${value%% *}"
        else printf 'SELECTOR=missing\\n'; fi
        if test -e "$target" || test -L "$target"; then
          directory "$target" || exit 1
          printf 'TARGET=directory\\n'
          count=$("$B" find "$target" -mindepth 1 -maxdepth 4 | "$B" wc -l | "$B" tr -d '[:space:]')
          test "$count" -le 512 || exit 1
        else printf 'TARGET=missing\\n';count=0;fi
        printf 'ENTRIES=%s\\n' "$count"

        """
        var files=menu.files;files["menu.manifest"]=menu.manifest
        for name in files.keys.sorted() {
            script += """
            file="$target/\(name)"
            if test -e "$file" || test -L "$file"; then
              test -f "$file" && test ! -L "$file" || exit 1
              test "$("$B" stat -c '%h' "$file")" = 1 || exit 1
              test "$("$B" stat -c '%u' "$file")" = 0 || exit 1
              bytes=$("$B" wc -c < "$file" | "$B" tr -d '[:space:]');test "$bytes" -le 8388608 || exit 1
              value=$("$B" sha256sum "$file");printf 'FILE \(name) %s %s\\n' "$bytes" "${value%% *}"
            else printf 'MISSING \(name)\\n';fi

            """
        }
        script += """
        limits=$("$B" awk '$1=="Max" && $2=="file" && $3=="size" {n++;print $4 ":" $5} END {if(n!=1)exit 1}' /proc/self/limits)
        if (ulimit -f \(blocks)) 2>/dev/null; then ready=1;else ready=0;fi
        printf 'FILE_SIZE_LIMIT=%s\\nCOPY_LIMIT_READY=%s\\nEND\\n' "$limits" "$ready"

        """
        if includeProcesses {script += #"""
        # Private bounded diagnostic data; never used as write or restart authority.
        printf '%s\n' 'SWIFTHAKCHI_SNES_PROCESS_DETAILS_V1' >&2
        inspected=0
        for process in /proc/[0-9]*; do
          test "$inspected" -lt 24 || break
          test -d "$process" || continue
          exe=$("$B" readlink -f "$process/exe" 2>/dev/null) || continue
          test "${#exe}" -le 128 || continue
          parent=$("$B" awk '$1=="PPid:" {print $2}' "$process/status" 2>/dev/null) || continue
          case "$parent" in ''|*[!0-9]*) continue;; esac
          framebuffer=0
          for descriptor in "$process"/fd/*; do
            linked=$("$B" readlink "$descriptor" 2>/dev/null) || continue
            if test "$linked" = /dev/fb0; then framebuffer=1;break;fi
          done
          args=$("$B" tr '\000' ' ' < "$process/cmdline" 2>/dev/null | "$B" head -c 96 | "$B" tr -cd ' -~') || args=unavailable
          printf 'PID=%s PPID=%s FB0=%s EXE=%s ARGS=%s\n' "${process##*/}" "$parent" "$framebuffer" "$exe" "$args" >&2
          inspected=$((inspected+1))
        done
        printf '%s\n' 'PROCESS_DETAILS_END' >&2

        """#}
        guard script.utf8.count<=65536 else {throw SNESOneGameMenu.failure()};return script
    }
    static func preflight(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding,challenge:UUID)throws->String {
        try context(menu:menu,binding:binding)+originalChecks(originals)+absent(menu)+"(ulimit -f \(copyLimitBlocks(menu))) 2>/dev/null || exit 1\n"+receipt(menu:menu,challenge:challenge,preflight:true)
    }
    static func verify(menu:SNESOneGameMenu,binding:SNESRuntimeBinding,challenge:UUID)throws->String {
        let verifier=LaunchCommand.shellQuote(SNESMenuAdapterScripts.verifier)
        return try context(menu:menu,binding:binding)+"""
        path=$("$B" sh -c \(verifier) -- '\(menu.id.uuidString)' '\(menu.treeSHA256)')
        test "$path" = '\(menu.consoleRoot)/games' || exit 1
        capacity || exit 1

        """+receipt(menu:menu,challenge:challenge,preflight:false)
    }
    static func copy(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding,challenge:UUID)throws->String {
        var script=try context(menu:menu,binding:binding)+originalChecks(originals)+absent(menu)+"ulimit -f \(copyLimitBlocks(menu))\n"
        script += """
        IFS= read -r line
        test "$line" = 'SWIFTHAKCHI_SNES_MENU_FILES_V1 \(menu.id.uuidString)' || exit 1
        for parent in "${N%/*}" "$N" "$N/menus"; do
          if test -e "$parent" || test -L "$parent"; then directory "$parent" || exit 1; else "$B" mkdir -m 0700 "$parent"; fi
        done
        "$B" mkdir -m 0700 "$target"
        "$B" mkdir -m 0700 "$target/games"
        set -C

        """
        for code in Set(menu.files.keys.compactMap { name->String? in
            let p=name.split(separator:"/");return p.count==3 ? String(p[1]):nil
        }).sorted() {script += "\"$B\" mkdir -m 0700 \"$target/games/"+code+"\"\n"}
        var files=menu.files;files["menu.manifest"]=menu.manifest
        for name in files.keys.sorted() {
            let data=files[name]!,hash=BackupManifest.digest(data)
            script += """
            IFS= read -r line
            test "$line" = 'FILE \(name) \(data.count) \(hash)' || exit 1
            "$B" dd bs=1 count=\(data.count) 2>/dev/null > "$target/\(name)"
            size=$("$B" wc -c < "$target/\(name)" | "$B" tr -d '[:space:]');test "$size" = \(data.count) || exit 1
            value=$("$B" sha256sum "$target/\(name)");test "${value%% *}" = '\(hash)' || exit 1
            IFS= read -r line;test -z "$line" || exit 1

            """
        }
        script += """
        IFS= read -r line;test "$line" = 'END \(files.count)' || exit 1
        "$B" sync
        path=$("$B" sh -c \(LaunchCommand.shellQuote(SNESMenuAdapterScripts.verifier)) -- '\(menu.id.uuidString)' '\(menu.treeSHA256)')
        test "$path" = '\(menu.consoleRoot)/games' || exit 1
        capacity || exit 1

        """+receipt(menu:menu,challenge:challenge,preflight:false)
        guard script.utf8.count<=65536 else {throw SNESOneGameMenu.failure()};return script
    }
}

struct SNESOneGameStageReceipt:Sendable {
    let raw:Data,freeBytes:Int
    let challenge:UUID,isPreflight:Bool
    init(_ raw:Data,menu:SNESOneGameMenu,binding:SNESRuntimeBinding,challenge:UUID,preflight:Bool)throws {
        try binding.validate()
        guard raw.count<=4096,let text=String(data:raw,encoding:.ascii) else {throw SNESOneGameMenu.failure()}
        let rows=text.components(separatedBy:"\n")
        guard rows.count==11,rows[0]==(preflight ? "SWIFTHAKCHI_SNES_GAME_PREFLIGHT_V1":"SWIFTHAKCHI_SNES_GAME_INACTIVE_V1"),
              rows[1]=="CHALLENGE="+challenge.uuidString,rows[2]=="HWID="+binding.expectedHWID,rows[3]=="ID="+menu.id.uuidString,
              rows[4]=="TREE="+menu.treeSHA256,rows[5]=="FILES="+String(menu.files.count+1),rows[6]=="BYTES="+String(menu.byteCount),
              rows[7].hasPrefix("FREE_BYTES="),rows[8]=="SELECTOR_CHANGED=0",rows[9]=="END",rows[10].isEmpty,
              let free=Int(rows[7].dropFirst(11)),String(free)==String(rows[7].dropFirst(11)),(0...409600000).contains(free) else {throw SNESOneGameMenu.failure()}
        self.raw=raw;freeBytes=free;self.challenge=challenge;isPreflight=preflight
    }
}

struct SNESOneGameInspectionReceipt:Sendable {
    let raw:Data,matchesMenu:Bool
    let copyLimitReady:Bool,fileSizeLimit:String
    let challenge:UUID
    var selectorMissing:Bool {raw.split(separator:10).dropFirst(4).first==Data("SELECTOR=missing".utf8)}
    init(_ raw:Data,menu:SNESOneGameMenu,binding:SNESRuntimeBinding,challenge:UUID)throws {
        var files=menu.files;files["menu.manifest"]=menu.manifest
        try self.init(raw,expected:files.mapValues {($0.count,BackupManifest.digest($0))},id:menu.id,gameCount:menu.gameCount,binding:binding,challenge:challenge)
    }
    /// Revalidates a saved observation without requiring the user's old ROM library.
    init(_ raw:Data,manifest:Data,plan:SNESOneGameMaterial.Plan,binding:SNESRuntimeBinding,challenge:UUID)throws {
        guard manifest.count<=32768,BackupManifest.digest(manifest)==plan.menuTreeSHA256,
              let text=String(data:manifest,encoding:.ascii),(2...35).contains(plan.gameCount) else {throw SNESOneGameMenu.failure()}
        let rows=text.components(separatedBy:"\n")
        guard rows.first=="SWIFTHAKCHI_SNES_MENU_V1",rows.last=="",rows.count==plan.gameCount+5 else {throw SNESOneGameMenu.failure()}
        var expected:[String:(Int,String)]=[:],previous="",total=0
        for row in rows.dropFirst().dropLast() {
            let parts=row.components(separatedBy:" ")
            guard parts.count==3,SNESDataSnapshotChunk.isDigest(parts[0]),let size=Int(parts[1]),String(size)==parts[1],
                  (1...4194400).contains(size),parts[2].utf8.count<=128,parts[2]>previous,
                  parts[2].range(of:#"^games/CLV-[PU]-[A-Z0-9]{5}/[A-Za-z0-9_.-]+$"#,options:.regularExpression) != nil else {throw SNESOneGameMenu.failure()}
            expected[parts[2]]=(size,parts[0]);previous=parts[2];total+=size
        }
        guard total<=8*1024*1024,Set(expected.keys.map{$0.split(separator:"/")[1]}).count==plan.gameCount else {throw SNESOneGameMenu.failure()}
        expected["menu.manifest"]=(manifest.count,BackupManifest.digest(manifest))
        try self.init(raw,expected:expected,id:plan.id,gameCount:plan.gameCount,binding:binding,challenge:challenge)
    }
    private init(_ raw:Data,expected:[String:(Int,String)],id:UUID,gameCount:Int,binding:SNESRuntimeBinding,challenge:UUID)throws {
        try binding.validate()
        guard raw.count<=16384,let text=String(data:raw,encoding:.ascii) else {throw SNESOneGameMenu.failure()}
        let lines=text.components(separatedBy:"\n")
        guard lines.count==expected.count+11,lines[0]=="SWIFTHAKCHI_SNES_GAME_INSPECTION_V2",lines[1]=="CHALLENGE="+challenge.uuidString,
              lines[2]=="HWID="+binding.expectedHWID,lines[3]=="ID="+id.uuidString,lines[4].hasPrefix("SELECTOR="),
              ["TARGET=missing","TARGET=directory"].contains(lines[5]),lines[6].hasPrefix("ENTRIES="),
              let count=Int(lines[6].dropFirst(8)),String(count)==String(lines[6].dropFirst(8)),(0...512).contains(count),lines.suffix(2)==["END",""] else {throw SNESOneGameMenu.failure()}
        let selector=String(lines[4].dropFirst(9));guard selector=="missing" || SNESDataSnapshotChunk.isDigest(selector) else {throw SNESOneGameMenu.failure()}
        var matched=lines[5]=="TARGET=directory" && count==1+gameCount+expected.count
        for (index,name) in expected.keys.sorted().enumerated() {
            let row=lines[index+7]
            if row=="MISSING "+name {matched=false;continue}
            let p=row.components(separatedBy:" ")
            guard p.count==4,p[0]=="FILE",p[1]==name,let size=Int(p[2]),String(size)==p[2],(0...8388608).contains(size),SNESDataSnapshotChunk.isDigest(p[3]) else {throw SNESOneGameMenu.failure()}
            if size != expected[name]!.0 || p[3] != expected[name]!.1 {matched=false}
        }
        let limitRow=lines[lines.count-4],readyRow=lines[lines.count-3]
        guard limitRow.hasPrefix("FILE_SIZE_LIMIT="),["COPY_LIMIT_READY=0","COPY_LIMIT_READY=1"].contains(readyRow) else {throw SNESOneGameMenu.failure()}
        let limit=String(limitRow.dropFirst(16)),parts=limit.components(separatedBy:":")
        guard parts.count==2,parts.allSatisfy({value in value=="unlimited" || (UInt64(value).map{String($0)==value} ?? false)}) else {throw SNESOneGameMenu.failure()}
        self.raw=raw;self.challenge=challenge;matchesMenu=matched;copyLimitReady=readyRow=="COPY_LIMIT_READY=1";fileSizeLimit=limit
    }
}

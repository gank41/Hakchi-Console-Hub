import Foundation
import SwiftHakchiCore

/// Passive startup-support data, not controller mappings or emulator eligibility.
struct SNESCompatibilitySupportFrame:Sendable {
    static let maximumBytes=3*ARMRuntimeELF.maximumSize+96*1024
    static let textLimits:[(String,Int)]=[("input",65536),("audio-cards",4096),("audio-pcm",4096),("fb-size",256),("fb-bpp",256)]
    let raw:Data
    let libraries:[String:Data]
    let chains:[String:String]
    let metadata:[String:Data]
    static func failure()->RecoveryProbeError {
        .refused("The console’s original libraries or device details could not be verified. Nothing was installed or changed.")
    }
    static func requireBinding(context:String,hwid:String)throws {
        guard context.count==64,SNESRuntimeBinding.hex(context),hwid.count==32,SNESRuntimeBinding.hex(hwid),
              hwid.contains(where:{$0 != "0"}) else {throw failure()}
    }
    init(_ raw:Data,challenge:UUID,context:String,hwid:String)throws {
        try Self.requireBinding(context:context,hwid:hwid)
        guard raw.count<=Self.maximumBytes else {throw Self.failure()}
        let bytes=Array(raw);var position=0
        func line()throws->String {
            guard position<bytes.count,let end=bytes[position..<min(position+2048,bytes.count)].firstIndex(of:10),
                  bytes[position..<end].allSatisfy({(32...126).contains($0)}) else {throw Self.failure()}
            let value=String(decoding:bytes[position..<end],as:UTF8.self);position=end+1;return value
        }
        func payload(count:String,sha:String,maximum:Int)throws->Data {
            guard let n=Int(count),String(n)==count,(1...maximum).contains(n),sha.count==64,SNESRuntimeBinding.hex(sha),
                  n<bytes.count-position else {throw Self.failure()}
            let data=Data(bytes[position..<position+n]);position += n
            guard bytes[position]==10,BackupManifest.digest(data)==sha else {throw Self.failure()};position += 1
            return data
        }
        guard try line()=="HAKCHI_SNES_COMPAT_SUPPORT_V1",try line()=="CHALLENGE="+challenge.uuidString,
              try line()=="CONTEXT="+context,try line()=="HWID="+hwid else {throw Self.failure()}
        var libraries:[String:Data]=[:],chains:[String:String]=[:],metadata:[String:Data]=[:]
        for (role,first,pattern,needed) in [
            ("loader","ld-linux-armhf.so.3",#"^ld-([0-9]+\.)+[0-9]+\.so$"#,Set<String>()),
            ("libc","libc.so.6",#"^libc-([0-9]+\.)+[0-9]+\.so$"#,Set(["ld-linux-armhf.so.3"])),
            ("pthread","libpthread.so.0",#"^libpthread-([0-9]+\.)+[0-9]+\.so$"#,Set(["libc.so.6","ld-linux-armhf.so.3"]))] {
            let fields=try line().components(separatedBy:" ")
            guard fields.count==5,fields[0]=="LIB",fields[1]==role else {throw Self.failure()}
            let links=fields[2].components(separatedBy:">")
            guard (1...9).contains(links.count),links.first==first,Set(links).count==links.count,
                  links.allSatisfy({$0.utf8.count<=128 && ($0==first || $0.range(of:pattern,options:.regularExpression) != nil)}) else {throw Self.failure()}
            let data=try payload(count:fields[3],sha:fields[4],maximum:ARMRuntimeELF.maximumSize)
            let elf=try ARMRuntimeELF(data:data)
            guard elf.type==3,Set(elf.dependencies)==needed,
                  role=="loader" ? elf.interpreter==nil : (elf.interpreter==nil || elf.interpreter=="/lib/ld-linux-armhf.so.3") else {throw Self.failure()}
            libraries[role]=data;chains[role]=fields[2]
        }
        for (role,limit) in Self.textLimits {
            let fields=try line().components(separatedBy:" ")
            guard fields.count==4,fields[0]=="TEXT",fields[1]==role else {throw Self.failure()}
            let data=try payload(count:fields[2],sha:fields[3],maximum:limit)
            guard let text=String(data:data,encoding:.utf8),text.unicodeScalars.allSatisfy({
                $0.value==9 || $0.value==10 || ($0.value>=32 && !((127...159).contains($0.value)))
            }) else {throw Self.failure()}
            metadata[role]=data
        }
        guard try line()=="END",position==bytes.count else {throw Self.failure()}
        self.raw=raw;self.libraries=libraries;self.chains=chains;self.metadata=metadata
    }
}

enum SNESCompatibilitySupportCommand {
    /// Fixed original-library/proc/sys reads only. Never reads controller events,
    /// user game files, saves or caller-supplied paths, and never writes console files.
    static func read(challenge:UUID,context:String,hwid:String)throws->String {
        try SNESCompatibilitySupportFrame.requireBinding(context:context,hwid:hwid)
        return #"""
        set -eu
        export LC_ALL=C
        B=/mnt/swifthakchi/busybox
        test -f "$B" && test ! -L "$B"
        test "$("$B" stat -c '%h:%u' "$B")" = 1:0
        pin=$("$B" sha256sum "$B")
        test "${pin%% *}" = 440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6
        "$B" awk 'NR==1 && $0=="rootfs / rootfs rw 0 0" {next}
          $2=="/" {n++;good=($3=="squashfs" && index("," $4 ",",",ro,") && !index("," $4 ",",",rw,"))}
          $2=="/lib" || index($2,"/lib/")==1 {bad=1}
          END {if(n!=1 || !good || bad) exit 1}' /proc/mounts
        test -d /lib && test ! -L /lib
        valid() {
          case "$1:$2" in loader:ld-linux-armhf.so.3|libc:libc.so.6|pthread:libpthread.so.0) return 0;; esac
          case "$1" in
            loader) printf '%s\n' "$2" | "$B" grep -Eq '^ld-([0-9]+\.)+[0-9]+\.so$';;
            libc) printf '%s\n' "$2" | "$B" grep -Eq '^libc-([0-9]+\.)+[0-9]+\.so$';;
            pthread) printf '%s\n' "$2" | "$B" grep -Eq '^libpthread-([0-9]+\.)+[0-9]+\.so$';;
            *) return 1;;
          esac
        }
        read_lib() {
          role="$1";name="$2";chain="$name";hops=0
          while test -L "/lib/$name"; do
            hops=$((hops+1));test "$hops" -le 8
            next=$("$B" readlink "/lib/$name")
            case "$next" in /lib/*) next="${next#/lib/}";; esac
            test "${#next}" -le 128 && valid "$role" "$next"
            name="$next";chain="$chain>$name"
          done
          test -f "/lib/$name"
          count=$("$B" wc -c < "/lib/$name" | "$B" tr -d ' \n')
          test "$count" -ge 52 && test "$count" -le 2097152
          sha=$("$B" sha256sum "/lib/$name");sha="${sha%% *}"
          printf 'LIB %s %s %s %s\n' "$role" "$chain" "$count" "$sha"
          "$B" cat "/lib/$name";printf '\n'
        }
        read_meta() {
          role="$1";path="$2";limit="$3"
          test -f "$path"
          # The sentinel preserves trailing newlines in bounded, passive text.
          value=$("$B" head -c "$((limit+1))" "$path";printf x);value="${value%x}"
          count=$(printf '%s' "$value" | "$B" wc -c | "$B" tr -d ' \n')
          test "$count" -gt 0 && test "$count" -le "$limit"
          sha=$(printf '%s' "$value" | "$B" sha256sum);sha="${sha%% *}"
          printf 'TEXT %s %s %s\n' "$role" "$count" "$sha"
          printf '%s\n' "$value"
        }
        no_game() {
          for program in canoe-shvc clover-canoe-shvc clover-kachikachi kachikachi retroarch hc-snes-superv; do
            test -z "$("$B" pidof "$program" || :)" || return 83
          done
          menu_pid=$("$B" pidof clover-mcp) || return 83
          case "$menu_pid" in ''|*[!0-9]*) return 83;; esac
          test "$menu_pid" -gt 1 && test "$("$B" readlink -f "/proc/$menu_pid/exe")" = /usr/bin/clover-mcp || return 83
        }
        no_game;original_menu_pid="$menu_pid"
        printf 'HAKCHI_SNES_COMPAT_SUPPORT_V1\nCHALLENGE=__NONCE__\nCONTEXT=__CONTEXT__\nHWID=__HWID__\n'
        read_lib loader ld-linux-armhf.so.3
        read_lib libc libc.so.6
        read_lib pthread libpthread.so.0
        read_meta input /proc/bus/input/devices 65536
        read_meta audio-cards /proc/asound/cards 4096
        read_meta audio-pcm /proc/asound/pcm 4096
        read_meta fb-size /sys/class/graphics/fb0/virtual_size 256
        read_meta fb-bpp /sys/class/graphics/fb0/bits_per_pixel 256
        no_game;test "$menu_pid" = "$original_menu_pid" || exit 83
        printf 'END\n'
        """#.replacingOccurrences(of:"__NONCE__",with:challenge.uuidString)
            .replacingOccurrences(of:"__CONTEXT__",with:context).replacingOccurrences(of:"__HWID__",with:hwid)+"\n"
    }
}

struct SNESCompatibilitySupportCapture:Sendable {
    let frame:SNESCompatibilitySupportFrame
    let frames:[Data]
    let challenges:[UUID]
    static func read(context:String,hwid:String,
                     validate:@Sendable () async throws->Void,
                     read:@Sendable(UUID) async throws->Data) async throws->Self {
        try SNESCompatibilitySupportFrame.requireBinding(context:context,hwid:hwid)
        var frames:[Data]=[],challenges:[UUID]=[],first:SNESCompatibilitySupportFrame?
        for _ in 0..<2 {
            try Task.checkCancellation();try await validate()
            let nonce=UUID();guard !challenges.contains(nonce) else {throw SNESCompatibilitySupportFrame.failure()}
            let raw=try await read(nonce)
            try Task.checkCancellation();try await validate()
            let current=try SNESCompatibilitySupportFrame(raw,challenge:nonce,context:context,hwid:hwid)
            if let first {
                guard current.libraries==first.libraries,current.chains==first.chains,current.metadata==first.metadata else {throw SNESCompatibilitySupportFrame.failure()}
            } else {first=current}
            frames.append(raw);challenges.append(nonce)
        }
        guard let first else {throw SNESCompatibilitySupportFrame.failure()}
        return .init(frame:first,frames:frames,challenges:challenges)
    }
}

struct SNESCompatibilityConsoleSupport:Sendable {
    let capture:SNESCompatibilitySupportCapture
    let reports:[Data]
    let reportChallenges:[UUID]
}

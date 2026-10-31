import Foundation
import SwiftHakchiCore

/// Original-file evidence only. No entry grants permission to load a library.
struct SNESFrontendSupportFrame: Sendable {
    static let maximumLibraryBytes = 8 * 1024 * 1024
    static let maximumBytes = 32 * 1024 * 1024
    static let roles: [(String, String, String)] = [
        ("rt", "librt.so.1", #"librt([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("math", "libm.so.6", #"libm([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("dl", "libdl.so.2", #"libdl([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("udev", "libudev.so.1", #"libudev([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("egl", "libEGL.so", #"(libEGL|libMali)([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("gles", "libGLESv2.so", #"(libGLESv2|libMali)([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("mali", "libMali.so", #"libMali([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("ump", "libUMP.so", #"libUMP([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("asound", "libasound.so.2", #"libasound([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("z", "libz.so.1", #"libz([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("gcc", "libgcc_s.so.1", #"libgcc_s([-.][0-9]+)*\.so([.][0-9]+)*"#),
        ("sdl", "libSDL2.so", #"libSDL2([-][0-9]+([.][0-9]+)*)?\.so([.][0-9]+)*"#)
    ]
    let raw: Data
    let libraries: [String: Data]
    let chains: [String: String]
    let missing: Set<String>
    static func validPath(_ path: String, role: (String,String,String)) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        return ["/lib", "/usr/lib"].contains(folder) && path.utf8.count <= 256 &&
            (path as NSString).lastPathComponent.range(of: "^(" + role.2 + ")$", options: .regularExpression) != nil
    }
    init(_ raw: Data, challenge: UUID, context: String, hwid: String) throws {
        try SNESCompatibilitySupportFrame.requireBinding(context: context, hwid: hwid)
        guard raw.count <= Self.maximumBytes else { throw SNESCompatibilitySupportFrame.failure() }
        let bytes = Array(raw); var at = 0
        func line() throws -> String {
            guard at < bytes.count, let end = bytes[at..<min(at+4096,bytes.count)].firstIndex(of:10),
                  bytes[at..<end].allSatisfy({ (32...126).contains($0) }) else { throw SNESCompatibilitySupportFrame.failure() }
            defer { at = end+1 }; return String(decoding:bytes[at..<end],as:UTF8.self)
        }
        guard try line() == "HAKCHI_SNES_FRONTEND_SUPPORT_V1", try line() == "CHALLENGE="+challenge.uuidString,
              try line() == "CONTEXT="+context, try line() == "HWID="+hwid else { throw SNESCompatibilitySupportFrame.failure() }
        var libraries:[String:Data]=[:],chains:[String:String]=[:],missing=Set<String>()
        for role in Self.roles {
            let fields=try line().components(separatedBy:" ")
            #if RECOVERY_DIAGNOSTIC
            FileHandle.standardError.write(Data(("Frontend evidence header: " + fields.joined(separator:" ") + "\n").utf8))
            #endif
            if fields == ["MISS",role.0] { missing.insert(role.0); continue }
            guard fields.count==5,fields[0]=="LIB",fields[1]==role.0 else { throw SNESCompatibilitySupportFrame.failure() }
            let paths=fields[2].components(separatedBy:">")
            guard (1...9).contains(paths.count),Set(paths).count==paths.count,
                  paths.first=="/lib/"+role.1 || paths.first=="/usr/lib/"+role.1,
                  paths.allSatisfy({Self.validPath($0,role:role)}),
                  let count=Int(fields[3]),String(count)==fields[3],(52...Self.maximumLibraryBytes).contains(count),
                  fields[4].count==64,SNESRuntimeBinding.hex(fields[4]), count < bytes.count-at else { throw SNESCompatibilitySupportFrame.failure() }
            let data=Data(bytes[at..<at+count]);at += count
            #if RECOVERY_DIAGNOSTIC
            FileHandle.standardError.write(Data(("Frontend evidence ELF " + role.0 + ": type=" + String(data[16]) + " flags=" + data[36..<40].map{String(format:"%02x",$0)}.joined() + "\n").utf8))
            #endif
            guard bytes[at]==10, BackupManifest.digest(data)==fields[4],
                  data.prefix(7)==Data([127,69,76,70,1,1,1]), data[16]==3,data[17]==0,data[18]==40,data[19]==0,
                  data[39]==5 else { throw SNESCompatibilitySupportFrame.failure() }
            at += 1;libraries[role.0]=data;chains[role.0]=fields[2]
        }
        guard try line()=="END",at==bytes.count else { throw SNESCompatibilitySupportFrame.failure() }
        self.raw=raw;self.libraries=libraries;self.chains=chains;self.missing=missing
    }
}


struct SNESFrontendSupportCapture: Sendable {
    let frame: SNESFrontendSupportFrame
    let frames: [Data]
    let challenges: [UUID]
    static func read(context:String,hwid:String,validate:@Sendable () async throws -> Void,
                     read:@Sendable (UUID) async throws -> Data) async throws -> Self {
        var frames:[Data]=[],challenges:[UUID]=[],first:SNESFrontendSupportFrame?
        for _ in 0..<2 {
            try Task.checkCancellation();try await validate()
            let nonce=UUID(),raw=try await read(nonce)
            try Task.checkCancellation();try await validate()
            let current=try SNESFrontendSupportFrame(raw,challenge:nonce,context:context,hwid:hwid)
            if let first {
                guard first.libraries==current.libraries, first.chains==current.chains, first.missing==current.missing else { throw SNESCompatibilitySupportFrame.failure() }
            } else { first=current }
            frames.append(raw);challenges.append(nonce)
        }
        guard let first,Set(challenges).count==2 else { throw SNESCompatibilitySupportFrame.failure() }
        return .init(frame:first,frames:frames,challenges:challenges)
    }
}
struct SNESFrontendConsoleSupport: Sendable {
    let capture: SNESFrontendSupportCapture
    let reports: [Data]
    let reportChallenges: [UUID]
}


enum SNESFrontendSupportCommand {
    static func read(challenge: UUID, context: String, hwid: String) throws -> String {
        try SNESCompatibilitySupportFrame.requireBinding(context: context, hwid: hwid)
        let coreCommand=try SNESCompatibilitySupportCommand.read(challenge:challenge,context:context,hwid:hwid)
        // Reuse the reviewed fixed helper/root/idle guards, stopping before its frame body.
        guard let marker=coreCommand.range(of:"printf 'HAKCHI_SNES_COMPAT_SUPPORT_V1") else {throw SNESCompatibilitySupportFrame.failure()}
        var script=String(coreCommand[..<marker.lowerBound]).replacingOccurrences(of:"set -eu",with:#"""
        set -eu
        frontend_stage=initial
        trap 'code=$?;if test "$code" -ne 0;then printf "FRONTEND_STOP=%s EXIT=%s\n" "$frontend_stage" "$code" >&2;fi' EXIT
        """#)
        script += #"""
        frontend_stage=usr-directory
        test -d /usr && test ! -L /usr && test -d /usr/lib && test ! -L /usr/lib
        frontend_stage=usr-mounts
        "$B" awk '$2=="/usr" || $2=="/usr/lib" || index($2,"/usr/lib/")==1 {bad=1} END {exit bad}' /proc/mounts
        valid_front() {
          role="$1";name="${2##*/}"
          test "${#name}" -le 128
          case "$2" in /lib/"$name"|/usr/lib/"$name") ;; *) return 1;; esac
          case "$role" in
        """# + "\n"
        for role in SNESFrontendSupportFrame.roles {
            script += "  " + role.0 + ") printf '%s\\n' \"$name\" | \"$B\" grep -Eq '^" + role.2 + "$';;\n"
        }
        script += #"""
            *) return 1;;
          esac
        }
        total_front=0
        read_front() {
          role="$1";first="$2";path='';frontend_stage="resolve-$role"
          for folder in /lib /usr/lib; do
            candidate="$folder/$first"
            if test -e "$candidate" || test -L "$candidate"; then path="$candidate";break;fi
          done
          if test -z "$path";then printf 'MISS %s\n' "$role";return 0;fi
          chain="$path";hops=0
          valid_front "$role" "$path"
          while test -L "$path";do
            hops=$((hops+1));test "$hops" -le 8
            next=$("$B" readlink "$path")
            case "$next" in /*) ;; */*) return 1;; *) next="${path%/*}/$next";;esac
            valid_front "$role" "$next"
            case ">$chain>" in *">$next>"*) return 1;;esac
            path="$next";chain="$chain>$path"
          done
          test -f "$path" && test ! -L "$path"
          test "$("$B" stat -c '%h:%u' "$path")" = 1:0
          frontend_stage="read-$role"
          count=$("$B" wc -c < "$path" | "$B" tr -d ' \n')
          test "$count" -ge 52 && test "$count" -le 8388608
          total_front=$((total_front+count));test "$total_front" -le 32505856
          sha=$("$B" sha256sum "$path");sha="${sha%% *}"
          printf 'LIB %s %s %s %s\n' "$role" "$chain" "$count" "$sha"
          "$B" cat "$path";printf '\n'
        }
        """# + "\n"
        script += "printf 'HAKCHI_SNES_FRONTEND_SUPPORT_V1\\nCHALLENGE=\(challenge.uuidString)\\nCONTEXT=\(context)\\nHWID=\(hwid)\\n'\n"
        for role in SNESFrontendSupportFrame.roles {script += "read_front " + role.0 + " " + role.1 + "\n"}
        script += "frontend_stage=final-menu\nno_game;test \"$menu_pid\" = \"$original_menu_pid\" || exit 83\nprintf 'END\\n'\n"
        return script
    }
}

import Foundation
import SwiftHakchiCore

/// Internal framing for fixed generated commands, never for a user-supplied shell command.
struct SNESOneGameStream {
    let command:String,input:Data
    init(script:String,body:Data=Data())throws {
        let source=Data(script.trimmingCharacters(in:.newlines).utf8)
        guard !source.isEmpty,source.count<=65536,!source.contains(0),body.count<=9*1024*1024 else {throw LegacyInspectionError.outputLimit}
        let hash=BackupManifest.digest(source)
        // This BusyBox head buffers beyond its limit. dd bs=1 preserves the following binary body.
        command = #"B=/mnt/swifthakchi/busybox; s=$("$B" dd bs=1 count=\#(source.count) 2>/dev/null); h=$(printf '%s' "$s" | "$B" sha256sum); [ "${h%% *}" = '\#(hash)' ] || exit 1; eval "$s""# + (body.isEmpty ? " </dev/null":"")
        input=source+body
        guard command.utf8.count<1020 else {throw LegacyInspectionError.outputLimit}
    }
}

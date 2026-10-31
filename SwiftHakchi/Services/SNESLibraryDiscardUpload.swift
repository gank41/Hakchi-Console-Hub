import Foundation
import SwiftHakchiCore

/// A fixed, bounded read of one operation's upload. Its report grants no deletion authority.
enum SNESLibraryDiscardUploadCommands {
    struct Request: Sendable {
        let script: String, id: UUID, contextSHA256: String, hwid: String, selectorSHA256: String, challenge: UUID
    }
    static func prepare(plan: SNESLibrarySyncPlan, contextSHA256: String, runtimeSHA256: String, challenge: UUID) throws -> Request {
        try plan.material.validate(sourcePolicy: .frozenRecovery)
        guard plan.before.selection.id != plan.material.menu.id else { throw SNESLibraryInventory.failure() }
        var script = try SNESLibraryInventoryCommands.prefix(context: contextSHA256, hwid: plan.before.hwid, runtime: runtimeSHA256)
        script += #"""
        D=/var/lib
        current_selection() {
          __SELECTION_CHECK__
        }
        parents() {
          q=${p%/*}
          while :;do
            case "$q" in "$D"|"$D"/*) ;; *) return 1;;esac
            if test -e "$q" || test -L "$q";then data_directory "$q";fi
            test "$q" != "$D" || break
            q=${q%/*}
          done
        }
        current_selection
        p="$N/menus/__ID__/.upload"
        parents
        upload_line='UPLOAD absent'
        if test -e "$p" || test -L "$p";then
          regular "$p"
          info=$("$B" stat -c '%d %i %Y %Z %a %s' "$p");set -- $info;test "$#" -eq 6
          test "$1" = "$device";bytes=$6;test "$bytes" -ge 0;test "$bytes" -le 4194400
          exec 7< "$p"
          test "$("$B" stat -L -c '%u' "/proc/$$/fd/7")" = 0
          test "$("$B" stat -L -c '%h' "/proc/$$/fd/7")" = 1
          test "$("$B" stat -L -c '%d %i %Y %Z %a %s' "/proc/$$/fd/7")" = "$info"
          value=$("$B" sha256sum "/proc/$$/fd/7");upload_hash=${value%% *}
          test "${#upload_hash}" -eq 64;case "$upload_hash" in *[!0-9a-f]*) exit 1;;esac
          test "$("$B" stat -L -c '%u' "/proc/$$/fd/7")" = 0
          test "$("$B" stat -L -c '%h' "/proc/$$/fd/7")" = 1
          test "$("$B" stat -L -c '%d %i %Y %Z %a %s' "/proc/$$/fd/7")" = "$info"
          regular "$p";parents
          test "$("$B" stat -c '%d %i %Y %Z %a %s' "$p")" = "$info"
          exec 7<&-
          upload_line="UPLOAD $bytes $upload_hash"
        else
          parents;test ! -e "$p";test ! -L "$p"
        fi
        current_selection;no_game
        printf 'SWIFTHAKCHI_SNES_UPLOAD_V1 __NONCE__\nCONTEXT __CONTEXT__\nHWID __HWID__\nMENU __ID__\nSELECTOR __SELECTOR__\n%s\nEND\n' "$upload_line"
        """#
        script = script.replacingOccurrences(of: "__SELECTION_CHECK__", with: try SNESLibraryCleanupCommands.checkedSelectionScript(plan.before.selection))
        for (key, value) in [("__ID__", plan.material.menu.id.uuidString), ("__NONCE__", challenge.uuidString),
            ("__CONTEXT__", contextSHA256), ("__HWID__", plan.before.hwid), ("__SELECTOR__", plan.before.selection.selectorSHA256)] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        script += "\n"
        guard script.utf8.count <= 65536 else { throw SNESLibraryInventory.failure() }
        return .init(script: script, id: plan.material.menu.id, contextSHA256: contextSHA256, hwid: plan.before.hwid,
            selectorSHA256: plan.before.selection.selectorSHA256, challenge: challenge)
    }
}
struct SNESLibraryDiscardUploadInspection: Sendable {
    let raw: Data, upload: SNESLibraryDiscardPlan.Upload?, measuredAt: Date
    init(_ raw: Data, request: SNESLibraryDiscardUploadCommands.Request, measuredAt: Date = Date()) throws {
        guard raw.count <= 2048, let text = String(data: raw, encoding: .ascii),
              text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else { throw SNESLibraryInventory.failure() }
        let rows = text.components(separatedBy: "\n")
        guard rows.count == 8, rows[0] == "SWIFTHAKCHI_SNES_UPLOAD_V1 " + request.challenge.uuidString,
              rows[1] == "CONTEXT " + request.contextSHA256, rows[2] == "HWID " + request.hwid,
              rows[3] == "MENU " + request.id.uuidString, rows[4] == "SELECTOR " + request.selectorSHA256,
              rows[6] == "END", rows[7].isEmpty else { throw SNESLibraryInventory.failure() }
        let parts = rows[5].components(separatedBy: " ")
        if parts == ["UPLOAD", "absent"] { upload = nil }
        else {
            guard parts.count == 3, parts[0] == "UPLOAD", let n = Int(parts[1]), String(n) == parts[1],
                  (0...4194400).contains(n), SNESDataSnapshotChunk.isDigest(parts[2]) else { throw SNESLibraryInventory.failure() }
            upload = .init(byteCount: n, sha256: parts[2])
        }
        self.raw = raw; self.measuredAt = measuredAt
    }
}

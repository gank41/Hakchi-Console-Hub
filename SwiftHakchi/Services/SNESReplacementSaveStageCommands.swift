import Foundation
import SwiftHakchiCore

/// An inactive staging request only. This generator does not open USB, grant a
/// write permit, publish a save, or establish that a live console is current.
enum SNESReplacementSaveStageCommands {
    struct Request: Sendable {
        let script: String, input: Data, tableBytes: Int, receipt: Data
    }

    /// A claimed permit permits one send only. The caller must retain the
    /// recovery record and mark the result uncertain if this operation fails.
    static func dispatch(request: Request, before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.StagePermit,
                         send: (Request) async throws -> Data) async throws -> SNESReplacementSaveStageReceipt {
        try Task.checkCancellation()
        try permit.claimDispatch(request: request, before: before)
        try Task.checkCancellation()
        let raw = try await send(request)
        try Task.checkCancellation()
        try permit.require(request: request, before: before)
        return try SNESReplacementSaveStageReceipt(raw, request: request)
    }

    static func prepare(review: SNESReplacementSaveEnvelope, group: Int, before: SNESLibraryInventory,
                        runtimeSHA256: String, challenge: UUID, stageID: UUID) throws -> Request {
        try review.validate(); try review.plan.requireCurrent(before)
        let payload = try SNESReplacementSavePayload.prepare(review: review, group: group, challenge: challenge)
        let block = before.capacity.blockSize
        guard before.capacity.namespaceReady, before.excludedMenuID == nil, !before.incompleteNamespace,
              before.hwid == payload.destinationHWID, (512...65536).contains(block), block.nonzeroBitCount == 1,
              payload.fileCount > 0, payload.fileCount <= 4096 else { throw SNESLibraryInventory.failure() }
        let needed = Int64(payload.body.count) + Int64(payload.table.count) + (Int64(payload.fileCount) + 3) * block + 2 * 1024 * 1024
        guard needed <= before.totalBytes else { throw SNESLibraryInventory.failure() }
        let selectionCheck = selectionCheck(before.selection)
        let fileLimit = (max(1, payload.largestFileBytes, payload.table.count) + 511) / 512
        var script = try SNESLibraryInventoryCommands.prefix(context: before.contextSHA256, hwid: before.hwid, runtime: runtimeSHA256)
        script += "current_selection() {\n" + selectionCheck + "}\ncurrent_selection\numask 077\nulimit -f \(fileLimit)\n"
        script += #"""
        data_directory "${N%/*}";data_directory "$N";data_directory "$N/objects";data_directory "$N/menus"
        space=$("$B" stat -f -c '%S %b %a' /var/lib);set -- $space;test "$#" -eq 3
        test "$1" = __BLOCK__;test "$3" -ge 0;test "$3" -le 1048576
        test "$(( $1 * $3 ))" -ge __NEEDED__
        root="$N/save-staging";stage="$root/__ID__"
        if test -e "$root" || test -L "$root";then data_directory "$root";else "$B" mkdir -m 0700 "$root";data_directory "$root";fi
        test ! -e "$stage" && test ! -L "$stage"
        "$B" mkdir -m 0700 "$stage";data_directory "$stage"
        namespace_token=$("$B" stat -c '%d %i %a' "$N")
        root_token=$("$B" stat -c '%d %i %a' "$root")
        stage_token=$("$B" stat -c '%d %i %a' "$stage")
        roots() {
          data_directory "$N";data_directory "$root";data_directory "$stage"
          test "$("$B" stat -c '%d %i %a' "$N")" = "$namespace_token"
          test "$("$B" stat -c '%d %i %a' "$root")" = "$root_token"
          test "$("$B" stat -c '%d %i %a' "$stage")" = "$stage_token"
        }
        exec 3<&0
        test ! -e "$stage/plan" && test ! -L "$stage/plan"
        set -C
        "$B" dd bs=1 count=__TABLE_BYTES__ <&3 > "$stage/plan" 2>/dev/null
        set +C
        roots;regular "$stage/plan";test "$("$B" stat -c '%d' "$stage/plan")" = "$device"
        plan_token=$("$B" stat -c '%d %i %a' "$stage/plan")
        test "$("$B" stat -c '%s' "$stage/plan")" = __TABLE_BYTES__
        value=$("$B" sha256sum "$stage/plan");test "${value%% *}" = '__TABLE_HASH__'
        exec 4< "$stage/plan"
        IFS= read -r line <&4;test "$line" = 'SWIFTHAKCHI_SNES_SAVE_GROUP_V1'
        IFS= read -r line <&4;test "$line" = 'CHALLENGE __NONCE__'
        IFS= read -r line <&4;test "$line" = 'HWID __HWID__'
        IFS= read -r line <&4;test "$line" = 'REVIEW __REVIEW__'
        IFS= read -r line <&4;test "$line" = 'FILES __COUNT__'
        count=0
        while IFS=' ' read -r kind path bytes hash mode modified extra <&4;do
          if test "$kind" = END;then test -z "$path$bytes$hash$mode$modified$extra";break;fi
          test "$kind" = FILE && test -n "$path" && test -n "$bytes" && test -n "$hash" && test -z "$extra"
          case "$path" in *[!0-9a-f]*|'') exit 1;; esac
          case "$bytes" in *[!0-9]*|'') exit 1;; esac
          case "$hash" in *[!0-9a-f]*|'') exit 1;; esac
          test "${#hash}" -eq 64 && test "$bytes" -le 16777216
          roots;current_selection;no_game
          name=$(printf '%04d' "$count");output="$stage/$name"
          test ! -e "$output" && test ! -L "$output"
          set -C;exec 7> "$output";set +C
          output_token=$("$B" stat -c '%d %i %a' "$output")
          written=0;remaining=$bytes
          while test "$remaining" -ge 512;do
            blocks=$((remaining / 512))
            "$B" dd ibs=512 obs=65536 count="$blocks" conv=fsync <&3 >&7 2>/dev/null
            progress=$("$B" stat -L -c '%s' "/proc/$$/fd/7")
            test "$progress" -gt "$written";test "$progress" -le "$bytes"
            written=$progress;remaining=$((bytes - written))
          done
          if test "$remaining" -gt 0;then "$B" dd ibs=1 obs=65536 count="$remaining" conv=fsync <&3 >&7 2>/dev/null;fi
          exec 7>&-
          roots;regular "$output";test "$("$B" stat -c '%d' "$output")" = "$device"
          test "$("$B" stat -c '%d %i %a' "$output")" = "$output_token"
          test "$("$B" stat -c '%s' "$output")" = "$bytes"
          value=$("$B" sha256sum "$output");test "${value%% *}" = "$hash"
          count=$((count + 1))
        done
        test "$kind" = END && test "$count" = __COUNT__
        if IFS= read -r line <&4;then exit 1;fi;exec 4<&-
        IFS= read -r ending <&3;test "$ending" = 'END __NONCE__';exec 3<&-
        roots;current_selection;no_game
        "$B" sync
        roots;current_selection;no_game
        regular "$stage/plan";test "$("$B" stat -c '%d' "$stage/plan")" = "$device"
        value=$("$B" sha256sum "$stage/plan");test "${value%% *}" = '__TABLE_HASH__'
        exec 4< "$stage/plan"
        for header in 1 2 3 4 5;do IFS= read -r line <&4;done
        verified=0
        while IFS=' ' read -r kind path bytes hash mode modified extra <&4;do
          if test "$kind" = END;then break;fi
          test "$kind" = FILE && test -z "$extra"
          roots;current_selection;no_game
          name=$(printf '%04d' "$verified");output="$stage/$name"
          regular "$output";test "$("$B" stat -c '%d' "$output")" = "$device"
          test "$("$B" stat -c '%s' "$output")" = "$bytes"
          value=$("$B" sha256sum "$output");test "${value%% *}" = "$hash"
          verified=$((verified + 1))
        done
        test "$kind" = END && test "$verified" = __COUNT__
        if IFS= read -r line <&4;then exit 1;fi;exec 4<&-
        roots;current_selection;no_game
        entries=$("$B" find "$stage" -mindepth 1 -maxdepth 1 -print | "$B" wc -l)
        test "$entries" -eq $((__COUNT__ + 1))
        roots;current_selection;no_game
        regular "$stage/plan";test "$("$B" stat -c '%d %i %a' "$stage/plan")" = "$plan_token"
        value=$("$B" sha256sum "$stage/plan");test "${value%% *}" = '__TABLE_HASH__'
        printf '%s\n' 'SWIFTHAKCHI_SNES_SAVE_STAGED_V1' 'CHALLENGE __NONCE__' 'CONTEXT __CONTEXT__' 'HWID __HWID__' 'REVIEW __REVIEW__' 'STAGE __ID__' 'TABLE __TABLE_HASH__' 'FILES __COUNT__' 'END'
        """#
        for (key, value) in [("__BLOCK__", String(block)), ("__NEEDED__", String(needed)), ("__ID__", stageID.uuidString),
                             ("__TABLE_BYTES__", String(payload.table.count)), ("__TABLE_HASH__", payload.tableSHA256),
                             ("__NONCE__", challenge.uuidString), ("__HWID__", before.hwid), ("__REVIEW__", review.sha256),
                             ("__CONTEXT__", before.contextSHA256), ("__COUNT__", String(payload.fileCount))] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        let input = payload.table + payload.body + Data(("END " + challenge.uuidString + "\n").utf8)
        let receipt = Data(("SWIFTHAKCHI_SNES_SAVE_STAGED_V1\nCHALLENGE \(challenge.uuidString)\nCONTEXT \(before.contextSHA256)\nHWID \(before.hwid)\nREVIEW \(review.sha256)\nSTAGE \(stageID.uuidString)\nTABLE \(payload.tableSHA256)\nFILES \(payload.fileCount)\nEND\n").utf8)
        guard script.utf8.count <= 65536 else { throw SNESLibraryInventory.failure() }
        try review.validate(); try review.plan.requireCurrent(before)
        return .init(script: script + "\n", input: input, tableBytes: payload.table.count, receipt: receipt)
    }

    static func selectionCheck(_ old: SNESLibraryInventory.Selection) -> String {
        if old.selectorSHA256 == BackupManifest.digest(Data()) {
            return "test ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\"\ntest ! -e \"$L/active-menu\" && test ! -L \"$L/active-menu\"\n"
        }
        let selected = old.kind == .legacy ? "$L/active-menu" : "$N/active-menu"
        return (old.kind == .legacy ? "test ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\"\n" : "")
            + "regular \"\(selected)\"\nvalue=$(\"$B\" sha256sum \"\(selected)\");test \"${value%% *}\" = '\(old.selectorSHA256)'\n"
    }
}

/// Exact response parsing; a receipt still needs an independently verified
/// native session before it can be treated as console evidence.
struct SNESReplacementSaveStageReceipt: Sendable {
    init(_ raw: Data, request: SNESReplacementSaveStageCommands.Request) throws {
        guard raw == request.receipt else { throw SNESLibraryInventory.failure() }
    }
}

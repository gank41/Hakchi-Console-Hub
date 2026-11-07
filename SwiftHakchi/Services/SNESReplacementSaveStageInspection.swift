import Foundation
import SwiftHakchiCore

/// A read-only inspection request. No outcome authorizes a retry or proves
/// that a save has been published into the game profile.
enum SNESReplacementSaveStageInspection {
    struct Request: Sendable {
        let script: String, input: Data, absent: Data, incomplete: Data, verified: Data
        private let contextSHA256: String, hwid: String, runtimeSHA256: String, stateSHA256: String

        fileprivate init(script: String, input: Data, absent: Data, incomplete: Data, verified: Data,
                         contextSHA256: String, hwid: String, runtimeSHA256: String, stateSHA256: String) {
            self.script = script; self.input = input; self.absent = absent; self.incomplete = incomplete; self.verified = verified
            self.contextSHA256 = contextSHA256; self.hwid = hwid; self.runtimeSHA256 = runtimeSHA256; self.stateSHA256 = stateSHA256
        }

        func requireBinding(contextSHA256: String, hwid: String, runtimeSHA256: String) throws {
            guard self.contextSHA256 == contextSHA256, self.hwid == hwid, self.runtimeSHA256 == runtimeSHA256 else {
                throw SNESLibraryInventory.failure()
            }
        }

        func require(_ context: SNESLibraryContext) throws {
            try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
            try requireBinding(contextSHA256: context.sha256, hwid: context.installation.expected.hwid,
                               runtimeSHA256: context.installation.expected.runtimeSHA256)
        }

        func requireInventory(_ inventory: SNESLibraryInventory) throws {
            guard inventory.contextSHA256 == contextSHA256, inventory.hwid == hwid, inventory.stateSHA256 == stateSHA256,
                  inventory.excludedMenuID == nil, !inventory.incompleteNamespace else { throw SNESLibraryInventory.failure() }
        }
    }

    /// Dispatch is read-only. A caller must separately attest its live session;
    /// this boundary checks the identity and accepts only the exact response.
    static func dispatch(_ request: Request, contextSHA256: String, hwid: String, runtimeSHA256: String,
                         read: (Request) async throws -> Data) async throws -> SNESReplacementSaveStageInspectionReceipt.Outcome {
        try Task.checkCancellation()
        try request.requireBinding(contextSHA256: contextSHA256, hwid: hwid, runtimeSHA256: runtimeSHA256)
        let raw = try await read(request)
        try Task.checkCancellation()
        try request.requireBinding(contextSHA256: contextSHA256, hwid: hwid, runtimeSHA256: runtimeSHA256)
        return try SNESReplacementSaveStageInspectionReceipt(raw, request: request).outcome
    }

    static func prepare(review: SNESReplacementSaveEnvelope, group: Int, before: SNESLibraryInventory,
                        runtimeSHA256: String, challenge: UUID, stageID: UUID, stagedChallenge: UUID) throws -> Request {
        try review.validate(); try review.plan.requireCurrent(before)
        let payload = try SNESReplacementSavePayload.prepare(review: review, group: group, challenge: challenge)
        guard before.capacity.namespaceReady, before.excludedMenuID == nil, !before.incompleteNamespace,
              before.hwid == payload.destinationHWID, let text = String(data: payload.table, encoding: .ascii) else {
            throw SNESLibraryInventory.failure()
        }
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 7, lines[1] == "CHALLENGE " + challenge.uuidString, lines.last == "" else { throw SNESLibraryInventory.failure() }
        lines[1] = "CHALLENGE " + stagedChallenge.uuidString
        let stagedTable = Data(lines.joined(separator: "\n").utf8)
        guard stagedTable.count == payload.table.count else { throw SNESLibraryInventory.failure() }
        let tableWithoutLastNewline = Data(payload.table.dropLast())
        let tableHash = BackupManifest.digest(tableWithoutLastNewline)
        var script = try SNESLibraryInventoryCommands.prefix(context: before.contextSHA256, hwid: before.hwid, runtime: runtimeSHA256)
        script += "current_selection() {\n" + SNESReplacementSaveStageCommands.selectionCheck(before.selection) + "}\ncurrent_selection\n"
        script += #"""
        data_directory "${N%/*}";data_directory "$N";data_directory "$N/objects";data_directory "$N/menus"
        table=$("$B" dd bs=1 count=__TABLE_BYTES__ 2>/dev/null)
        value=$(printf '%s' "$table" | "$B" sha256sum);test "${value%% *}" = '__TABLE_HASH__'
        root="$N/save-staging";stage="$root/__ID__"
        result() { printf '%s\n' 'SWIFTHAKCHI_SNES_SAVE_STAGE_INSPECTION_V1' 'CHALLENGE __NONCE__' 'CONTEXT __CONTEXT__' 'HWID __HWID__' 'REVIEW __REVIEW__' 'STAGE __ID__' "STATUS $1" 'END'; }
        if test ! -e "$root" && test ! -L "$root";then current_selection;no_game;result ABSENT;exit 0;fi
        data_directory "$root"
        if test ! -e "$stage" && test ! -L "$stage";then current_selection;no_game;result ABSENT;exit 0;fi
        data_directory "$stage"
        namespace_token=$("$B" stat -c '%d %i %a' "$N")
        root_token=$("$B" stat -c '%d %i %a' "$root")
        stage_token=$("$B" stat -c '%d %i %a' "$stage")
        roots() {
          data_directory "$N";data_directory "$root";data_directory "$stage"
          test "$("$B" stat -c '%d %i %a' "$N")" = "$namespace_token"
          test "$("$B" stat -c '%d %i %a' "$root")" = "$root_token"
          test "$("$B" stat -c '%d %i %a' "$stage")" = "$stage_token"
        }
        roots;current_selection;no_game
        if test ! -e "$stage/plan" && test ! -L "$stage/plan";then
          entries=$("$B" find "$stage" -mindepth 1 -maxdepth 1 -print | "$B" wc -l)
          test "$entries" -eq 0;roots;current_selection;no_game
          test ! -e "$stage/plan" && test ! -L "$stage/plan"
          entries=$("$B" find "$stage" -mindepth 1 -maxdepth 1 -print | "$B" wc -l)
          test "$entries" -eq 0;roots;current_selection;no_game;result INCOMPLETE;exit 0
        fi
        regular "$stage/plan";test "$("$B" stat -c '%d' "$stage/plan")" = "$device"
        plan_size=$("$B" stat -c '%s' "$stage/plan")
        if test "$plan_size" -lt __TABLE_BYTES__;then
          info=$("$B" stat -c '%d %i %Y %Z %a %s' "$stage/plan")
          partial_digest=$("$B" sha256sum "$stage/plan")
          entries=$("$B" find "$stage" -mindepth 1 -maxdepth 1 -print | "$B" wc -l)
          test "$entries" -eq 1;roots;current_selection;no_game
          regular "$stage/plan";test "$("$B" stat -c '%d %i %Y %Z %a %s' "$stage/plan")" = "$info"
          test "$("$B" sha256sum "$stage/plan")" = "$partial_digest"
          roots;current_selection;no_game;result INCOMPLETE;exit 0
        fi
        test "$plan_size" -eq __TABLE_BYTES__
        plan_token=$("$B" stat -c '%d %i %a' "$stage/plan")
        plan_check() {
          roots;regular "$stage/plan";test "$("$B" stat -c '%d' "$stage/plan")" = "$device"
          test "$("$B" stat -c '%d %i %a' "$stage/plan")" = "$plan_token"
          value=$("$B" sha256sum "$stage/plan");test "${value%% *}" = '__STAGED_HASH__'
        }
        plan_check
        line=0;count=0;present=0;ended=0;unfinished=0;stopped=0
        while IFS=' ' read -r kind path bytes hash mode modified extra;do
          line=$((line + 1));if test "$line" -le 5;then continue;fi
          if test "$kind" = END;then test -z "$path$bytes$hash$mode$modified$extra";ended=1;break;fi
          test "$kind" = FILE && test -n "$bytes" && test -n "$hash" && test -z "$extra"
          roots;current_selection;no_game
          name=$(printf '%04d' "$count");file="$stage/$name"
          if test ! -e "$file" && test ! -L "$file";then
            unfinished=1;stopped=1;count=$((count + 1));continue
          fi
          test "$stopped" = 0
          regular "$file";test "$("$B" stat -c '%d' "$file")" = "$device"
          size=$("$B" stat -c '%s' "$file");test "$size" -le "$bytes"
          info=$("$B" stat -c '%d %i %Y %Z %a %s' "$file")
          value=$("$B" sha256sum "$file")
          if test "$size" = "$bytes";then test "${value%% *}" = "$hash";else unfinished=1;stopped=1;fi
          regular "$file";test "$("$B" stat -c '%d %i %Y %Z %a %s' "$file")" = "$info"
          again=$("$B" sha256sum "$file");test "$again" = "$value"
          regular "$file";test "$("$B" stat -c '%d %i %Y %Z %a %s' "$file")" = "$info"
          count=$((count + 1));present=$((present + 1))
        done <<SWIFTHAKCHI_INSPECTION_TABLE
        $table
        SWIFTHAKCHI_INSPECTION_TABLE
        test "$ended" = 1 && test "$count" = __COUNT__
        entries=$("$B" find "$stage" -mindepth 1 -maxdepth 1 -print | "$B" wc -l)
        test "$entries" -eq $((present + 1))
        plan_check;current_selection;no_game
        if test "$unfinished" = 1;then result INCOMPLETE;exit 0;fi
        result VERIFIED
        """#
        for (key, value) in [("__TABLE_BYTES__", String(payload.table.count)), ("__TABLE_HASH__", tableHash),
                             ("__STAGED_HASH__", BackupManifest.digest(stagedTable)), ("__ID__", stageID.uuidString),
                             ("__NONCE__", challenge.uuidString), ("__HWID__", before.hwid), ("__REVIEW__", review.sha256),
                             ("__CONTEXT__", before.contextSHA256), ("__COUNT__", String(payload.fileCount))] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        func receipt(_ status: String) -> Data {
            Data(("SWIFTHAKCHI_SNES_SAVE_STAGE_INSPECTION_V1\nCHALLENGE \(challenge.uuidString)\nCONTEXT \(before.contextSHA256)\nHWID \(before.hwid)\nREVIEW \(review.sha256)\nSTAGE \(stageID.uuidString)\nSTATUS \(status)\nEND\n").utf8)
        }
        guard script.utf8.count <= 65536 else { throw SNESLibraryInventory.failure() }
        try review.validate(); try review.plan.requireCurrent(before)
        return .init(script: script + "\n", input: payload.table, absent: receipt("ABSENT"), incomplete: receipt("INCOMPLETE"), verified: receipt("VERIFIED"),
                     contextSHA256: before.contextSHA256, hwid: before.hwid, runtimeSHA256: runtimeSHA256, stateSHA256: before.stateSHA256)
    }
}

struct SNESReplacementSaveStageInspectionReceipt: Sendable {
    enum Outcome: Equatable, Sendable { case absent, incomplete, verified }
    let outcome: Outcome
    init(_ raw: Data, request: SNESReplacementSaveStageInspection.Request) throws {
        if raw == request.absent { outcome = .absent }
        else if raw == request.incomplete { outcome = .incomplete }
        else if raw == request.verified { outcome = .verified }
        else { throw SNESLibraryInventory.failure() }
    }
}

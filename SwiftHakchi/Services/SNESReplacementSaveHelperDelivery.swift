import Foundation
import SwiftHakchiCore

/// Prepared delivery into temporary runtime memory only. A request is inert:
/// it grants no permission to contact the console or publish saved progress.
enum SNESReplacementSaveHelperDelivery {
    struct Request: Sendable {
        let script: String, input: Data, receipt: Data
        let hwid: String, contextSHA256: String, runtimeSHA256: String, challenge: UUID
        fileprivate init(script: String, input: Data, receipt: Data, hwid: String, contextSHA256: String, runtimeSHA256: String, challenge: UUID) {
            self.script = script; self.input = input; self.receipt = receipt; self.hwid = hwid
            self.contextSHA256 = contextSHA256; self.runtimeSHA256 = runtimeSHA256; self.challenge = challenge
        }
    }

    /// The caller still needs the checked native session and attachment. Once
    /// claimed, a permit cannot retry even if sending or receipt checks fail.
    static func dispatch(request: Request, before: SNESLibraryInventory,
                         permit: SNESReplacementSaveJournal.HelperDeliveryPermit,
                         send: (Request) async throws -> Data) async throws {
        try Task.checkCancellation()
        try permit.claimDispatch(request: request, before: before)
        try Task.checkCancellation()
        let result = try await send(request)
        try Task.checkCancellation(); try permit.require(request: request, before: before)
        guard result == request.receipt else { throw SNESLibraryInventory.failure() }
    }

    static func prepare(helper: SNESReplacementSaveHelper, hwid: String, contextSHA256: String,
                        runtimeSHA256: String, selection: SNESLibraryInventory.Selection, challenge: UUID) throws -> Request {
        _ = try SNESReplacementSaveHelper.validate(helper.bytes)
        var script = try SNESLibraryInventoryCommands.prefix(context: contextSHA256, hwid: hwid, runtime: runtimeSHA256)
        script += "current_selection() {\n" + SNESReplacementSaveStageCommands.selectionCheck(selection) + "}\nM=/mnt\n"
        script += "# SNES_HELPER_DELIVERY_BODY\n"
        script += #"""
        umask 077
        directory "$M";directory "$R"
        test "$("$B" stat -c '%d' "$R")" = "$("$B" stat -c '%d' "$M")"
        "$B" awk '$2=="/mnt" {n++;if($3!="tmpfs"||!index("," $4 ",",",rw,")||index("," $4 ",",",noexec,"))bad=1} END {exit !(n==1&&!bad)}' /proc/mounts
        current_selection;no_game
        H="$R/snes-save-profile-switch"
        helper_check() {
          regular "$H";test "$("$B" stat -c '%s' "$H")" = __BYTES__
          case "$("$B" stat -c '%d %i %a' "$H")" in *' 700') :;; *) return 1;; esac
          value=$("$B" sha256sum "$H");test "${value%% *}" = '__HASH__'
        }
        result() { printf '%s\n' 'SWIFTHAKCHI_SNES_SAVE_HELPER_READY_V1' 'CHALLENGE __NONCE__' 'CONTEXT __CONTEXT__' 'HWID __HWID__' 'HELPER __HASH__' 'END'; }
        if test -e "$H" || test -L "$H";then
          helper_check;exec 3<&0
          value=$("$B" dd bs=1 count=__BYTES__ <&3 2>/dev/null | "$B" sha256sum);test "${value%% *}" = '__HASH__'
          IFS= read -r ending <&3;test "$ending" = 'END __NONCE__'
          if IFS= read -r extra <&3;then exit 1;fi;exec 3<&-
          helper_check;current_selection;no_game;result;exit 0
        fi
        test ! -e "$H" && test ! -L "$H"
        exec 3<&0
        set -C;"$B" dd bs=1 count=__BYTES__ <&3 > "$H" 2>/dev/null;set +C
        regular "$H";test "$("$B" stat -c '%s' "$H")" = __BYTES__
        value=$("$B" sha256sum "$H");test "${value%% *}" = '__HASH__'
        IFS= read -r ending <&3;test "$ending" = 'END __NONCE__'
        if IFS= read -r extra <&3;then exit 1;fi;exec 3<&-
        current_selection;no_game;"$B" chmod 700 "$H"
        helper_check;current_selection;no_game;result
        """# + "\n"
        for (key, value) in [("__BYTES__", String(helper.bytes.count)), ("__HASH__", SNESReplacementSaveHelper.sha256),
                             ("__NONCE__", challenge.uuidString), ("__CONTEXT__", contextSHA256), ("__HWID__", hwid)] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        let receipt = Data("SWIFTHAKCHI_SNES_SAVE_HELPER_READY_V1\nCHALLENGE \(challenge.uuidString)\nCONTEXT \(contextSHA256)\nHWID \(hwid)\nHELPER \(SNESReplacementSaveHelper.sha256)\nEND\n".utf8)
        guard script.utf8.count <= 65536 else { throw SNESLibraryInventory.failure() }
        return .init(script: script, input: helper.bytes + Data(("END " + challenge.uuidString + "\n").utf8), receipt: receipt,
                     hwid: hwid, contextSHA256: contextSHA256, runtimeSHA256: runtimeSHA256, challenge: challenge)
    }
}

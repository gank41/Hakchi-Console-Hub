import Foundation
import SwiftHakchiCore

/// Fixed target inspection and separately scoped removal. No menu restart or firmware operation.
enum SNESLibraryCleanupCommands {
    struct Request: Sendable {
        let script: String, body: Data
        func stream() throws -> SNESOneGameStream { try .init(script: script, body: body) }
    }
    static func path(_ logical: String) -> String {
        if logical == "namespace" { return SNESLibraryMenu.namespace }
        if logical.hasPrefix("clover/") { return "/var/lib/" + logical }
        if logical.hasPrefix("legacy/") { return "/var/lib/swifthakchi/snes-v1/" + logical.dropFirst(7) }
        return SNESLibraryMenu.namespace + "/" + logical
    }
    static func checkedSelectionScript(_ selection: SNESLibraryInventory.Selection) throws -> String {
        guard BackupManifest.digest(try selection.bytes()) == selection.selectorSHA256 else { throw SNESLibraryInventory.failure() }
        let selectionPath: String?
        var selectionCheck: String
        switch selection.kind {
        case .legacy:
            selectionPath = "$L"
            selectionCheck = "test ! -e \"$N/active-menu\";test ! -L \"$N/active-menu\"\n"
        case .library:
            selectionPath = "$N"; selectionCheck = ""
        case .builtin:
            if selection.selectorSHA256 == BackupManifest.digest(Data()) {
                selectionPath = nil
                selectionCheck = "test ! -e \"$N/active-menu\";test ! -L \"$N/active-menu\";test ! -e \"$L/active-menu\";test ! -L \"$L/active-menu\""
            } else { selectionPath = "$N"; selectionCheck = "" }
        }
        if let selectionPath {
            selectionCheck += "data_directory \"" + selectionPath + "/..\";data_directory \"" + selectionPath + "\"\nregular \"" + selectionPath + "/active-menu\"\nvalue=$(\"$B\" sha256sum \"" + selectionPath + "/active-menu\");test \"${value%% *}\" = '__SELECTOR__'"
        }
        return selectionCheck
    }
    static func preview<Scope: SNESLibraryRetirementScope>(scope: Scope, contextSHA256: String, runtimeSHA256: String, challenge: UUID) throws -> Request {
        try scope.validateSources()
        func hex(_ text: String) -> String { Data(text.utf8).map { String(format: "%02x", $0) }.joined() }
        var rows: [String] = []
        for (index, file) in scope.fileTargets.enumerated() {
            rows.append("F \(index) \(Data(file.path.utf8).base64EncodedString()) \(hex(path(file.path))) \(file.byteCount) \(file.sha256)")
        }
        for (index, name) in scope.directories.enumerated() { rows.append("D \(index) \(Data(name.utf8).base64EncodedString()) \(hex(path(name)))") }
        for (index, menu) in scope.protectedMenus.enumerated() {
            guard let description = menu.descriptionSHA256 else { throw SNESLibraryInventory.failure() }
            rows.append("M \(index) \(menu.id.uuidString) \(menu.treeSHA256) \(description) -")
        }
        rows.append("END")
        let body = Data(rows.joined(separator: "\n").utf8)
        guard body.count <= 8 * 1024 * 1024 else { throw SNESLibraryInventory.failure() }
        let root = scope.retiredRootPath.isEmpty ? "" : path(scope.retiredRootPath)
        let selectionCheck = try checkedSelectionScript(scope.selection)
        let child = #"""
        set -eu
        set -o pipefail
        trap 'r=$?;if test "$r" -ne 0;then printf "INVALID\n";fi' EXIT
        printf '%s' "$1" | "$2" od -An -tx1 -v | "$2" tr -d ' \n'
        printf '\n'
        """#
        var script = try SNESLibraryInventoryCommands.prefix(context: contextSHA256, hwid: scope.hwid, runtime: runtimeSHA256)
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
        # This is the last input item, with no following binary record for head to consume.
        table=$("$B" head -c __BYTES__)
        value=$(printf '%s' "$table" | "$B" sha256sum);test "${value%% *}" = '__TABLE__'
        root=__ROOT__
        resolve() {
          logical=$(printf '%s' "$1" | "$B" base64 -d)
          case "$logical" in
            namespace) p="$N";;
            legacy/*) p="$L/${logical#legacy/}";;
            menus|objects|descriptions|menus/*|objects/*|descriptions/*) p="$N/$logical";;
            *) return 1;;
          esac
        }
        members() {
          test -n "$root" || return 0
          p="$root";parents
          if test ! -e "$root" && test ! -L "$root";then return 0;fi
          data_directory "$root"
          (
            set -eu
            printf '%s\nNODES\n' "$table"
            "$B" find "$root" -xdev -exec "$B" sh -c __CHILD__ -- '{}' "$B" \;
          ) | "$B" awk '
            $0=="NODES" {scan=1;next}
            !scan {if($1=="F"||$1=="D")allowed[$4]=1;next}
            scan {if(!allowed[$0]||seen[$0]++||++count>8192)bad=1}
            END {exit bad}'
        }
        references() {
          for store in "$N" "$N/menus" "$N/descriptions";do
            if test -e "$store" || test -L "$store";then data_directory "$store"
            else test '__RETIRE_NS__' = 1;fi
          done
          while IFS=' ' read -r kind index encoded absolute bytes hash extra;do
            test -z "$extra"
            if test "$kind" = M;then
              p="$N/menus/$encoded/menu.manifest";parents;regular "$p"
              value=$("$B" sha256sum "$p");test "${value%% *}" = "$absolute"
              p="$N/descriptions/$encoded.json";parents;regular "$p"
              value=$("$B" sha256sum "$p");test "${value%% *}" = "$bytes"
              if test "$graphs_checked" = 0;then
                folder=$("$B" sh "$R/library-selector" "$encoded" "$absolute")
                test "$folder" = "$N/menus/$encoded/pages/000"
              fi
            fi
          done <<SWIFTHAKCHI_REFERENCE_ROOTS
        $table
        SWIFTHAKCHI_REFERENCE_ROOTS
          (
            set -eu
            printf '%s\nNODES\n' "$table"
            if test -d "$N/menus";then
              "$B" find "$N/menus" -mindepth 1 -maxdepth 1 -exec "$B" sh -c 'p=$1;printf "%s\n" "${p##*/}"' -- '{}' \;
            fi
          ) | "$B" awk -v old='__OLD_V2__' '
            $0=="NODES" {scan=1;next}
            !scan {if($1=="M")allowed[$3]=1;next}
            scan {if((!allowed[$0]&&$0!=old)||seen[$0]++||++count>512)bad=1}
            END {exit bad}'
          graphs_checked=1
        }
        file_token() {
          f_index=$1;f_bytes=$2;f_hash=$3
          parents
          if test ! -e "$p" && test ! -L "$p";then printf 'MISSING_FILE %s\n' "$f_index";return 0;fi
          regular "$p"
          info=$("$B" stat -c '%d %i %Y %Z %a %s' "$p");set -- $info;test "$#" -eq 6
          f_dev=$1;f_inode=$2;f_modified=$3;f_changed=$4;f_permissions=$5;f_size=$6
          test "$f_dev" = "$device";test "$f_size" = "$f_bytes"
          case "$f_permissions" in ''|*[!0-7]*) return 1;;esac
          f_mode=$((0$f_permissions));test "$f_mode" -le 511
          value=$("$B" sha256sum "$p");test "${value%% *}" = "$f_hash"
          regular "$p";parents
          test "$("$B" stat -c '%d %i %Y %Z %a %s' "$p")" = "$info"
          printf 'FILE %s %s %s %s %s %s %s %s\n' "$f_index" "$f_bytes" "$f_hash" "$f_mode" "$f_modified" "$f_dev" "$f_inode" "$f_changed"
        }
        directory_token() {
          d_index=$1
          parents
          if test ! -e "$p" && test ! -L "$p";then printf 'MISSING_DIR %s\n' "$d_index";return 0;fi
          data_directory "$p"
          info=$("$B" stat -c '%d %i %a' "$p");set -- $info;test "$#" -eq 3
          d_dev=$1;d_inode=$2;d_permissions=$3
          case "$d_permissions" in ''|*[!0-7]*) return 1;;esac
          d_mode=$((0$d_permissions));test "$d_mode" -le 511
          printf 'DIR %s %s %s %s\n' "$d_index" "$d_mode" "$d_dev" "$d_inode"
        }
        graphs_checked=0
        references;members
        tokens=$(
          set -eu
          while IFS=' ' read -r kind index encoded absolute bytes hash extra;do
            test -z "$extra"
            case "$kind" in
              (F) resolve "$encoded";file_token "$index" "$bytes" "$hash";;
              (D) resolve "$encoded";directory_token "$index";;
              (M|END) ;;
              (*) exit 1;;
            esac
          done <<SWIFTHAKCHI_CLEANUP_TARGETS
        $table
        SWIFTHAKCHI_CLEANUP_TARGETS
        )
        references;members;current_selection;no_game
        value=$(printf '%s' "$tokens" | "$B" sha256sum);tokens_hash=${value%% *}
        space=$("$B" stat -f -c '%S %b %a' /var/lib);set -- $space;test "$#" -eq 3
        test "$1" -gt 0;test "$3" -ge 0;test "$3" -le 1048576
        printf 'SWIFTHAKCHI_SNES_CLEANUP_PREVIEW_V1\nCHALLENGE=__NONCE__\nSCOPE=__SCOPE__\nCONTEXT=__CONTEXT__\nHWID=__HWID__\nSELECTOR=__SELECTOR__\nDEVICE=%s\nFREE_BYTES=%s\nFILES=__FILES__\nDIRS=__DIRS__\n' "$device" "$(( $1 * $3 ))"
        if test -n "$tokens";then printf '%s\n' "$tokens";fi
        printf 'TOKENS_SHA=%s\nEND\n' "$tokens_hash"
        """#
        script = script.replacingOccurrences(of: "__SELECTION_CHECK__", with: selectionCheck)
        for (key, value) in [("__RETIRE_NS__", scope.retireNamespace ? "1" : "0"), ("__SELECTOR__", scope.selection.selectorSHA256), ("__BYTES__", String(body.count)), ("__TABLE__", BackupManifest.digest(body)),
            ("__OLD_V2__", scope.unprotectedMenuID?.uuidString ?? ""), ("__ROOT__", LaunchCommand.shellQuote(root)), ("__CHILD__", LaunchCommand.shellQuote(child)), ("__NONCE__", challenge.uuidString),
            ("__SCOPE__", scope.reviewSHA256), ("__CONTEXT__", contextSHA256), ("__HWID__", scope.hwid), ("__FILES__", String(scope.fileTargets.count)), ("__DIRS__", String(scope.directories.count))] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        script += "\n"
        guard script.utf8.count <= 65536 else { throw SNESLibraryInventory.failure() }
        return .init(script: script, body: body)
    }
    struct RemovalRequest: Sendable {
        let script: String, body: Data, receipt: Data, challenge: UUID, scopeSHA256: String, previewSHA256: String, contextSHA256: String
        func stream() throws -> SNESOneGameStream { try .init(script: script, body: body) }
    }
    static func remove<Scope: SNESLibraryRetirementScope>(scope: Scope, preview: SNESLibraryCleanupObservation, runtimeSHA256: String, challenge: UUID) throws -> RemovalRequest {
        try scope.validateSources()
        guard preview.scopeSHA256 == scope.reviewSHA256 else { throw SNESLibraryInventory.failure() }
        let inspection = try self.preview(scope: scope, contextSHA256: preview.contextSHA256, runtimeSHA256: runtimeSHA256, challenge: UUID())
        guard let split = inspection.script.range(of: "        space=$(", options: []) ?? inspection.script.range(of: "space=$(") else { throw SNESLibraryInventory.failure() }
        var script = String(inspection.script[..<split.lowerBound])
        let previewHash = BackupManifest.digest(preview.raw)
        let receipt = Data(([
            "SWIFTHAKCHI_SNES_LIBRARY_CLEANED_V1", "CHALLENGE=" + challenge.uuidString, "SCOPE=" + scope.reviewSHA256,
            "PREVIEW=" + previewHash, "CONTEXT=" + preview.contextSHA256, "HWID=" + scope.hwid,
            "SELECTOR=" + scope.selection.selectorSHA256, "FILES_REMOVED=" + String(preview.files.compactMap { $0 }.count),
            "DIRS_REMOVED=" + String(preview.directories.compactMap { $0 }.count), "TARGETS_ABSENT=1", "END", ""
        ].joined(separator: "\n")).utf8)
        script += #"""
        test "$device" = '__DEVICE__'
        test "$tokens_hash" = '__TOKENS__'
        # The complete fresh target set is checked before the first unlink.
        references;members;current_selection;no_game
        removed_files=0;removed_dirs=0
        while IFS=' ' read -r kind index encoded absolute bytes hash extra;do
          test -z "$extra"
          case "$kind" in
            (F)
              IFS= read -r expected <&5
              resolve "$encoded";p_saved=$p
              actual=$(file_token "$index" "$bytes" "$hash");test "$actual" = "$expected"
              p=$p_saved;parents;current_selection;no_game
              case "$actual" in
                FILE\ *) "$B" rm -- "$p";removed_files=$((removed_files + 1));;
                MISSING_FILE\ *) ;;
                *) exit 1;;
              esac
              test ! -e "$p" && test ! -L "$p"
              ;;
            (D)
              IFS= read -r expected <&5
              resolve "$encoded";p_saved=$p
              actual=$(directory_token "$index");test "$actual" = "$expected"
              p=$p_saved;parents;current_selection;no_game
              case "$actual" in
                DIR\ *) "$B" rmdir -- "$p";removed_dirs=$((removed_dirs + 1));;
                MISSING_DIR\ *) ;;
                *) exit 1;;
              esac
              test ! -e "$p" && test ! -L "$p"
              ;;
            (M|END) ;;
            (*) exit 1;;
          esac
        done 5<<SWIFTHAKCHI_EXPECTED_NODES <<SWIFTHAKCHI_CLEANUP_TARGETS
        $tokens
        SWIFTHAKCHI_EXPECTED_NODES
        $table
        SWIFTHAKCHI_CLEANUP_TARGETS
        test "$removed_files" = '__FILES_REMOVED__';test "$removed_dirs" = '__DIRS_REMOVED__'
        "$B" sync
        references;members;current_selection;no_game
        printf '__RECEIPT__'
        """#
        for (key, value) in [("__DEVICE__", String(preview.device)), ("__TOKENS__", preview.tokensSHA256),
            ("__FILES_REMOVED__", String(preview.files.compactMap { $0 }.count)), ("__DIRS_REMOVED__", String(preview.directories.compactMap { $0 }.count)),
            ("__RECEIPT__", String(decoding: receipt, as: UTF8.self))] { script = script.replacingOccurrences(of: key, with: value) }
        script += "\n"
        guard script.utf8.count <= 65536 else { throw SNESLibraryInventory.failure() }
        return .init(script: script, body: inspection.body, receipt: receipt, challenge: challenge, scopeSHA256: scope.reviewSHA256,
            previewSHA256: previewHash, contextSHA256: preview.contextSHA256)
    }

}

struct SNESLibraryCleanupReceipt: Sendable {
    let raw: Data, challenge: UUID, scopeSHA256: String, previewSHA256: String, contextSHA256: String
    init<Scope: SNESLibraryRetirementScope>(_ raw: Data, request: SNESLibraryCleanupCommands.RemovalRequest, scope: Scope) throws {
        guard raw == request.receipt, request.scopeSHA256 == scope.reviewSHA256 else { throw SNESLibraryInventory.failure() }
        self.raw = raw; challenge = request.challenge; scopeSHA256 = request.scopeSHA256; previewSHA256 = request.previewSHA256; contextSHA256 = request.contextSHA256
    }
}

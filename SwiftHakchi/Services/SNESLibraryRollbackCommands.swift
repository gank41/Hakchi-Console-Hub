import Foundation
import SwiftHakchiCore

/// Inert, fixed-scope recovery request. A separate journal permit is required for dispatch.
enum SNESLibraryRollbackCommands {
    struct Request:Sendable {
        let script:String, id:UUID,challenge:UUID,contextSHA256:String,hwid:String
        let previous:SNESLibraryInventory.Selection,currentSHA256:String
        var receipt:Data {Data("SWIFTHAKCHI_SNES_LIBRARY_ROLLBACK_V1 \(challenge.uuidString)\nCONTEXT \(contextSHA256)\nHWID \(hwid)\nMENU \(id.uuidString)\nFROM \(currentSHA256)\nTO \(previous.selectorSHA256)\nEND\n".utf8)}
    }
    static func prepare(menu:SNESLibraryMenu,previous:SNESLibraryInventory.Selection,current:SNESLibraryInventory,runtimeSHA256:String,challenge:UUID,recoverPending:Bool=false)throws->Request {
        try menu.validate()
        let wire=BackupManifest.digest(try SNESLibraryStartupScripts.manifest(for:menu))
        let original=try previous.bytes()
        guard current.excludedMenuID==nil,current.capacity.namespaceReady,current.capacity.descriptionStoreReady,
              current.selection.kind == .library,current.selection.id==menu.id,current.selection.treeSHA256==wire,
              BackupManifest.digest(try current.selection.bytes())==current.selection.selectorSHA256,
              previous.id != menu.id,BackupManifest.digest(original)==previous.selectorSHA256,
              current.menus.contains(where: {$0.kind == .library && $0.id==menu.id && $0.treeSHA256==wire && $0.descriptionSHA256==BackupManifest.digest(menu.manifest)}) else {throw SNESLibraryInventory.failure()}
        let remove=previous.kind == .legacy || original.isEmpty
        var oldCheck:String
        switch previous.kind {
        case .legacy:
            let id=previous.id!.uuidString,hash=previous.treeSHA256!
            oldCheck="""
            for p in "$L" "$L/menus" "$L/menus/\(id)" "$L/menus/\(id)/games";do data_directory "$p" || return 1;done
            regular "$L/active-menu" || return 1
            value=$("$B" sha256sum "$L/active-menu") || return 1
            test "${value%% *}" = '\(previous.selectorSHA256)' || return 1
            folder=$("$B" sh "$R/menu-selector" '\(id)' '\(hash)') || return 1
            test "$folder" = "$L/menus/\(id)/games" || return 1
            """
        case .library:
            let id=previous.id!.uuidString,hash=previous.treeSHA256!
            oldCheck="""
            for p in "$N/menus/\(id)" "$N/menus/\(id)/pages" "$N/menus/\(id)/pages/000";do data_directory "$p" || return 1;done
            folder=$("$B" sh "$R/library-selector" '\(id)' '\(hash)') || return 1
            test "$folder" = "$N/menus/\(id)/pages/000" || return 1
            """
        case .builtin:
            oldCheck=original.isEmpty ? """
            if test -e "$L" || test -L "$L";then data_directory "$L" || return 1;fi
            test ! -e "$L/active-menu" && test ! -L "$L/active-menu" || return 1
            """:"true"
        }
        let result=Request(script:"",id:menu.id,challenge:challenge,contextSHA256:current.contextSHA256,hwid:current.hwid,previous:previous,currentSHA256:current.selection.selectorSHA256)
        var script=try SNESLibraryInventoryCommands.prefix(context:current.contextSHA256,hwid:current.hwid,runtime:runtimeSHA256)
        script += #"""
        umask 077
        stage="$N/menus/__ID__"
        for p in "${N%/*}" "$N" "$N/menus" "$N/objects" "$N/descriptions" "$stage" "$stage/pages" "$stage/pages/000";do data_directory "$p";done
        namespace_token=$("$B" stat -c '%d %i %a' "$N")
        menus_token=$("$B" stat -c '%d %i %a' "$N/menus")
        stage_token=$("$B" stat -c '%d %i %a' "$stage")
        selector_token=$("$B" stat -c '%d %i %a' "$N/active-menu")
        roots() {
          for p in "${N%/*}" "$N" "$N/menus" "$N/objects" "$N/descriptions" "$stage" "$stage/pages" "$stage/pages/000";do data_directory "$p" || return 1;done
          test "$("$B" stat -c '%d %i %a' "$N")" = "$namespace_token" || return 1
          test "$("$B" stat -c '%d %i %a' "$N/menus")" = "$menus_token" || return 1
          test "$("$B" stat -c '%d %i %a' "$stage")" = "$stage_token" || return 1
        }
        current_selection() {
          regular "$N/active-menu" || return 1
          test "$("$B" stat -c '%d %i %a' "$N/active-menu")" = "$selector_token" || return 1
          value=$("$B" sha256sum "$N/active-menu") || return 1
          test "${value%% *}" = '__CURRENT__' || return 1
          regular "$stage/menu.manifest" || return 1
          value=$("$B" sha256sum "$stage/menu.manifest") || return 1
          test "${value%% *}" = '__WIRE__' || return 1
          regular "$N/descriptions/__ID__.json" || return 1
          value=$("$B" sha256sum "$N/descriptions/__ID__.json") || return 1
          test "${value%% *}" = '__DESCRIPTION__' || return 1
        }
        previous_menu() {
        __OLD_CHECK__
        }
        pending="$N/descriptions/__ID__.rollback"
        roots;current_selection;previous_menu;no_game
        if test -e "$pending" || test -L "$pending";then
          # Only a new, explicitly approved attempt can retire a verified prefix of its own selector.
          test '__RECOVER_PENDING__' = 1 && test '__REMOVE_SELECTION__' = 0 || exit 1
          regular "$pending"
          pending_before=$("$B" stat -c '%d %i %Y %Z %a %s' "$pending")
          bytes=$("$B" stat -c '%s' "$pending")
          case "$bytes" in ''|*[!0-9]*) exit 1;;esac
          test "$bytes" -le __PREVIOUS_COUNT__
          expected=$(printf '%s' '__PREVIOUS_BYTES__' | "$B" head -c "$bytes" | "$B" sha256sum)
          value=$("$B" sha256sum "$pending");test "${value%% *}" = "${expected%% *}"
          roots;current_selection;previous_menu;no_game
          regular "$pending"
          test "$("$B" stat -c '%d %i %Y %Z %a %s' "$pending")" = "$pending_before"
          value=$("$B" sha256sum "$pending");test "${value%% *}" = "${expected%% *}"
          "$B" rm "$pending"
        fi
        test ! -e "$pending" && test ! -L "$pending" || exit 1
        folder=$("$B" sh "$R/library-selector" '__ID__' '__WIRE__')
        test "$folder" = "$stage/pages/000"
        """# + "\n"
        if remove {
            script += "roots;current_selection;previous_menu;no_game\n\"$B\" rm \"$N/active-menu\"\ntest ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\" || exit 1\n"
        } else {
            script += #"""
            set -C
            exec 7> "$pending"
            set +C
            pending_token=$("$B" stat -c '%d %i %a' "$pending")
            printf '__PREVIOUS_BYTES__' | "$B" dd conv=fsync >&7 2>/dev/null
            exec 7>&-
            roots;current_selection;previous_menu;no_game
            regular "$pending"
            test "$("$B" stat -c '%d %i %a' "$pending")" = "$pending_token"
            value=$("$B" sha256sum "$pending");test "${value%% *}" = '__PREVIOUS__'
            "$B" mv -f "$pending" "$N/active-menu"
            test ! -e "$pending" && test ! -L "$pending" || exit 1
            regular "$N/active-menu"
            value=$("$B" sha256sum "$N/active-menu");test "${value%% *}" = '__PREVIOUS__'
            """# + "\n"
        }
        script += "\"$B\" sync\nroots;previous_menu;no_game\nprintf '__RECEIPT__'\n"
        for (key,value) in [("__ID__",menu.id.uuidString),("__WIRE__",wire),("__DESCRIPTION__",BackupManifest.digest(menu.manifest)),
                            ("__RECOVER_PENDING__",recoverPending ? "1":"0"),("__REMOVE_SELECTION__",remove ? "1":"0"),("__PREVIOUS_COUNT__",String(original.count)),("__CURRENT__",current.selection.selectorSHA256),("__OLD_CHECK__",oldCheck),("__PREVIOUS__",previous.selectorSHA256),
                            ("__PREVIOUS_BYTES__",String(decoding:original,as:UTF8.self)),("__RECEIPT__",String(decoding:result.receipt,as:UTF8.self))] {
            script=script.replacingOccurrences(of:key,with:value)
        }
        guard script.utf8.count<=65536 else {throw SNESLibraryInventory.failure()}
        return .init(script:script,id:result.id,challenge:result.challenge,contextSHA256:result.contextSHA256,hwid:result.hwid,previous:previous,currentSHA256:result.currentSHA256)
    }
}
struct SNESLibraryRollbackReceipt:Sendable {
    let raw:Data, id:UUID,challenge:UUID,previousSHA256:String,currentSHA256:String,hwid:String
    init(_ raw:Data,request:SNESLibraryRollbackCommands.Request)throws {
        guard raw==request.receipt else {throw SNESLibraryInventory.failure()}
        self.raw=raw;id=request.id;challenge=request.challenge;previousSHA256=request.previous.selectorSHA256;currentSHA256=request.currentSHA256;hwid=request.hwid
    }
}

/// Checks the restored selection while allowing current save progress to remain.
enum SNESLibraryPreviousCheck {
    static func require(_ plan:SNESLibrarySyncPlan,inventory:SNESLibraryInventory)throws {
        try plan.requireSources()
        let before=plan.before,menu=plan.material.menu
        guard inventory.excludedMenuID==nil,inventory.hwid==before.hwid,inventory.catalogSHA256==before.catalogSHA256,
              inventory.totalBytes==before.totalBytes,inventory.capacity.blockSize==before.capacity.blockSize,
              inventory.selection==before.selection,inventory.capacity.namespaceReady,inventory.capacity.descriptionStoreReady else {throw SNESLibraryInventory.failure()}
        var objects=before.capacity.objects
        for r in menu.objectRecords {
            guard objects[r.name]==nil || objects[r.name]==r else {throw SNESLibraryInventory.failure()};objects[r.name]=r
        }
        guard objects==inventory.capacity.objects else {throw SNESLibraryInventory.failure()}
        var menus=Dictionary(uniqueKeysWithValues:before.menus.map {($0.id,$0)})
        guard menus[menu.id]==nil else {throw SNESLibraryInventory.failure()}
        menus[menu.id]=try SNESLibraryInactiveCheck.expectedMenu(plan)
        guard menus==Dictionary(uniqueKeysWithValues:inventory.menus.map {($0.id,$0)}) else {throw SNESLibraryInventory.failure()}
        guard protectedFilesMatch(before: before, inventory: inventory) else { throw SNESLibraryInventory.failure() }
    }
    /// Atomic return creates a fresh selector at the canonical private mode. Other immutable files stay exact.
    static func protectedFilesMatch(before: SNESLibraryInventory, inventory: SNESLibraryInventory) -> Bool {
        let expected = Dictionary(uniqueKeysWithValues: before.files.filter { !$0.path.hasPrefix("clover/") }.map { ($0.path, $0) })
        let actual = inventory.files.filter { !$0.path.hasPrefix("clover/") }
        guard actual.count == expected.count else { return false }
        for record in actual {
            guard let old = expected[record.path] else { return false }
            if record.path == "active-menu", before.selection.kind == .builtin || before.selection.kind == .library {
                guard record.byteCount == old.byteCount, record.sha256 == old.sha256,
                      record.mode == old.mode || record.mode == 0o600 else { return false }
            } else if record != old { return false }
        }
        return true
    }

}

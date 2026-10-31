import Foundation
import SwiftHakchiCore

/// Publishes only the saved menu choice. Displaying it requires a separately checked normal restart.
enum SNESLibrarySelectionCommands {
    struct Request: Sendable {
        let script: String, selector: Data, id: UUID, challenge: UUID
        let contextSHA256: String, hwid: String, wireSHA256: String, previousSHA256: String
        var receipt: Data {
            Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTION_SAVED_V1\nCHALLENGE=\(challenge.uuidString)\nCONTEXT=\(contextSHA256)\nHWID=\(hwid)\nID=\(id.uuidString)\nWIRE=\(wireSHA256)\nPREVIOUS_SELECTOR=\(previousSHA256)\nSELECTOR=\(BackupManifest.digest(selector))\nRESTART_REQUIRED=1\nEND\n".utf8)
        }
    }
    static func prepare(menu: SNESLibraryMenu, before: SNESLibraryInventory, runtimeSHA256: String, challenge: UUID) throws -> Request {
        try menu.validate()
        let wire = try SNESLibraryStartupScripts.manifest(for: menu), wireHash = BackupManifest.digest(wire)
        guard before.excludedMenuID == nil, before.selection.id != menu.id,
              let staged = before.menus.first(where: { $0.id == menu.id }), staged.kind == .library,
              staged.treeSHA256 == wireHash, staged.manifestBytes == wire.count, staged.descriptionBytes == menu.manifest.count,
              staged.descriptionSHA256 == BackupManifest.digest(menu.manifest), staged.references == menu.objectRecords.map(\.name).sorted(),
              menu.objectRecords.allSatisfy({ before.capacity.objects[$0.name] == $0 }),
              BackupManifest.digest(try before.selection.bytes()) == before.selection.selectorSHA256 else { throw SNESLibraryMenu.failure() }
        let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(menu.id.uuidString)\n\(wireHash)\n".utf8)
        let check: String
        if before.selection.selectorSHA256 == BackupManifest.digest(Data()) {
            check = "test ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\"\ntest ! -e \"$L/active-menu\" && test ! -L \"$L/active-menu\"\n"
        } else {
            let selected = before.selection.kind == .legacy ? "$L/active-menu" : "$N/active-menu"
            check = (before.selection.kind == .legacy ? "test ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\"\n" : "")
                + "regular \"\(selected)\"\nvalue=$(\"$B\" sha256sum \"\(selected)\");test \"${value%% *}\" = '\(before.selection.selectorSHA256)'\n"
        }
        let replace = before.selection.kind != .legacy && before.selection.selectorSHA256 != BackupManifest.digest(Data())
        var script = try SNESLibraryInventoryCommands.prefix(context: before.contextSHA256, hwid: before.hwid, runtime: runtimeSHA256)
        script += "current_selection() {\n" + check + "}\ncurrent_selection\numask 077\n"
        script += #"""
        stage="$N/menus/__ID__"
        for parent in "${N%/*}" "$N" "$N/objects" "$N/menus" "$N/descriptions" "$stage" "$stage/pages" "$stage/pages/000";do data_directory "$parent";done
        namespace_token=$("$B" stat -c '%d %i %a' "$N")
        menus_token=$("$B" stat -c '%d %i %a' "$N/menus")
        stage_token=$("$B" stat -c '%d %i %a' "$stage")
        roots() {
          for parent in "${N%/*}" "$N" "$N/objects" "$N/menus" "$N/descriptions" "$stage" "$stage/pages" "$stage/pages/000";do data_directory "$parent";done
          test "$("$B" stat -c '%d %i %a' "$N")" = "$namespace_token"
          test "$("$B" stat -c '%d %i %a' "$N/menus")" = "$menus_token"
          test "$("$B" stat -c '%d %i %a' "$stage")" = "$stage_token"
        }
        regular "$stage/menu.manifest"
        value=$("$B" sha256sum "$stage/menu.manifest");test "${value%% *}" = '__WIRE__'
        regular "$N/descriptions/__ID__.json"
        value=$("$B" sha256sum "$N/descriptions/__ID__.json");test "${value%% *}" = '__DESCRIPTION__'
        pending="$stage/.upload"
        test ! -e "$pending" && test ! -L "$pending"
        folder=$("$B" sh "$R/library-selector" '__ID__' '__WIRE__');test "$folder" = "$stage/pages/000"
        roots;current_selection;no_game
        set -C
        exec 7> "$pending"
        set +C
        token=$("$B" stat -c '%d %i %a' "$pending")
        printf '__SELECTOR__' | "$B" dd conv=fsync >&7 2>/dev/null
        exec 7>&-
        roots;current_selection;no_game
        regular "$pending"
        test "$("$B" stat -c '%d %i %a' "$pending")" = "$token"
        value=$("$B" sha256sum "$pending");test "${value%% *}" = '__SELECTOR_HASH__'
        # Atomic rename is scoped to this exact reviewed selector under the single console lease.
        "$B" mv __MOVE__ "$pending" "$N/active-menu"
        test ! -e "$pending" && test ! -L "$pending"
        roots;regular "$N/active-menu"
        value=$("$B" sha256sum "$N/active-menu");test "${value%% *}" = '__SELECTOR_HASH__'
        "$B" sync
        folder=$("$B" sh "$R/library-selector" '__ID__' '__WIRE__');test "$folder" = "$stage/pages/000"
        roots;no_game
        printf '__RECEIPT__'
        """#
        let result = Request(script: "", selector: selector, id: menu.id, challenge: challenge, contextSHA256: before.contextSHA256,
            hwid: before.hwid, wireSHA256: wireHash, previousSHA256: before.selection.selectorSHA256)
        for (key, value) in [("__ID__", menu.id.uuidString), ("__NONCE__", challenge.uuidString), ("__WIRE__", wireHash),
            ("__DESCRIPTION__", BackupManifest.digest(menu.manifest)), ("__SELECTOR__", String(decoding: selector, as: UTF8.self)),
            ("__SELECTOR_HASH__", BackupManifest.digest(selector)), ("__MOVE__", replace ? "-f" : "-n"), ("__RECEIPT__", String(decoding: result.receipt, as: UTF8.self))] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        script += "\n"
        guard script.utf8.count <= 65536 else { throw SNESLibraryMenu.failure() }
        return Request(script: script, selector: selector, id: menu.id, challenge: challenge, contextSHA256: before.contextSHA256,
            hwid: before.hwid, wireSHA256: wireHash, previousSHA256: before.selection.selectorSHA256)
    }
}
struct SNESLibrarySelectionReceipt: Sendable {
    let raw: Data, selectorSHA256: String, id: UUID, challenge: UUID
    let wireSHA256: String, previousSHA256: String, hwid: String
    init(_ raw: Data, request: SNESLibrarySelectionCommands.Request) throws {
        guard raw == request.receipt else { throw SNESLibraryInventory.failure() }
        self.raw = raw; selectorSHA256 = BackupManifest.digest(request.selector); id = request.id; challenge = request.challenge
        wireSHA256 = request.wireSHA256; previousSHA256 = request.previousSHA256; hwid = request.hwid
    }
}

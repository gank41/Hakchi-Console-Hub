import Foundation
import SwiftHakchiCore

/// Fixed inactive copying only. Constructing a request grants no USB or write authority.
enum SNESLibraryCopyCommands {
    struct Request: Sendable {
        let script: String, body: Data, objectNames: Set<String>
        let id: UUID, challenge: UUID, contextSHA256: String, hwid: String, wireSHA256: String, descriptionSHA256: String
        let selectorSHA256: String, fileCount: Int
        func stream() throws -> SNESLibraryCopyStream { try .init(script: script, body: body) }
        var receiptPrefix: String {
            "SWIFTHAKCHI_SNES_LIBRARY_COPIED_V1\nCHALLENGE=\(challenge.uuidString)\nCONTEXT=\(contextSHA256)\nHWID=\(hwid)\nID=\(id.uuidString)\nWIRE=\(wireSHA256)\nDESCRIPTION=\(descriptionSHA256)\nFILES=\(fileCount)\nPREVIOUS_SELECTOR=\(selectorSHA256)\nSELECTOR_CHANGED=0\n"
        }
    }
    static func prepare(menu: SNESLibraryMenu, before: SNESLibraryInventory, runtimeSHA256: String, challenge: UUID) throws -> Request {
        try menu.validate()
        guard before.excludedMenuID == nil, before.selection.id != menu.id, !before.menus.contains(where: { $0.id == menu.id }) else { throw SNESLibraryMenu.failure() }
        let capacity = try SNESLibraryCapacity.project(menu: menu, inventory: before.capacity, expectedContext: before.contextSHA256)
        guard capacity.canFit else { throw SNESLibraryCompatibility.failure("There is not enough free console space for this copy. Choose fewer games and refresh the review.") }
        var records: [(String, Data)] = [], reused: [(String, SNESLibraryObjects.Record)] = []
        for record in menu.objectRecords {
            if let existing = before.capacity.objects[record.name] {
                guard existing == record else { throw SNESLibraryMenu.failure() }; reused.append(("objects/" + record.name, record))
            } else { records.append(("objects/" + record.name, try checked(menu.objects[record.name], size: record.byteCount, hash: record.sha256))) }
        }
        let missing = Set(records.map { String($0.0.dropFirst(8)) })
        for record in menu.description.files.sorted(by: { $0.path < $1.path }) {
            records.append(("menus/" + menu.id.uuidString + "/" + record.path, try checked(menu.files[record.path], size: record.byteCount, hash: record.sha256)))
        }
        let wire = try SNESLibraryStartupScripts.manifest(for: menu), wireHash = BackupManifest.digest(wire), descriptionHash = BackupManifest.digest(menu.manifest)
        // Restore description first, runtime manifest last. A partial menu can never be selected.
        records.append(("descriptions/" + menu.id.uuidString + ".json", menu.manifest))
        records.append(("menus/" + menu.id.uuidString + "/menu.manifest", wire))
        var lines = reused.map { "REUSE \($0.0) \($0.1.byteCount) \($0.1.sha256)" }
        lines += records.map { "COPY \($0.0) \($0.1.count) \(BackupManifest.digest($0.1))" }
        let table = Data(lines.joined(separator: "\n").utf8)
        guard table.count <= 1024 * 1024 else { throw SNESLibraryMenu.failure() }
        var body = table
        for (_, bytes) in records { body.append(bytes) }
        body.append(Data(("END " + challenge.uuidString + "\n").utf8))
        guard body.count <= 160 * 1024 * 1024 else { throw SNESLibraryMenu.failure() }
        let old = before.selection
        let previousCheck: String
        if old.selectorSHA256 == BackupManifest.digest(Data()) {
            previousCheck = "test ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\"\ntest ! -e \"$L/active-menu\" && test ! -L \"$L/active-menu\"\n"
        } else {
            let selected = old.kind == .legacy ? "$L/active-menu" : "$N/active-menu"
            previousCheck = (old.kind == .legacy ? "test ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\"\n" : "")
                + "regular \"\(selected)\"\nvalue=$(\"$B\" sha256sum \"\(selected)\");test \"${value%% *}\" = '\(old.selectorSHA256)'\n"
        }
        // The USB daemon inherits a 512 KiB file cap. Raise only this request's child,
        // bounded to its largest reviewed file; leave the daemon and console startup unchanged.
        guard let largest = records.map({ $0.1.count }).max(), largest > 0, largest <= 4 * 1024 * 1024 + 96 else { throw SNESLibraryMenu.failure() }
        let fileLimitBlocks = (largest + 511) / 512
        var script = try SNESLibraryInventoryCommands.prefix(context: before.contextSHA256, hwid: before.hwid, runtime: runtimeSHA256)
        script += "current_selection() {\n" + previousCheck + "}\ncurrent_selection\numask 077\nulimit -f \(fileLimitBlocks)\n"
        script += before.capacity.namespaceReady ? "data_directory \"${N%/*}\";data_directory \"$N\";data_directory \"$N/objects\";data_directory \"$N/menus\"\n" : "test ! -e \"$N\" && test ! -L \"$N\"\n"
        script += #"""
        space=$("$B" stat -f -c '%S %b %a' /var/lib);set -- $space;test "$#" -eq 3
        test "$1" = __BLOCK__;test "$3" -ge 0;test "$3" -le 1048576
        test "$(( $1 * $3 ))" -ge __NEEDED__
        table=$("$B" dd bs=1 count=__TABLE_BYTES__ 2>/dev/null)
        value=$(printf '%s' "$table" | "$B" sha256sum);test "${value%% *}" = '__TABLE_HASH__'
        test ! -e "$N/menus/__ID__" && test ! -L "$N/menus/__ID__"
        make_directory() {
          if test -e "$1" || test -L "$1";then data_directory "$1";else "$B" mkdir -m 0700 "$1";data_directory "$1";fi
        }
        for parent in "${N%/*}" "$N" "$N/objects" "$N/menus" "$N/descriptions";do make_directory "$parent";done
        stage="$N/menus/__ID__"
        "$B" mkdir -m 0700 "$stage"
        data_directory "$stage"
        stage_token=$("$B" stat -c '%d %i %a' "$stage")
        pool_token=$("$B" stat -c '%d %i %a' "$N/objects")
        namespace_token=$("$B" stat -c '%d %i %a' "$N")
        roots() {
          data_directory "${N%/*}";data_directory "$N";data_directory "$N/menus";data_directory "$N/objects";data_directory "$N/descriptions";data_directory "$stage"
          test "$("$B" stat -c '%d %i %a' "$stage")" = "$stage_token"
          test "$("$B" stat -c '%d %i %a' "$N/objects")" = "$pool_token"
          test "$("$B" stat -c '%d %i %a' "$N")" = "$namespace_token"
        }
        parents() {
          q=${p%/*}
          while :;do
            data_directory "$q"
            test "$q" != /var/lib || break
            q=${q%/*}
          done
        }
        checked_file() {
          regular "$p";parents
          test "$("$B" stat -c '%d' "$p")" = "$device"
          test "$("$B" stat -c '%s' "$p")" = "$bytes"
          value=$("$B" sha256sum "$p");test "${value%% *}" = "$hash"
          regular "$p";parents
        }
        exec 3<&0
        copied=0
        while IFS=' ' read -r action relative bytes hash extra;do
          test -z "$extra";test -n "$relative";test -n "$bytes";test -n "$hash"
          roots;current_selection;no_game
          p="$N/$relative"
          case "$action" in
            REUSE) checked_file;continue;;
            COPY) ;;
            *) exit 1;;
          esac
          test ! -e "$p" && test ! -L "$p"
          case "$relative" in
            menus/__ID__/pages/*)
              page=${relative#menus/__ID__/pages/};page=${page%%/*}
              code=${relative%/*};code=${code##*/}
              make_directory "$stage/pages";make_directory "$stage/pages/$page";make_directory "$stage/pages/$page/$code";;
          esac
          parents
          test ! -e "$stage/.upload" && test ! -L "$stage/.upload"
          set -C
          exec 7> "$stage/.upload"
          set +C
          upload_token=$("$B" stat -c '%d %i %a' "$stage/.upload")
          # Read bounded blocks without consuming the next record. Short pipe reads count as
          # records in this pinned dd, so measure actual progress through the held descriptor.
          written=0;remaining=$bytes
          while test "$remaining" -ge 512;do
            blocks=$((remaining / 512))
            "$B" dd ibs=512 obs=65536 count="$blocks" conv=fsync <&3 >&7 2>/dev/null
            progress=$("$B" stat -L -c '%s' "/proc/$$/fd/7")
            test "$progress" -gt "$written";test "$progress" -le "$bytes"
            written=$progress;remaining=$((bytes - written))
          done
          if test "$remaining" -gt 0;then
            "$B" dd ibs=1 obs=65536 count="$remaining" conv=fsync <&3 >&7 2>/dev/null
          fi
          exec 7>&-
          roots;parents
          regular "$stage/.upload"
          test "$("$B" stat -c '%d %i %a' "$stage/.upload")" = "$upload_token"
          test "$("$B" stat -c '%s' "$stage/.upload")" = "$bytes"
          value=$("$B" sha256sum "$stage/.upload");test "${value%% *}" = "$hash"
          test ! -e "$p" && test ! -L "$p"
          "$B" mv -n "$stage/.upload" "$p"
          test ! -e "$stage/.upload" && test ! -L "$stage/.upload"
          checked_file
          copied=$((copied+1))
        done <<SWIFTHAKCHI_COPY_TABLE
        $table
        SWIFTHAKCHI_COPY_TABLE
        IFS= read -r ending <&3;test "$ending" = 'END __NONCE__'
        exec 3<&-
        test "$copied" = __COUNT__
        roots;current_selection;no_game
        "$B" sync
        folder=$("$B" sh "$R/library-selector" '__ID__' '__WIRE__')
        test "$folder" = "$stage/pages/000"
        roots;current_selection;no_game
        space=$("$B" stat -f -c '%S %b %a' /var/lib);set -- $space;test "$#" -eq 3
        test "$1" = __BLOCK__;test "$3" -ge 0;test "$3" -le 1048576
        printf '__RECEIPT__FREE_BYTES=%s\nEND\n' "$(( $1 * $3 ))"
        """#
        let prefix = "SWIFTHAKCHI_SNES_LIBRARY_COPIED_V1\nCHALLENGE=\(challenge.uuidString)\nCONTEXT=\(before.contextSHA256)\nHWID=\(before.hwid)\nID=\(menu.id.uuidString)\nWIRE=\(wireHash)\nDESCRIPTION=\(descriptionHash)\nFILES=\(records.count)\nPREVIOUS_SELECTOR=\(old.selectorSHA256)\nSELECTOR_CHANGED=0\n"
        for (key, value) in [("__BLOCK__", String(before.capacity.blockSize)), ("__NEEDED__", String(capacity.neededToCopy)),
            ("__TABLE_BYTES__", String(table.count)), ("__TABLE_HASH__", BackupManifest.digest(table)), ("__ID__", menu.id.uuidString),
            ("__NONCE__", challenge.uuidString), ("__COUNT__", String(records.count)), ("__WIRE__", wireHash), ("__RECEIPT__", prefix)] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        script += "\n"
        guard script.utf8.count <= 65536 else { throw SNESLibraryMenu.failure() }
        return Request(script: script, body: body, objectNames: missing, id: menu.id, challenge: challenge, contextSHA256: before.contextSHA256,
            hwid: before.hwid, wireSHA256: wireHash, descriptionSHA256: descriptionHash, selectorSHA256: old.selectorSHA256, fileCount: records.count)
    }
    private static func checked(_ data: Data?, size: Int, hash: String) throws -> Data {
        guard let data, data.count == size, BackupManifest.digest(data) == hash else { throw SNESLibraryMenu.failure() };return data
    }
}
struct SNESLibraryCopyStream: Sendable {
    let command: String, input: Data
    fileprivate init(script: String, body: Data) throws {
        let source = Data(script.trimmingCharacters(in: .newlines).utf8)
        guard !source.isEmpty, source.count <= 65536, !source.contains(0), !body.isEmpty, body.count <= 160 * 1024 * 1024 else { throw LegacyInspectionError.outputLimit }
        command = #"B=/mnt/swifthakchi/busybox; s=$("$B" dd bs=1 count=\#(source.count) 2>/dev/null); h=$(printf '%s' "$s" | "$B" sha256sum); [ "${h%% *}" = '\#(BackupManifest.digest(source))' ] || exit 1; eval "$s""#
        input = source + body
        guard command.utf8.count < 1020 else { throw LegacyInspectionError.outputLimit }
    }
}
extension SNESReplacementSaveStageCommands.Request {
    func stream() throws -> SNESLibraryCopyStream { try .init(script: script, body: input) }
}
extension SNESReplacementSaveStageInspection.Request {
    func stream() throws -> SNESLibraryCopyStream { try .init(script: script, body: input) }
}
extension SNESReplacementSaveHelperDelivery.Request {
    func stream() throws -> SNESLibraryCopyStream { try .init(script: script, body: input) }
}
struct SNESLibraryCopyReceipt: Sendable {
    let raw: Data, id: UUID, challenge: UUID, freeBytes: Int64
    init(_ raw: Data, request: SNESLibraryCopyCommands.Request) throws {
        guard raw.count <= 4096, let text = String(data: raw, encoding: .ascii), text.hasPrefix(request.receiptPrefix) else { throw SNESLibraryInventory.failure() }
        let suffix = text.dropFirst(request.receiptPrefix.count), parts = suffix.components(separatedBy: "\n")
        guard parts.count == 3, parts[0].hasPrefix("FREE_BYTES="), parts[1] == "END", parts[2].isEmpty,
              let free = Int64(parts[0].dropFirst(11)), String(free) == parts[0].dropFirst(11), (0...512 * 1024 * 1024).contains(free) else { throw SNESLibraryInventory.failure() }
        self.raw = raw; id = request.id; challenge = request.challenge; freeBytes = free
    }
}

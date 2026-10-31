import Foundation
import SwiftHakchiCore

/// Fixed, read-only data readers. Their output is inert until checked by the native session.
enum SNESLibraryInventoryCommands {
    static func prefix(context: String, hwid: String, runtime: String) throws -> String {
        guard [context, runtime].allSatisfy(SNESDataSnapshotChunk.isDigest), hwid.count == 32,
              SNESRuntimeBinding.hex(hwid), hwid.contains(where: { $0 != "0" }) else { throw SNESLibraryInventory.failure() }
        return #"""
        set -eu
        set -o pipefail
        set -f
        export LC_ALL=C
        B=/mnt/swifthakchi/busybox
        R=/mnt/swifthakchi
        N=/var/lib/swifthakchi/snes-v2
        L=/var/lib/swifthakchi/snes-v1
        regular() { test -f "$1" || return 1;test ! -L "$1" || return 1; test "$("$B" stat -c '%u' "$1")" = 0; test "$("$B" stat -c '%h' "$1")" = 1; }
        directory() { test -d "$1" || return 1;test ! -L "$1" || return 1; test "$("$B" stat -c '%u' "$1")" = 0; }
        directory "$R"
        regular "$B"
        value=$("$B" sha256sum "$B"); test "${value%% *}" = 440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6
        regular "$R/runtime-files.sha256"
        value=$("$B" sha256sum "$R/runtime-files.sha256"); test "${value%% *}" = '__RUNTIME__'
        "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
        test "$("$B" uname -r)" = 3.4.113
        test "$("$B" cat /etc/clover/boardtype)" = dp-shvc
        test "$("$B" cat /etc/clover/REGION)" = USA
        chip=''
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32); chip="$chip$(printf '%08x' "$word")"
        done
        test "$chip" = '__HWID__'
        "$B" awk '$2=="/var/lib" {data++;if($1!="/dev/nandc"||$3!="ext4"||!index("," $4 ",",",rw,")||index("," $4 ",",",ro,"))bad=1}
          $1=="/dev/mapper/root-crypt"&&$2=="/" {roots++;if($3!="squashfs"||!index("," $4 ",",",ro,")||index("," $4 ",",",rw,"))bad=1}
          END {exit !(data==1&&roots==1&&!bad)}' /proc/mounts
        directory /var/lib
        device=$("$B" stat -c '%d' /var/lib)
        data_directory() { directory "$1"; test "$("$B" stat -c '%d' "$1")" = "$device"; }
        no_game() {
          for program in canoe-shvc clover-canoe-shvc clover-kachikachi kachikachi retroarch hc-snes-superv; do
            test -z "$("$B" pidof "$program" || :)" || return 83
          done
          pid=$("$B" pidof clover-mcp);case "$pid" in ''|*[!0-9]*) return 83;; esac
          test "$pid" -gt 1 && test "$("$B" readlink -f "/proc/$pid/exe")" = /usr/bin/clover-mcp
        }
        no_game
        """#.replacingOccurrences(of: "__RUNTIME__", with: runtime).replacingOccurrences(of: "__HWID__", with: hwid) + "\n"
    }
    /// Each find child must report failure in the frame even when find itself returns success.
    private static let emit = #"""
    set -eu
    set -f
    B=$1;root=$2;prefix=$3;wanted_device=$4;p=$5;role=$6
    trap 'result=$?; if test "$result" -ne 0; then printf "INVALID\n"; fi' EXIT
    D=/var/lib
    case "$p" in "$D"/*) ;; *) exit 1;; esac
    case "$p" in "$root"|"$root"/*) ;; *) exit 1;; esac
    parents() {
      q=${p%/*}
      while :; do
        case "$q" in "$D"|"$D"/*) ;; *) return 1;; esac
        test -d "$q";test ! -L "$q"
        test "$("$B" stat -c '%u' "$q")" = 0
        test "$("$B" stat -c '%d' "$q")" = "$wanted_device"
        test "$q" != "$D" || break
        q=${q%/*}
      done
    }
    parents
    test ! -L "$p"
    test "$("$B" stat -c '%u' "$p")" = 0
    info=$("$B" stat -c '%d %i %Y %Z %a %s' "$p")
    set -- $info;test "$#" -eq 6
    dev=$1;inode=$2;modified=$3;changed=$4;permissions=$5;bytes=$6
    test "$dev" = "$wanted_device"
    case "$permissions" in ''|*[!0-7]*) exit 1;; esac
    mode=$((0$permissions));test "$mode" -le 511
    relative=${p#"$root"};relative=${relative#/}
    logical="$prefix";test -z "$relative" || logical="$prefix/$relative"
    encoded=$(printf '%s' "$logical" | "$B" od -An -tx1 -v | "$B" tr -d ' \n')
    if test -d "$p"; then
      test "$role" = tree
      test "$("$B" stat -c '%d %i %Y %Z %a %s' "$p")" = "$info"
      parents
      printf 'DIR %s %s\n' "$encoded" "$mode"
      exit 0
    fi
    test -f "$p";test ! -L "$p"
    test "$("$B" stat -c '%h' "$p")" = 1
    test "$bytes" -ge 0 && test "$bytes" -le 16777216
    value=$("$B" sha256sum "$p");hash=${value%% *}
    test "${#hash}" -eq 64;case "$hash" in *[!0-9a-f]*) exit 1;; esac
    test -f "$p";test ! -L "$p"
    test "$("$B" stat -c '%h' "$p")" = 1 && test "$("$B" stat -c '%u' "$p")" = 0
    test "$("$B" stat -c '%d %i %Y %Z %a %s' "$p")" = "$info"
    parents
    if test "$role" = pool; then
      name=${p##*/};test "$bytes" -gt 0
      case "$name" in
        *.sfrom) stem=${name%.sfrom};test "$stem" = "$hash";test "$bytes" -le 4194400;;
        *_small.png) stem=${name%_small.png};test "$bytes" -le 262144;;
        *.png) stem=${name%.png};test "$bytes" -le 262144;;
        *) exit 1;;
      esac
      test "${#stem}" -eq 64;case "$stem" in *[!0-9a-f]*) exit 1;; esac
      printf 'OBJECT %s %s %s\n' "$name" "$bytes" "$hash"
    else
      printf 'FILE %s %s %s %s %s %s %s %s\n' "$encoded" "$bytes" "$hash" "$mode" "$modified" "$dev" "$inode" "$changed"
    fi
    """# + "\n"
    static func script(contextSHA256: String, hwid: String, catalogSHA256: String, runtimeSHA256: String,
                       librarySupport: Bool, challenge: UUID, excludingIncompleteMenu: UUID? = nil, allowIncompleteNamespace: Bool = false) throws -> String {
        guard SNESDataSnapshotChunk.isDigest(catalogSHA256), excludingIncompleteMenu == nil || librarySupport,
              !allowIncompleteNamespace || (librarySupport && excludingIncompleteMenu != nil) else { throw SNESLibraryInventory.failure() }
        let start = try prefix(context: contextSHA256, hwid: hwid, runtime: runtimeSHA256)
        let body = #"""
        data_directory /var/lib/clover
        emit_file() { "$B" sh -c __EMIT__ -- "$B" "$1" "$2" "$device" "$1" file; }
        ready=absent;descriptions=absent;pool_present=0;menus_present=0
        if test -e "$N" || test -L "$N"; then
          test '__LIBRARY__' = 1 || exit 84
          data_directory "${N%/*}";data_directory "$N"
          if test -e "$N/objects" || test -L "$N/objects";then data_directory "$N/objects";pool_present=1;fi
          if test -e "$N/menus" || test -L "$N/menus";then data_directory "$N/menus";menus_present=1;fi
          if test "$pool_present" = 1 && test "$menus_present" = 1;then ready=ready
          else
            test '__ALLOW_PARTIAL__' = 1
            test ! -e "$N/active-menu";test ! -L "$N/active-menu"
            ready=partial
          fi
          if test -e "$N/descriptions" || test -L "$N/descriptions"; then data_directory "$N/descriptions";descriptions=ready;fi
        fi
        kind=builtin;id=-;tree=-;selector='';selector_hash='__EMPTY__'
        if test -e "$N/active-menu" || test -L "$N/active-menu"; then
          test '__LIBRARY__' = 1
          folder=$("$B" sh "$R/library-selector")
          regular "$N/active-menu";selector="$N/active-menu"
          value=$("$B" sha256sum "$selector");selector_hash=${value%% *}
          exec 3< "$selector";IFS= read -r header <&3;IFS= read -r mode <&3
          test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1
          case "$mode" in
            BUILTIN) test "$folder" = /usr/share/games;;
            MENU) kind=library;IFS= read -r id <&3;IFS= read -r tree <&3;test "$folder" = "$N/menus/$id/pages/000";;
            *) exit 1;;
          esac
          if IFS= read -r extra <&3;then exit 1;fi;exec 3<&-
        elif test -e "$L/active-menu" || test -L "$L/active-menu"; then
          data_directory "$L";data_directory "$L/menus"
          folder=$("$B" sh "$R/menu-selector")
          regular "$L/active-menu";selector="$L/active-menu"
          value=$("$B" sha256sum "$selector");selector_hash=${value%% *}
          exec 3< "$selector";IFS= read -r header <&3;IFS= read -r id <&3;IFS= read -r tree <&3
          test "$header" = SWIFTHAKCHI_SNES_MENU_SELECTOR_V1
          if IFS= read -r extra <&3;then exit 1;fi;exec 3<&-
          test "$folder" = "$L/menus/$id/games";kind=legacy
        fi
        if test '__EXCLUDED__' != -; then test "$kind" != library || test "$id" != '__EXCLUDED__'; fi
        printf '__HEADER__ __NONCE__\nCONTEXT __CONTEXT__\nHWID __HWID__\nCATALOG __CATALOG__\n'
        space=$("$B" stat -f -c '%S %b %a' /var/lib);set -- $space;test "$#" -eq 3
        printf 'SPACE %s %s %s\nNAMESPACE %s %s\nSELECTOR %s %s %s %s\n' "$1" "$2" "$3" "$ready" "$descriptions" "$kind" "$id" "$tree" "$selector_hash"
        if test '__EXCLUDED__' != -; then printf 'EXCLUDED %s\n' '__EXCLUDED__'; fi
        if test "$ready" != absent; then
          if test "$pool_present" = 1;then
            "$B" find "$N/objects" -mindepth 1 -maxdepth 1 -exec "$B" sh -c __EMIT__ -- "$B" "$N/objects" objects "$device" '{}' pool \;
          fi
          if test "$menus_present" = 1;then
          "$B" find "$N/menus" -mindepth 1 -maxdepth 1 -print | "$B" sort | while IFS= read -r base; do
            data_directory "$base";menu=${base##*/}
            if test "$menu" = '__EXCLUDED__'; then continue; fi
            regular "$base/menu.manifest";value=$("$B" sha256sum "$base/menu.manifest");hash=${value%% *}
            folder=$("$B" sh "$R/library-selector" "$menu" "$hash");test "$folder" = "$base/pages/000"
            regular "$N/descriptions/$menu.json"
            bytes=$("$B" stat -c '%s' "$base/menu.manifest");description_bytes=$("$B" stat -c '%s' "$N/descriptions/$menu.json")
            test "$description_bytes" -gt 0 && test "$description_bytes" -le 1048576
            value=$("$B" sha256sum "$N/descriptions/$menu.json");description_hash=${value%% *}
            printf 'MENU library %s %s %s %s %s\n' "$menu" "$hash" "$bytes" "$description_bytes" "$description_hash"
            "$B" awk -v id="$menu" '$1=="OBJECT" {print "REF " id " " $2}' "$base/menu.manifest"
          done
          fi
        fi
        case "$kind" in
          library)
            base="$N/menus/$id"
            emit_file "$N/active-menu" active-menu
            emit_file "$base/menu.manifest" "menus/$id/menu.manifest"
            emit_file "$N/descriptions/$id.json" "descriptions/$id.json"
            "$B" awk '$1=="FILE" {print $2}' "$base/menu.manifest" | while IFS= read -r relative; do emit_file "$base/$relative" "menus/$id/$relative";done
            "$B" awk '$1=="OBJECT" {print $2}' "$base/menu.manifest" | while IFS= read -r name;do emit_file "$N/objects/$name" "objects/$name";done;;
          legacy)
            base="$L/menus/$id";data_directory "$base";data_directory "$base/games"
            bytes=$("$B" stat -c '%s' "$base/menu.manifest")
            printf 'MENU legacy %s %s %s 0 -\n' "$id" "$tree" "$bytes"
            emit_file "$L/active-menu" legacy/active-menu
            emit_file "$base/menu.manifest" "legacy/menus/$id/menu.manifest"
            "$B" awk 'NR>1 {print $3}' "$base/menu.manifest" | while IFS= read -r relative;do emit_file "$base/$relative" "legacy/menus/$id/$relative";done;;
          builtin) if test -n "$selector";then emit_file "$selector" active-menu;fi;;
        esac
        "$B" find /var/lib/clover -xdev -exec "$B" sh -c __EMIT__ -- "$B" /var/lib/clover clover "$device" '{}' tree \;
        no_game
        if test -n "$selector";then
          regular "$selector";value=$("$B" sha256sum "$selector");test "${value%% *}" = "$selector_hash"
          if test "$kind" = legacy;then test ! -e "$N/active-menu" && test ! -L "$N/active-menu";fi
        else
          test ! -e "$N/active-menu" && test ! -L "$N/active-menu"
          test ! -e "$L/active-menu" && test ! -L "$L/active-menu"
        fi
        case "$kind" in
          library) folder=$("$B" sh "$R/library-selector" "$id" "$tree");test "$folder" = "$N/menus/$id/pages/000";;
          legacy) folder=$("$B" sh "$R/menu-selector" "$id" "$tree");test "$folder" = "$L/menus/$id/games";;
        esac
        printf 'END\n'
        """#.replacingOccurrences(of: "__EMIT__", with: LaunchCommand.shellQuote(emit))
            .replacingOccurrences(of: "__HEADER__", with: excludingIncompleteMenu == nil ? "SWIFTHAKCHI_SNES_LIBRARY_INVENTORY_V1" : "SWIFTHAKCHI_SNES_LIBRARY_RECOVERY_INVENTORY_V1")
            .replacingOccurrences(of: "__EXCLUDED__", with: excludingIncompleteMenu?.uuidString ?? "-")
            .replacingOccurrences(of: "__LIBRARY__", with: librarySupport ? "1" : "0")
            .replacingOccurrences(of: "__ALLOW_PARTIAL__", with: allowIncompleteNamespace ? "1" : "0")
            .replacingOccurrences(of: "__EMPTY__", with: BackupManifest.digest(Data()))
            .replacingOccurrences(of: "__NONCE__", with: challenge.uuidString)
            .replacingOccurrences(of: "__CONTEXT__", with: contextSHA256)
            .replacingOccurrences(of: "__HWID__", with: hwid).replacingOccurrences(of: "__CATALOG__", with: catalogSHA256)
        let script = start + body + "\n"
        guard script.utf8.count <= 65536 else { throw SNESLibraryInventory.failure() }; return script
    }
    static func space(contextSHA256: String, hwid: String, runtimeSHA256: String, selection: SNESLibraryInventory.Selection, challenge: UUID) throws -> String {
        let bytes = try selection.bytes()
        guard BackupManifest.digest(bytes) == selection.selectorSHA256 else { throw SNESLibraryInventory.failure() }
        var script = try prefix(context: contextSHA256, hwid: hwid, runtime: runtimeSHA256)
        if bytes.isEmpty {
            script += "test ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\"\ntest ! -e \"$L/active-menu\" && test ! -L \"$L/active-menu\"\n"
        } else {
            let path = selection.kind == .legacy ? "$L/active-menu" : "$N/active-menu"
            script += "regular \"\(path)\"\nvalue=$(\"$B\" sha256sum \"\(path)\");test \"${value%% *}\" = '\(selection.selectorSHA256)'\n"
            if selection.kind == .legacy { script += "test ! -e \"$N/active-menu\" && test ! -L \"$N/active-menu\"\n" }
        }
        script += """
        space=$("$B" stat -f -c '%S %b %a' /var/lib);set -- $space;test "$#" -eq 3
        printf 'SWIFTHAKCHI_SNES_SPACE_V1 \(challenge.uuidString)\\nCONTEXT=\(contextSHA256)\\nHWID=\(hwid)\\nSPACE=%s %s %s\\nEND\\n' "$1" "$2" "$3"

        """
        return script
    }
}

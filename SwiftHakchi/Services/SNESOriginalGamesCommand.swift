import Foundation

/// A fixed read-only scan of the stock, read-only game directory. No desktop command is executed.
struct SNESOriginalGamesCommand {
    static func script(binding: SNESRuntimeBinding, challenge: UUID) throws -> String {
        try binding.validate()
        return #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        B=/mnt/swifthakchi/busybox
        [ -f "$B" ] && [ ! -L "$B" ] || exit 1
        h=$("$B" sha256sum "$B"); [ "${h%% *}" = '@BUSYBOX@' ] || exit 1
        [ "$("$B" uname -r)" = 3.4.113 ] || exit 1
        [ "$("$B" cat /etc/clover/boardtype)" = dp-shvc ] || exit 1
        [ "$("$B" cat /etc/clover/REGION)" = USA ] || exit 1
        sid=''
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32)
          sid="$sid$(printf '%08x' "$word")"
        done
        [ "$sid" = '@HWID@' ] || exit 1
        "$B" awk '$2=="/" && $3=="squashfs" { n++; if ($4 !~ /(^|,)ro(,|$)/ || $4 ~ /(^|,)rw(,|$)/) bad=1 } END { exit !(n==1 && !bad) }' /proc/mounts || exit 1
        G=/usr/share/games
        [ -d "$G" ] && [ ! -L "$G" ] || exit 1
        total=0
        size() {
          [ -f "$1" ] && [ ! -L "$1" ] || exit 1
          n=$("$B" wc -c < "$1" | "$B" tr -d '[:space:]')
          case "$n" in ''|*[!0-9]*) exit 1;; esac
          [ "$n" -ge "$2" ] && [ "$n" -le "$3" ] || exit 1
        }
        reserve() {
          total=$((total+$1))
          [ "$total" -le 8323072 ] || exit 1
        }
        digest() { h=$("$B" sha256sum "$1"); h=${h%% *}; }
        emit_file() {
          size "$1" "$2" "$3"; reserve "$n"; digest "$1"
          printf 'FILE %s %s %s\n' "${1##*/}" "$n" "$h"
          "$B" cat "$1"; printf '\n'
        }
        W=/usr/bin/clover-canoe-shvc
        size "$W" 1 16384; reserve "$n"; digest "$W"
        printf 'SWIFTHAKCHI_SNES_ORIGINAL_GAMES_V1 @CHALLENGE@\nHWID %s\nWRAPPER %s %s\n' "$sid" "$n" "$h"
        "$B" cat "$W"; printf '\n'
        count=0
        for dir in "$G"/CLV-P-*; do
          [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
          code=${dir##*/}
          case "$code" in CLV-P-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;; *) exit 1;; esac
          count=$((count+1)); [ "$count" -le 48 ] || exit 1
          printf 'GAME %s\n' "$code"
          emit_file "$dir/$code.desktop" 1 8192
          pngs=0
          for file in "$dir"/*.png; do
            name=${file##*/}
            case "$name" in *[!A-Za-z0-9._-]*) exit 1;; esac
            case "$name" in "$code"*.png) ;; *) exit 1;; esac
            [ "${#name}" -le 128 ] || exit 1
            pngs=$((pngs+1)); [ "$pngs" -le 4 ] || exit 1
            emit_file "$file" 8 262144
          done
          [ "$pngs" -ge 1 ] || exit 1
          rom="$dir/$code.sfrom"
          size "$rom" 96 16777216; bytes=$n; digest "$rom"; rom_hash=$h
          h=$({ "$B" head -c 48 "$rom"; "$B" tail -c 48 "$rom"; } | "$B" sha256sum); h=${h%% *}
          reserve 96
          printf 'ROM %s.sfrom %s %s %s\n' "$code" "$bytes" "$rom_hash" "$h"
          "$B" head -c 48 "$rom"; "$B" tail -c 48 "$rom"; printf '\nEND_GAME\n'
        done
        [ "$count" -ge 1 ] || exit 1
        printf 'END %s\n' "$count"
        """#
            .replacingOccurrences(of: "@BUSYBOX@", with: SNESRAMProbeScripts.busyboxSHA256)
            .replacingOccurrences(of: "@HWID@", with: binding.expectedHWID)
            .replacingOccurrences(of: "@CHALLENGE@", with: challenge.uuidString)
    }
}

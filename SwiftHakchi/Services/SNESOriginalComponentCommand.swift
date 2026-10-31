import Foundation

enum SNESOriginalComponentCommand {
    /// Only fixed regular files, copied as opaque bytes into bounded recovery RAM.
    static let read = #"""
    set -eu
    export LC_ALL=C
    umask 077
    stage=mounts
    trap 'printf "SWIFTHAKCHI_ORIGINAL_COMPONENT_STAGE_V1 %s\n" "$stage" >&2' EXIT
    awk 'index($2,"/newroot/")==1 { bad=1 } $2=="/newroot" { n++; good=($3=="squashfs" && index("," $4 ",",",ro,") && !index("," $4 ",",",rw,")) } $2=="/" { r++; ram=($1=="rootfs" && $3=="rootfs" && index("," $4 ",",",rw,")) } $2=="/tmp" || index($2,"/tmp/")==1 { bad=1 } END { if(n!=1 || !good || r!=1 || !ram || bad) exit 1 }' /proc/mounts || exit 20
    awk 'seen[$2]++ { bad=1 } !($2=="/newroot" && $3=="squashfs" || $2=="/" && $1=="rootfs" && $3=="rootfs" || $2=="/dev" && $1=="devtmpfs" && $3=="devtmpfs" || $2=="/proc" && $1=="proc" && $3=="proc" || $2=="/sys" && $1=="sys" && $3=="sysfs" || $2=="/dev/pts" && $1=="devpts" && $3=="devpts" || $2=="/dev/shm" && $1=="tmpfs" && $3=="tmpfs") { bad=1 } END { if(bad) exit 1 }' /proc/mounts || exit 20
    test -d /newroot && test ! -L /newroot && test -d /tmp && test ! -L /tmp || exit 21
    d=$(mktemp -d /tmp/swifthakchi-components.XXXXXX) || exit 22
    trap 'printf "SWIFTHAKCHI_ORIGINAL_COMPONENT_STAGE_V1 %s\n" "$stage" >&2; rm -f "$d/frame" "$d/item"; rmdir "$d"' EXIT
    chmod 700 "$d"
    ulimit -f 1024 || exit 23
    parents() {
      local path="${1%/*}" part base=/newroot oldifs="$IFS"
      IFS=/
      for part in $path; do
        base="$base/$part"
        test -d "$base" && test ! -L "$base" || exit 24
      done
      IFS="$oldifs"
    }
    hash_file() {
      local sum
      sum=$(sha256sum "$1") || exit 25
      sha=${sum%% *}
      test "${#sha}" = 64 || exit 25
      case "$sha" in *[!0-9a-f]*) exit 25;; esac
    }
    emit() {
      local path="$1" src="/newroot/$1" count meta before current
      parents "$path"
      test -f "$src" && test ! -L "$src" || exit 26
      meta=$(stat -c '%s:%h' "$src") || exit 26
      count=${meta%:*}
      case "$count" in ''|*[!0-9]*) exit 26;; esac
      test "${meta##*:}" = 1 && test "$count" -gt 0 && test "$count" -le 262144 || exit 26
      hash_file "$src"; before="$sha"
      cat "$src" > "$d/item" || exit 27
      current=$(stat -c '%s:%h' "$src") || exit 27
      test "$current" = "$meta" || exit 27
      current=$(stat -c '%s:%h' "$d/item") || exit 27
      test "$current" = "$count:1" || exit 27
      hash_file "$src"; test "$sha" = "$before" || exit 27
      hash_file "$d/item"; test "$sha" = "$before" || exit 27
      printf 'F %s %s %s\n' "$path" "$count" "$sha" >> "$d/frame"
      cat "$d/item" >> "$d/frame" || exit 27
      printf '\n' >> "$d/frame"
    }
    stage=copying
    printf 'SWIFTHAKCHI_SNES_ORIGINAL_COMPONENTS_V1\n' > "$d/frame"
    for path in lib/modules/3.4.113/extra/clvcon.ko lib/modules/3.4.113/extra/mali.ko lib/modules/3.4.113/kernel/drivers/input/keyboard/sunxi-keyboard.ko lib/modules/3.4.113/kernel/drivers/input/keyboard/sunxi-knob.ko usr/bin/clover-mcp; do emit "$path"; done
    printf 'END\n' >> "$d/frame"
    meta=$(stat -c '%s:%h' "$d/frame") || exit 28
    test "${meta##*:}" = 1 && test "${meta%:*}" -le 524288 || exit 28
    stage=complete
    cat "$d/frame"
    """#
}

import Foundation

enum SNESMenuSupportCommand {
    /// Exact supplemental paths; original scripts/configuration are copied as opaque data only.
    static let read = #"""
    set -eu
    export LC_ALL=C
    umask 077
    stage=mounts
    trap 'printf "SWIFTHAKCHI_MENU_SUPPORT_STAGE_V1 %s\n" "$stage" >&2' EXIT
    awk 'index($2,"/newroot/")==1 { bad=1 } $2=="/newroot" { n++; good=($3=="squashfs" && index("," $4 ",",",ro,") && !index("," $4 ",",",rw,")) } $2=="/" { r++; ram=($1=="rootfs" && $3=="rootfs" && index("," $4 ",",",rw,")) } $2=="/tmp" || index($2,"/tmp/")==1 { bad=1 } END { if(n!=1 || !good || r!=1 || !ram || bad) exit 1 }' /proc/mounts || exit 20
    test -d /newroot && test ! -L /newroot && test -d /tmp && test ! -L /tmp || exit 21
    d=$(mktemp -d /tmp/swifthakchi-menu-support.XXXXXX) || exit 22
    trap 'printf "SWIFTHAKCHI_MENU_SUPPORT_STAGE_V1 %s\n" "$stage" >&2; rm -f "$d/paths" "$d/sorted" "$d/frame" "$d/link"; rmdir "$d"' EXIT
    chmod 700 "$d"
    ulimit -f 8192 || exit 23
    : > "$d/paths"; : > "$d/frame"
    safe() {
      test "${#1}" -le 512 || exit 24
      case "$1" in ''|/*|*/|*//*|.|..|../*|*/../*|*/..|./*|*/./*|*/.|*[!A-Za-z0-9._+/-]*) exit 24;; esac
    }
    parents() {
      local path="$1" part base=/newroot oldifs="$IFS"
      path=${path%/*}; IFS=/
      for part in $path; do
        base="$base/$part"
        test ! -L "$base" || exit 25
        if test -e "$base"; then test -d "$base" || exit 25; fi
      done
      IFS="$oldifs"
    }
    paths=0
    add() {
      safe "$1"; parents "$1"
      paths=$((paths+1)); test "$paths" -le 129 || exit 26
      printf '%s\n' "$1" >> "$d/paths"
    }
    stage=listing
    for path in etc/asound.conf etc/clover/buildtype etc/clover/ui etc/group etc/nsswitch.conf etc/passwd etc/udev/udev.conf lib/udev/rules.d usr/bin/clover-canoe-shvc; do add "$path"; done
    test ! -L /newroot/lib/udev/rules.d || exit 25
    if test -e /newroot/lib/udev/rules.d; then
      test -d /newroot/lib/udev/rules.d || exit 25
      for child in /newroot/lib/udev/rules.d/* /newroot/lib/udev/rules.d/.[!.]* /newroot/lib/udev/rules.d/..?*; do
        if test ! -e "$child" && test ! -L "$child"; then continue; fi
        add "lib/udev/rules.d/${child##*/}"
      done
    fi
    text_count=0; text_bytes=0
    hash_file() {
      local sum
      sum=$(sha256sum "$1") || exit 27
      sha=${sum%% *}
      test "${#sha}" = 64 || exit 27
      case "$sha" in *[!0-9a-f]*) exit 27;; esac
    }
    emit() {
      local path="$1" section="$2" src="/newroot/$1" kind count meta links target
      safe "$path"; parents "$path"
      if test -L "$src"; then
        target=$(readlink "$src" && printf '.') || exit 28
        target=${target%.}; target=${target%?}
        test -n "$target" && test "${#target}" -le 512 || exit 28
        if printf '%s' "$target" | grep -q '[^ -~]'; then exit 28; fi
        printf '%s' "$target" > "$d/link"
        count=${#target}; hash_file "$d/link"
        printf 'L %s %s %s\n' "$path" "$count" "$sha" >> "$d/frame"
        cat "$d/link" >> "$d/frame"; printf '\n' >> "$d/frame"
        if test "$section" = text; then text_count=$((text_count+1)); fi
      elif test -d "$src"; then
        test "$path" = lib/udev/rules.d && test "$section" = text || exit 29
        printf 'D %s 0 -\n' "$path" >> "$d/frame"
      elif test ! -e "$src"; then
        printf 'A %s 0 -\n' "$path" >> "$d/frame"
      else
        test -f "$src" || exit 30
        meta=$(stat -c '%s:%h' "$src") || exit 30
        count=${meta%:*}; links=${meta##*:}
        case "$count:$links" in *[!0-9:]*) exit 30;; esac
        test "$links" = 1 || exit 30
        if test "$section" = executable; then
          kind=B; test "$count" -le 33554432 || exit 31
        else
          kind=F; test "$count" -le 65536 || exit 31
          text_count=$((text_count+1)); text_bytes=$((text_bytes+count)); test "$text_bytes" -le 2097152 || exit 31
        fi
        hash_file "$src"
        printf '%s %s %s %s\n' "$kind" "$path" "$count" "$sha" >> "$d/frame"
        if test "$kind" = F; then cat "$src" >> "$d/frame"; printf '\n' >> "$d/frame"; fi
      fi
      test "$text_count" -le 128 || exit 31
    }
    stage=reading-text
    printf 'SWIFTHAKCHI_SNES_MENU_SUPPORT_V1\nTEXT_BEGIN\n' > "$d/frame"
    sort "$d/paths" > "$d/sorted"
    while IFS= read -r path; do emit "$path" text; done < "$d/sorted"
    stage=reading-executables
    printf 'EXECUTABLES_BEGIN\n' >> "$d/frame"
    for path in sbin/udevadm sbin/udevd usr/bin/clover-mcp usr/bin/udevadm; do emit "$path" executable; done
    printf 'END\n' >> "$d/frame"
    meta=$(stat -c '%s:%h' "$d/frame") || exit 32
    test "${meta%:*}" -le 4194304 || exit 32
    stage=complete
    cat "$d/frame"
    """#
}

import Foundation

enum SNESStartupCommand {
    /// Fixed read-only paths, no script sourcing and no followed original-system links.
    static let read = #"""
    set -eu
    export LC_ALL=C
    umask 077
    stage=mounts
    trap 'printf "SWIFTHAKCHI_STARTUP_STAGE_V1 %s\n" "$stage" >&2' EXIT
    awk 'index($2,"/newroot/")==1 { bad=1 } $2=="/newroot" { n++; good=($3=="squashfs" && index("," $4 ",",",ro,") && !index("," $4 ",",",rw,")) } $2=="/" { r++; ram=($1=="rootfs" && $3=="rootfs" && index("," $4 ",",",rw,")) } $2=="/tmp" || index($2,"/tmp/")==1 { bad=1 } END { if(n!=1 || !good || r!=1 || !ram || bad) exit 1 }' /proc/mounts || exit 20
    test -d /newroot && test ! -L /newroot && test -d /tmp && test ! -L /tmp || exit 21
    d=$(mktemp -d /tmp/swifthakchi-startup.XXXXXX) || exit 22
    trap 'printf "SWIFTHAKCHI_STARTUP_STAGE_V1 %s\n" "$stage" >&2; rm -f "$d/text" "$d/modules" "$d/sorted" "$d/frame" "$d/link"; rmdir "$d"' EXIT
    chmod 700 "$d"
    ulimit -f 24576 || exit 23
    : > "$d/text"; : > "$d/modules"; : > "$d/frame"
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
    stage=listing-text
    text_paths=0
    add_text() {
      text_paths=$((text_paths+1)); test "$text_paths" -le 144 || exit 26
      printf '%s\n' "$1" >> "$d/text"
    }
    for path in bin/busybox bin/sh etc/clover/REGION etc/clover/boardtype etc/fstab etc/init.d etc/inittab etc/modules etc/modules-load.d etc/udev/rules.d sbin/init usr/bin/clover-canoe-shvc; do
      safe "$path"; parents "$path"
      add_text "$path"
      case "$path" in etc/init.d|etc/modules-load.d|etc/udev/rules.d)
        test ! -L "/newroot/$path" || exit 25
        if test -e "/newroot/$path"; then
          test -d "/newroot/$path" || exit 25
          for child in "/newroot/$path"/* "/newroot/$path"/.[!.]* "/newroot/$path"/..?*; do
            if test ! -e "$child" && test ! -L "$child"; then continue; fi
            rel="$path/${child##*/}"; safe "$rel"
            add_text "$rel"
          done
        fi;;
      esac
    done
    module_records=0
    walk_modules() {
      local path="$1" depth="$2" child rel
      safe "$path"; parents "$path"
      test "$depth" -le 8 || exit 26
      module_records=$((module_records+1)); test "$module_records" -le 2048 || exit 26
      printf '%s\n' "$path" >> "$d/modules"
      if test ! -L "/newroot/$path" && test -d "/newroot/$path"; then
        for child in "/newroot/$path"/* "/newroot/$path"/.[!.]* "/newroot/$path"/..?*; do
          if test ! -e "$child" && test ! -L "$child"; then continue; fi
          rel="$path/${child##*/}"; walk_modules "$rel" "$((depth+1))"
        done
      fi
    }
    stage=listing-modules
    test ! -L /newroot/lib/modules || exit 25
    walk_modules lib/modules 0
    text_count=0; text_bytes=0; module_bytes=0
    hash_file() {
      local sum
      sum=$(sha256sum "$1") || exit 27
      sha=${sum%% *}
      test "${#sha}" = 64 || exit 27
      case "$sha" in *[!0-9a-f]*) exit 27;; esac
    }
    emit() {
      local path="$1" section="$2" src="/newroot/$1" kind count meta links target
      if test -L "$src"; then
        target=$(readlink "$src" && printf '.') || exit 28
        target=${target%.}; target=${target%?}
        test -n "$target" && test "${#target}" -le 512 || exit 28
        if printf '%s' "$target" | grep -q '[^ -~]'; then exit 28; fi
        printf '%s' "$target" > "$d/link"
        count=${#target}; hash_file "$d/link"
        printf 'L %s %s %s\n' "$path" "$count" "$sha" >> "$d/frame"
        cat "$d/link" >> "$d/frame"; printf '\n' >> "$d/frame"
        if test "$section" = text; then
          case "$path" in bin/busybox|bin/sh|sbin/init|usr/bin/clover-canoe-shvc) :;; *) text_count=$((text_count+1));; esac
        fi
      elif test -d "$src"; then
        if test "$section" = text; then
          case "$path" in etc/init.d|etc/modules-load.d|etc/udev/rules.d) :;; *) exit 29;; esac
        fi
        printf 'D %s 0 -\n' "$path" >> "$d/frame"
      elif test ! -e "$src"; then
        printf 'A %s 0 -\n' "$path" >> "$d/frame"
      else
        test -f "$src" || exit 30
        meta=$(stat -c '%s:%h' "$src") || exit 30
        count=${meta%:*}; links=${meta##*:}
        case "$count:$links" in *[!0-9:]*) exit 30;; esac
        test "$links" = 1 || exit 30
        if test "$section" = modules; then
          kind=M; test "$count" -le 8388608 || exit 31
          module_bytes=$((module_bytes+count)); test "$module_bytes" -le 134217728 || exit 31
        else
          case "$path" in bin/busybox|bin/sh|sbin/init|usr/bin/clover-canoe-shvc) kind=B; test "$count" -le 33554432 || exit 31;;
            *) kind=F; test "$count" -le 65536 || exit 31
               text_count=$((text_count+1)); text_bytes=$((text_bytes+count)); test "$text_bytes" -le 8388608 || exit 31;;
          esac
        fi
        hash_file "$src"
        printf '%s %s %s %s\n' "$kind" "$path" "$count" "$sha" >> "$d/frame"
        if test "$kind" = F; then cat "$src" >> "$d/frame"; printf '\n' >> "$d/frame"; fi
      fi
      test "$text_count" -le 128 || exit 31
    }
    stage=reading-text
    printf 'SWIFTHAKCHI_SNES_STARTUP_V1\nTEXT_BEGIN\n' > "$d/frame"
    sort "$d/text" > "$d/sorted"
    while IFS= read -r path; do emit "$path" text; done < "$d/sorted"
    stage=reading-modules
    printf 'MODULES_BEGIN\n' >> "$d/frame"
    sort "$d/modules" > "$d/sorted"
    while IFS= read -r path; do emit "$path" modules; done < "$d/sorted"
    printf 'END\n' >> "$d/frame"
    meta=$(stat -c '%s:%h' "$d/frame") || exit 32
    test "${meta%:*}" -le 12582912 || exit 32
    stage=complete
    cat "$d/frame"
    """#
}

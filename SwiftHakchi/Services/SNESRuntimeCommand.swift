import Foundation

enum SNESRuntimeCommand {
    /// Fixed original-root reads only. Link components never leave the known library directory.
    static let read = #"""
    set -eu
    awk 'index($2,"/newroot/")==1 { bad=1 } $2 == "/newroot" { n++; good=($3=="squashfs" && index("," $4 ",",",ro,") && !index("," $4 ",",",rw,")) } END { if(n!=1 || !good || bad) exit 1 }' /proc/mounts || exit 20
    test -d /newroot/lib && test ! -L /newroot/lib || exit 26
    valid() {
      case "$1:$2" in
        loader:ld-linux-armhf.so.3|libc:libc.so.6) return 0;;
      esac
      case "$1" in
        loader) printf '%s\n' "$2" | grep -Eq '^ld-([0-9]+\.)+[0-9]+\.so$';;
        libc) printf '%s\n' "$2" | grep -Eq '^libc-([0-9]+\.)+[0-9]+\.so$';;
        *) return 1;;
      esac
    }
    read_one() {
      role="$1"; name="$2"; chain="$name"; hops=0
      while test -L "/newroot/lib/$name"; do
        hops=$((hops+1)); test "$hops" -le 8 || exit 21
        next=$(readlink "/newroot/lib/$name") || exit 22
        case "$next" in /lib/*) next="${next#/lib/}";; esac
        test "${#next}" -le 128 && valid "$role" "$next" || exit 23
        name="$next"; chain="$chain>$name"
      done
      test -f "/newroot/lib/$name" || exit 24
      count=$(wc -c < "/newroot/lib/$name" | tr -d ' \n')
      test "$count" -ge 52 && test "$count" -le 2097152 || exit 25
      sha=$(sha256sum "/newroot/lib/$name" | cut -d' ' -f1)
      printf '%s %s %s %s\n' "$role" "$chain" "$count" "$sha"
      cat "/newroot/lib/$name"; printf '\n'
    }
    printf 'SWIFTHAKCHI_SNES_RUNTIME_V1\n'
    read_one loader ld-linux-armhf.so.3
    read_one libc libc.so.6
    printf 'END\n'
    """#
}

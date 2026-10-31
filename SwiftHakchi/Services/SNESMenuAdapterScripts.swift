import Foundation
struct SNESMenuAdapterScripts {
 static let mcpDesktopSHA256="e335d1d61afb8f5c03942282ad056d8109c5009ca5c16f8e456f36e8e17c2130"
 static let verifier = #"""
 #!/bin/sh
 set -eu
 set -o pipefail
 set -f
 export LC_ALL=C
 B=/mnt/swifthakchi/busybox
 N=/var/lib/swifthakchi/snes-v1
 regular() {
   test -f "$1" && test ! -L "$1" || return 1
   test "$("$B" stat -c '%h' "$1")" = 1
   test "$("$B" stat -c '%u' "$1")" = 0
 }
 directory() { test -d "$1" && test ! -L "$1" || return 1; test "$("$B" stat -c '%u' "$1")" = 0; }
 ascii_file() {
   regular "$1" || exit 1
   size=$("$B" wc -c < "$1" | "$B" tr -d '[:space:]')
   test "$size" -gt 0 && test "$size" -le "$2"
   clean=$("$B" tr -cd '\12\40-\176' < "$1" | "$B" wc -c | "$B" tr -d '[:space:]')
   test "$clean" = "$size"
   test "$("$B" tail -c 1 "$1" | "$B" wc -l)" -eq 1
 }
 directory "${N%/*}"
 directory "$N"
 directory "$N/menus"
 if test "$#" -eq 2; then
   id=$1; tree=$2
 elif test "$#" -eq 0; then
   selector="$N/active-menu"
   ascii_file "$selector" 192
   exec 3< "$selector"
   IFS= read -r header <&3; IFS= read -r id <&3; IFS= read -r tree <&3
   if IFS= read -r extra <&3; then exit 1; fi
   exec 3<&-
   test "$header" = SWIFTHAKCHI_SNES_MENU_SELECTOR_V1
 else
   exit 1
 fi
 case "$id" in ????????-????-????-????-????????????) ;; *) exit 1;; esac
 case "$id" in *[!0-9A-F-]*) exit 1;; esac
 test "${#tree}" -eq 64; case "$tree" in *[!0-9a-f]*) exit 1;; esac
 base="$N/menus/$id"
 directory "$base"; directory "$base/games"
 test "$("$B" find "$base" -mindepth 1 -maxdepth 1 | "$B" wc -l)" -eq 2
 manifest="$base/menu.manifest"
 ascii_file "$manifest" 32768
 actual=$("$B" sha256sum "$manifest"); test "${actual%% *}" = "$tree"
 exec 4< "$manifest"
 IFS= read -r header <&4; test "$header" = SWIFTHAKCHI_SNES_MENU_V1
 count=0; dirs=0; total=0; previous=''; previous_code=''; custom=''; mask=0
 while IFS= read -r row <&4; do
   set -- $row
   test "$#" -eq 3
   hash=$1; bytes=$2; relative=$3
   test "$row" = "$hash $bytes $relative"
   test "${#hash}" -eq 64; case "$hash" in *[!0-9a-f]*) exit 1;; esac
   case "$bytes" in ''|0|0*|*[!0-9]*) exit 1;; esac
   case "$relative" in games/*/*) ;; *) exit 1;; esac
   rest=${relative#games/}; code=${rest%%/*}; name=${rest#*/}
   case "$code" in CLV-[PU]-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;; *) exit 1;; esac
   test "$relative" = "games/$code/$name"
   case "$name" in *[!A-Za-z0-9._-]*) exit 1;; esac
   test "${#name}" -le 128
   test "$relative" \> "$previous"; previous=$relative
   if test "$code" != "$previous_code"; then
     dirs=$((dirs+1)); test "$dirs" -le 35
     directory "$base/games/$code"; previous_code=$code
   fi
   case "$code" in
     CLV-P-*) test "$name" = "$code.desktop"; limit=8192;;
     CLV-U-*)
       test -z "$custom" || test "$custom" = "$code"; custom=$code
       case "$name" in
         "$code.desktop") limit=8192; mask=$((mask+1));;
         "$code.png") limit=262144; mask=$((mask+2));;
         "$code.sfrom") limit=4194400; mask=$((mask+4)); test "$bytes" -ge 96;;
         "${code}_small.png") limit=262144; mask=$((mask+8));;
         *) exit 1;;
       esac;;
   esac
   test "$bytes" -le "$limit"
   regular "$base/$relative"
   size=$("$B" wc -c < "$base/$relative" | "$B" tr -d '[:space:]'); test "$size" = "$bytes"
   actual=$("$B" sha256sum "$base/$relative"); test "${actual%% *}" = "$hash"
   count=$((count+1)); total=$((total+bytes)); test "$count" -le 128 && test "$total" -le 8388608
 done
 exec 4<&-
 test "$mask" -eq 15 && test "$dirs" -ge 2 && test "$count" -eq $((dirs+3))
 actual=$("$B" find "$base/games" -mindepth 1 -maxdepth 2 | "$B" wc -l | "$B" tr -d '[:space:]')
 test "$actual" -eq $((count+dirs))
 printf '%s\n' "$base/games"
 """# + "\n"
 /// Extend only the new recipe; historical script bytes remain untouched.
 static func extendPreparation(_ original:String)throws->String {
     var result=original
     func replace(_ old:String,_ new:String)throws {
         guard result.components(separatedBy:old).count==2 else {throw SNESRuntimeBinding.failure()}
         result=result.replacingOccurrences(of:old,with:new)
     }
     try replace("mounted=0\nbound=0\n","mounted=0\nbound=0\nmenu_bound=0\n")
     try replace("if test \"$bound\" = 1; then", "if test \"$menu_bound\" = 1; then\n  if \"$B\" umount /newroot/etc/init.d/S81clover-mcp; then menu_bound=0; fi\nfi\nif test \"$bound\" = 1; then")
     try replace("test \"$mounted\" = 1 && test \"$bound\" = 0;", "test \"$mounted\" = 1 && test \"$bound\" = 0 && test \"$menu_bound\" = 0;")
     try replace("original-usb service usb-wrapper runtime-files.sha256; do", "original-usb service usb-wrapper original-menu-init menu-wrapper menu-selector menu-configure runtime-files.sha256; do")
     let template="""
     test -f /newroot/etc/init.d/S81clover-mcp && test ! -L /newroot/etc/init.d/S81clover-mcp
     test -f /newroot/usr/share/applications/clover-mcp.desktop && test ! -L /newroot/usr/share/applications/clover-mcp.desktop
     test "$("$B" wc -c < /newroot/usr/share/applications/clover-mcp.desktop)" -eq 2638
     value=$("$B" sha256sum /newroot/usr/share/applications/clover-mcp.desktop)
     test "${value%% *}" = '\(mcpDesktopSHA256)'
     "$B" cp /newroot/usr/share/applications/clover-mcp.desktop "$R/mcp-template"
     "$B" chmod 0600 "$R/mcp-template"

     """
     try replace("# Verify copied bytes",template+"# Verify copied bytes")
     try replace("bound=1\n", "bound=1\n\"$B\" mount --bind \"$R/menu-wrapper\" /newroot/etc/init.d/S81clover-mcp\nmenu_bound=1\n")
     try replace("END { if(bad || m!=1 || b!=1) exit 1 }", "$2==\"/newroot/etc/init.d/S81clover-mcp\" { c++; if($3!=\"tmpfs\") bad=1 } END { if(bad || m!=1 || b!=1 || c!=1) exit 1 }")
     return result
 }
 static let configure = #"""
 #!/bin/sh
 set -eu
 set -o pipefail
 R=/mnt/swifthakchi
 B="$R/busybox"
 T=/usr/share/applications/clover-mcp.desktop
 test -d "$R" && test ! -L "$R"
 "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
 # Configuration changes happen before the original menu manager starts.
 test -z "$("$B" pidof clover-mcp || :)"
 value=$("$B" sha256sum "$R/mcp-template"); test "${value%% *}" = '__MCP_SHA__'
 mounts=$("$B" awk '$2=="/usr/share/applications/clover-mcp.desktop" {n++;if($3!="tmpfs")bad=1} END {if(bad || n>1)exit 1;print n+0}' /proc/mounts)
 if test "$mounts" = 1; then
   test -f "$R/mcp-selected" && test ! -L "$R/mcp-selected"
   test "$("$B" stat -c '%h' "$R/mcp-selected")" = 1
   test "$("$B" stat -c '%d:%i' "$T")" = "$("$B" stat -c '%d:%i' "$R/mcp-selected")"
   "$B" umount "$T"
 fi
 value=$("$B" sha256sum "$T"); test "${value%% *}" = '__MCP_SHA__'
 if test ! -e /var/lib/swifthakchi/snes-v1/active-menu && test ! -L /var/lib/swifthakchi/snes-v1/active-menu; then exit 0; fi
 # A missing or rejected selector leaves the verified stock configuration in place.
 if ! folder=$("$B" sh "$R/menu-selector"); then
   if test -e /var/lib/swifthakchi/snes-v1/active-menu || test -L /var/lib/swifthakchi/snes-v1/active-menu; then
     printf '%s\n' 'Swift Hakchi: added games were not ready; starting the built-in games.' >&2
   fi
   exit 0
 fi
 test ! -L "$R/mcp-selected"
 if test -e "$R/mcp-selected"; then
   test -f "$R/mcp-selected" && test "$("$B" stat -c '%h' "$R/mcp-selected")" = 1
 fi
 "$B" awk -v folder="$folder" '
   $0=="GamesFolder = /usr/share/games" {print "GamesFolder = " folder;n++;next}
   {print}
   END {if(n!=1)exit 1}
 ' "$R/mcp-template" > "$R/mcp-selected"
 "$B" chmod 0600 "$R/mcp-selected"
 bound=0
 cleanup() {
   result=$?; trap - EXIT
   if test "$result" != 0 && test "$bound" = 1; then "$B" umount "$T" || :; fi
   exit "$result"
 }
 trap cleanup EXIT
 "$B" mount --bind "$R/mcp-selected" "$T"
 bound=1
 test "$("$B" stat -c '%d:%i' "$T")" = "$("$B" stat -c '%d:%i' "$R/mcp-selected")"
 """#.replacingOccurrences(of:"__MCP_SHA__",with:mcpDesktopSHA256) + "\n"
 static let wrapper = #"""
 #!/bin/sh
 set -eu
 R=/mnt/swifthakchi
 B="$R/busybox"
 "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
 original() { "$B" sh -e "$R/original-menu-init" "$1"; }
 start() { "$B" sh "$R/menu-configure"; original start; }
 case "${1:-}" in
   start) start;;
   stop) original stop;;
   restart|reload) original stop || :; start;;
   *) exit 1;;
 esac
 """# + "\n"
}

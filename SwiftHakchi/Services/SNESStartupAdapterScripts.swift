import Foundation
import SwiftHakchiCore

/// Fixed original-profile adapter. These scripts carry no flash or library-update operation.
struct SNESStartupAdapterScripts: Sendable {
    let prepare: String, service: String, usbWrapper: String
    init(binding: SNESRuntimeBinding, rootRuntime: SNESRuntimeFrame? = nil) throws {
        try binding.validate()
        usbWrapper = #"""
        #!/bin/sh
        R=/mnt/swifthakchi
        original() { "$R/busybox" sh "$R/original-usb" "$1"; }
        stop() { "$R/busybox" sh "$R/service" stop || :; original stop; }
        start() {
          original start || return $?
          if ! "$R/busybox" sh "$R/service" start; then
            "$R/busybox" sh "$R/service" stop || :
            original start
          fi
        }
        case "${1:-}" in
          start) start;;
          stop) stop;;
          restart|reload) stop; start;;
          *) exit 1;;
        esac
        """# + "\n"
        var preparation = #"""
        #!/bin/sh
        set -eu
        set -o pipefail
        umask 077
        B=/swifthakchi/busybox
        R=/newroot/mnt/swifthakchi
        mounted=0
        bound=0
        cleanup() {
          result=$?
          trap - EXIT
          if test "$result" != 0; then
            if test "$bound" = 1; then
              if "$B" umount /newroot/etc/init.d/S90usb-gadget; then bound=0; fi
            fi
            if test "$mounted" = 1 && test "$bound" = 0; then "$B" umount /newroot/mnt || :; fi
          fi
          exit "$result"
        }
        trap cleanup EXIT
        "$B" sha256sum -c /swifthakchi/files.sha256 >/dev/null
        "$B" awk '
          NF!=6 { bad=1 }
          $2=="/" { r++; if($1!="rootfs" || $3!="rootfs") bad=1; next }
          $2=="/dev" { d++; if($3!="devtmpfs") bad=1; next }
          $2=="/proc" { p++; if($3!="proc") bad=1; next }
          $2=="/sys" { s++; if($3!="sysfs") bad=1; next }
          $2=="/newroot" { n++; if($3!="squashfs" || !index("," $4 ",",",ro,") || index("," $4 ",",",rw,")) bad=1; next }
          { bad=1 }
          END { if(bad || r!=1 || d!=1 || p!=1 || s!=1 || n!=1) exit 1 }
        ' /proc/mounts
        test "$("$B" uname -r)" = 3.4.113
        test "$("$B" cat /newroot/etc/clover/boardtype)" = dp-shvc
        test "$("$B" cat /newroot/etc/clover/REGION)" = USA
        chip=''
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32)
          chip="$chip$(printf '%08x' "$word")"
        done
        test "$chip" = '__HWID__'
        "$B" sha256sum -c /swifthakchi/root-files.sha256 >/dev/null
        test -d /newroot/mnt && test ! -L /newroot/mnt
        test -z "$("$B" ls -A /newroot/mnt)"
        test -f /newroot/etc/init.d/S90usb-gadget && test ! -L /newroot/etc/init.d/S90usb-gadget
        "$B" mount -t tmpfs -o size=8m,mode=0700,nosuid,nodev tmpfs /newroot/mnt
        mounted=1
        "$B" mkdir "$R"
        for name in busybox clovershell ld-linux-armhf.so.3 libc.so.6 original-usb service usb-wrapper runtime-files.sha256; do
          test -f "/swifthakchi/$name" && test ! -L "/swifthakchi/$name"
          "$B" cp "/swifthakchi/$name" "$R/$name"
          "$B" chmod 0700 "$R/$name"
        done
        # Verify copied bytes using their pre-switch_root names before binding any root file.
        "$B" sed 's@  /mnt/swifthakchi/@  /newroot/mnt/swifthakchi/@' /swifthakchi/runtime-files.sha256 | "$B" sha256sum -c - >/dev/null
        "$B" mount --bind "$R/usb-wrapper" /newroot/etc/init.d/S90usb-gadget
        bound=1
        "$B" awk '$2=="/newroot/mnt" { m++; if($3!="tmpfs") bad=1 } $2=="/newroot/etc/init.d/S90usb-gadget" { b++; if($3!="tmpfs") bad=1 } END { if(bad || m!=1 || b!=1) exit 1 }' /proc/mounts
        """#.replacingOccurrences(of:"__HWID__",with:binding.expectedHWID) + "\n"
        if let rootRuntime {
            _=try SNESRuntimeFrame(rootRuntime.encoded)
            // Copy only the captured regular leaves, never follow root-library symlinks.
            // All source files live on the already-verified read-only original root.
            var copies="test -d /newroot/lib && test ! -L /newroot/lib\n"
            for (name,chain,bytes) in [("ld-linux-armhf.so.3",rootRuntime.loaderChain,rootRuntime.loader),("libc.so.6",rootRuntime.libcChain,rootRuntime.libc)] {
                let leaf=try { () throws -> String in
                    guard let value=chain.split(separator:">").last else {throw SNESRuntimeBinding.failure()};return String(value)
                }()
                copies += """
                test -f /newroot/lib/\(leaf) && test ! -L /newroot/lib/\(leaf)
                test "$("$B" wc -c < /newroot/lib/\(leaf))" -eq \(bytes.count)
                value=$("$B" sha256sum /newroot/lib/\(leaf))
                test "${value%% *}" = '\(BackupManifest.digest(bytes))'
                test ! -e "$R/\(name)" && test ! -L "$R/\(name)"
                "$B" cp /newroot/lib/\(leaf) "$R/\(name)"
                "$B" chmod 0700 "$R/\(name)"

                """
            }
            preparation=preparation.replacingOccurrences(of:"busybox clovershell ld-linux-armhf.so.3 libc.so.6 original-usb service usb-wrapper runtime-files.sha256",with:"busybox clovershell original-usb service usb-wrapper runtime-files.sha256")
            preparation=preparation.replacingOccurrences(of:"# Verify copied bytes",with:copies+"# Verify copied bytes")
        }
        prepare=preparation
        service = #"""
        #!/bin/sh
        set -eu
        set -o pipefail
        umask 077
        R=/mnt/swifthakchi
        B="$R/busybox"
        G=/sys/devices/virtual/android_usb/android0
        pidfile="$R/daemon.pid"
        owned_pid() {
          test -f "$pidfile" && test ! -L "$pidfile" || return 1
          test "$("$B" stat -c '%h' "$pidfile")" = 1 || return 1
          pid=$("$B" cat "$pidfile")
          case "$pid" in ''|*[!0-9]*) return 1;; esac
          test "$pid" -gt 1 && test "$pid" -le 4194304 || return 1
          test "$("$B" readlink -f "/proc/$pid/exe")" = "$R/ld-linux-armhf.so.3" || return 1
          actual=$("$B" tr '\000' '\n' < "/proc/$pid/cmdline")
          expected=$(printf '%s\n' "$R/ld-linux-armhf.so.3" --inhibit-cache --inhibit-rpath '' --library-path "$R" "$R/clovershell")
          test "$actual" = "$expected" || return 1
          kill -0 "$pid" 2>/dev/null
        }
        stop_daemon() {
          if test -e "$pidfile" || test -L "$pidfile"; then
            if owned_pid; then
              kill "$pid"
              for unused in 1 2 3; do
                if ! kill -0 "$pid" 2>/dev/null; then break; fi
                "$B" sleep 1
              done
              if kill -0 "$pid" 2>/dev/null; then return 1; fi
              "$B" rm "$pidfile"
            else
              return 1
            fi
          fi
        }
        read_original_revision() {
          file="$R/original-usb-revision"
          test -f "$file" && test ! -L "$file" || return 1
          test "$("$B" stat -c '%h' "$file")" = 1 || return 1
          test "$("$B" stat -c '%s' "$file")" = 4 || return 1
          revision=$("$B" cat "$file") || return 1
          valid_revision
        }
        valid_revision() {
          test "${#revision}" = 4 || return 1
          case "$revision" in *[!0123456789abcdefABCDEF]*) return 1;; esac
        }
        restore_revision() {
          if test -e "$R/original-usb-revision" || test -L "$R/original-usb-revision"; then
            read_original_revision || return 1
            for attr in enable bcdDevice; do
              test -f "$G/$attr" && test ! -L "$G/$attr" || return 1
            done
            printf '0' > "$G/enable" || return 1
            printf '%s' "$revision" > "$G/bcdDevice" || return 1
            test "$("$B" cat "$G/bcdDevice")" = "$revision" || return 1
          fi
        }
        stop() {
          status=0
          stop_daemon || status=1
          restore_revision || status=1
          return "$status"
        }
        start() {
          test -d "$R" && test ! -L "$R"
          "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
          if test -e "$pidfile" || test -L "$pidfile"; then owned_pid; return $?; fi
          for attr in enable idVendor idProduct bcdDevice bDeviceClass iProduct functions f_clover/model; do
            test -f "$G/$attr" && test ! -L "$G/$attr"
          done
          if test -e "$R/original-usb-revision" || test -L "$R/original-usb-revision"; then
            read_original_revision
          else
            revision=$("$B" cat "$G/bcdDevice")
            valid_revision
            printf '%s' "$revision" > "$R/original-usb-revision"
          fi
          test -c /dev/usb_clover
          test "$("$B" cat "$G/f_clover/model")" = 3
          printf '0' > "$G/enable"
          printf '1f3a' > "$G/idVendor"
          printf 'efe8' > "$G/idProduct"
          printf '6a04' > "$G/bcdDevice"
          printf '0' > "$G/bDeviceClass"
          printf 'Swift Hakchi SNES Startup' > "$G/iProduct"
          printf 'clover' > "$G/functions"
          for pair in idVendor:1f3a idProduct:efe8 bcdDevice:6a04 bDeviceClass:0 functions:clover f_clover/model:3; do
            test "$("$B" cat "$G/${pair%%:*}")" = "${pair#*:}"
          done
          test "$("$B" cat "$G/iProduct")" = 'Swift Hakchi SNES Startup'
          printf '1' > "$G/enable"
          test "$("$B" cat "$G/enable")" = 1
          (ulimit -f 1024; exec "$R/ld-linux-armhf.so.3" --inhibit-cache --inhibit-rpath '' --library-path "$R" "$R/clovershell") > "$R/daemon.log" 2>&1 &
          pid=$!
          printf '%s\n' "$pid" > "$pidfile"
          "$B" sleep 1
          owned_pid
        }
        case "${1:-}" in
          start) start;;
          stop) stop;;
          *) exit 1;;
        esac
        """# + "\n"
    }
}

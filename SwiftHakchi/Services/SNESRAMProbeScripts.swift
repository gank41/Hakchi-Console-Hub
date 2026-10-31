import Foundation

struct SNESRAMProbeScripts: Sendable {
    static let busyboxSHA256 = "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6"
    let entryPoint = "#!/bin/sh\nexec /probe/busybox sh /probe/early-init\n"
    let earlyInit: String
    let report: String
    init(binding: SNESRuntimeBinding, nonce: String, loaderSHA256: String, libcSHA256: String, daemonSHA256: String) throws {
        try binding.validate()
        guard UUID(uuidString: nonce)?.uuidString == nonce,
              [loaderSHA256, libcSHA256, daemonSHA256].allSatisfy({ $0.count == 64 && SNESRuntimeBinding.hex($0) }),
              daemonSHA256 == "8d36e4c280c7a8f5ce7a4639ffb103947dc4eee7f261230a0cda6b8092e2dfee" else { throw SNESRuntimeBinding.failure() }
        // Only UUID/hex constants are interpolated. No caller path or shell text is accepted.
        earlyInit = #"""
        #!/bin/sh
        set -eu
        umask 077
        B=/probe/busybox
        stage=starting
        trace() {
          stage="$1"
          printf 'Swift Hakchi startup: %s\n' "$stage" >> /probe/stages.log || :
          if test -c /dev/tty0; then
            printf 'Swift Hakchi startup: %s\n' "$stage" > /dev/tty0 || :
          fi
        }
        fail() {
          trap - EXIT
          trace "Stopped at $stage ($1)"
          printf 'failed:%s\n' "$1" > /probe/status || :
          while :; do "$B" sleep 60; done
        }
        trap 'fail command' EXIT
        trace virtual-filesystems
        "$B" mkdir -p /dev /proc /sys /newroot
        "$B" mount -t devtmpfs devtmpfs /dev
        exec </dev/null >/probe/init.log 2>&1
        "$B" mount -t proc proc /proc
        "$B" mount -t sysfs sysfs /sys
        trace file-checks
        "$B" sha256sum -c /probe/files.sha256 > /probe/check.log
        test "$("$B" cat /probe/nonce)" = '__NONCE__' || fail nonce
        readonly_flag=0
        trace command-line
        for flag in $("$B" cat /proc/cmdline); do
          case "$flag" in
            ro) readonly_flag=1;;
            init=/init|root=/dev/nandb) :;;
            rw|rdinit=*|init=*|root=*|hakchi-*) fail command-line;;
          esac
        done
        test "$readonly_flag" = 1 || fail command-line
        trace decrypting-original-system
        /sbin/cryptsetup open /dev/nandb swifthakchi-probe-root --readonly --type plain --cipher aes-xts-plain --key-file /key-file
        trace mounting-original-system
        "$B" mount -t squashfs -o ro,noatime /dev/mapper/swifthakchi-probe-root /newroot
        trace console-identity
        test "$("$B" cat /newroot/etc/clover/boardtype)" = dp-shvc || fail board
        test "$("$B" cat /newroot/etc/clover/REGION)" = USA || fail region
        chip=''
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32)
          chip="$chip$(printf '%08x' "$word")"
        done
        test "$chip" = '__HWID__' || fail identity
        trace mount-checks
        "$B" awk '
          NF!=6 { exit 1 }
          $2=="/" { r++; if($1!="rootfs" || $3!="rootfs") exit 1; next }
          $2=="/dev" { d++; if($3!="devtmpfs") exit 1; next }
          $2=="/proc" { p++; if($3!="proc") exit 1; next }
          $2=="/sys" { s++; if($3!="sysfs") exit 1; next }
          $2=="/newroot" { n++; if($3!="squashfs" || !index("," $4 ",",",ro,") || index("," $4 ",",",rw,")) exit 1; next }
          { exit 1 }
          END { if(r!=1 || d!=1 || p!=1 || s!=1 || n!=1) exit 1 }
        ' /proc/mounts || fail mounts
        trace initial-report
        "$B" sh /probe/report > /probe/initial-report
        trace usb-controller
        role=/sys/devices/sunxi_usb/usb_role
        test -f "$role" && test ! -L "$role" || fail usb-role-attribute
        printf '0' > "$role"
        test "$("$B" cat "$role")" = 0 || fail usb-role-disable
        printf '2' > "$role"
        test "$("$B" cat "$role")" = 2 || fail usb-role-device
        trace usb-attributes
        g=/sys/devices/virtual/android_usb/android0
        for attr in enable idVendor idProduct bcdDevice bDeviceClass iProduct functions; do
          test -f "$g/$attr" && test ! -L "$g/$attr" || fail usb-attributes
        done
        trace usb-descriptors
        printf '0' > "$g/enable"
        printf '1f3a' > "$g/idVendor"
        printf 'efe8' > "$g/idProduct"
        printf '6a01' > "$g/bcdDevice"
        printf '0' > "$g/bDeviceClass"
        printf 'Swift Hakchi SNES RAM Probe' > "$g/iProduct"
        printf 'clover' > "$g/functions"
        test "$("$B" cat "$g/idVendor")" = 1f3a || fail usb-vendor
        test "$("$B" cat "$g/idProduct")" = efe8 || fail usb-product
        test "$("$B" cat "$g/bcdDevice")" = 6a01 || fail usb-version
        test "$("$B" cat "$g/bDeviceClass")" = 0 || fail usb-class
        test "$("$B" cat "$g/iProduct")" = 'Swift Hakchi SNES RAM Probe' || fail usb-name
        test "$("$B" cat "$g/functions")" = clover || fail usb-function
        test -c /dev/usb_clover || fail usb-node
        trace usb-enable
        printf '1' > "$g/enable"
        test "$("$B" cat "$g/enable")" = 1 || fail usb-enable
        trace usb-daemon
        /probe/ld-linux-armhf.so.3 --inhibit-cache --inhibit-rpath '' --library-path /probe /probe/clovershell > /probe/daemon.log 2>&1 &
        daemon=$!
        printf 'ready\n' > /probe/status
        wait "$daemon"
        fail daemon-exited
        """#.replacingOccurrences(of: "__NONCE__", with: nonce).replacingOccurrences(of: "__HWID__", with: binding.expectedHWID)
        report = #"""
        #!/bin/sh
        set -eu
        B=/probe/busybox
        printf 'SWIFTHAKCHI_SNES_RAM_REPORT_V1\nNONCE=%s\nKERNEL=%s\nBOARD=%s\nREGION=%s\n' \
          "$("$B" cat /probe/nonce)" "$("$B" uname -r)" "$("$B" cat /newroot/etc/clover/boardtype)" "$("$B" cat /newroot/etc/clover/REGION)"
        printf 'HWID='
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32); printf '%08x' "$word"
        done
        printf '\n'
        for item in INIT:early-init REPORT:report LOADER:ld-linux-armhf.so.3 LIBC:libc.so.6 DAEMON:clovershell BUSYBOX:busybox; do
          label=${item%%:*}; name=${item#*:}
          sum=$("$B" sha256sum "/probe/$name"); sum=${sum%% *}
          printf '%s_SHA=%s\n' "$label" "$sum"
        done
        printf 'STATUS=%s\n' "$("$B" cat /probe/status 2>/dev/null || printf starting)"
        printf 'MOUNTS_BEGIN\n'; "$B" cat /proc/mounts; printf 'MOUNTS_END\nEND\n'
        """#
    }
}

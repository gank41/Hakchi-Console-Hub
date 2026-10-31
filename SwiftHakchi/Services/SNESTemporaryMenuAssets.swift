import Foundation

/// The original init/rcS and package installers are never entered. Every helper is fixed.
extension SNESTemporaryMenuScripts {
    static func assets(base: SNESRAMProbeScripts, sourceFiles: String) throws -> [String: Data] {
        guard let cut = base.earlyInit.range(of: "trace initial-report") else { throw SNESRuntimeBinding.failure() }
        let early = String(base.earlyInit[..<cut.lowerBound]) + #"""
        trace original-file-checks
        "$B" sha256sum -c /probe/source-files.sha256 > /probe/source-check.log
        . /probe/common
        trace preparing-helpers
        prepare_probe_ram
        exec >> /probe/init.log 2>&1
        trace usb-controller
        role=/sys/devices/sunxi_usb/usb_role
        test -f "$role" && test ! -L "$role" || fail usb-role
        printf '0' > "$role"
        test "$("$B" cat "$role")" = 0 || fail usb-role
        printf '2' > "$role"
        test "$("$B" cat "$role")" = 2 || fail usb-role
        # Pinned 3.4.112 exports boolean hvc, not stock 3.4.113 model.
        # hvc=0 selects only the legacy USB interface string.
        g=/sys/devices/virtual/android_usb/android0
        for attr in enable idVendor idProduct bcdDevice bDeviceClass iProduct functions f_clover/hvc; do
          test -f "$g/$attr" && test ! -L "$g/$attr" || fail usb-attribute
        done
        printf '0' > "$g/enable"
        printf '1f3a' > "$g/idVendor"
        printf 'efe8' > "$g/idProduct"
        printf '6a02' > "$g/bcdDevice"
        printf '0' > "$g/bDeviceClass"
        printf 'Swift Hakchi SNES Menu Test' > "$g/iProduct"
        printf 'clover' > "$g/functions"
        printf '0' > "$g/f_clover/hvc"
        printf '1' > "$g/enable"
        . /probe/common
        require_usb
        trace diagnostic-service
        "$B" mkfifo /probe/daemon.pipe
        cap_log /probe/daemon.log < /probe/daemon.pipe &
        /probe/ld-linux-armhf.so.3 --inhibit-cache --inhibit-rpath '' --library-path /probe /probe/clovershell > /probe/daemon.pipe 2>&1 &
        printf '%s\n' "$!" > /probe/daemon.pid
        trace protecting-storage
        lock_blocks
        trace preparing-ram
        for path in /newroot/dev /newroot/proc /newroot/sys /newroot/var /newroot/run /newroot/tmp /newroot/etc/udev/rules.d /newroot/lib/udev/rules.d; do
          real_dir "$path"
        done
        "$B" mount --bind /dev /newroot/dev
        "$B" mount --bind /proc /newroot/proc
        "$B" mount --bind /sys /newroot/sys
        "$B" mount -t tmpfs -o size=32m,nosuid,nodev,mode=755 tmpfs /newroot/var
        "$B" mount -t tmpfs -o size=8m,nosuid,nodev,mode=755 tmpfs /newroot/run
        "$B" mount -t tmpfs -o size=16m,nosuid,nodev,mode=1777 tmpfs /newroot/tmp
        "$B" mkdir -p /dev/shm /dev/pts
        "$B" mount -t tmpfs -o size=8m,nosuid,nodev,mode=1777 tmpfs /newroot/dev/shm
        "$B" mount -t devpts -o nosuid,noexec devpts /newroot/dev/pts
        "$B" mkdir -p /newroot/var/cache /newroot/var/lock /newroot/var/log /newroot/var/spool \
          /newroot/var/cache/clover/reed-libs/tmp /newroot/var/lib/clover/profiles/0/home-menu \
          /newroot/var/lib/clover/config/reed-libs /newroot/var/lib/profiling-data /newroot/run/swifthakchi
        "$B" ln -s /tmp /newroot/var/tmp
        "$B" ln -s /run /newroot/var/run
        "$B" mount --bind /probe/rules /newroot/etc/udev/rules.d
        "$B" mount --bind /probe/empty-rules /newroot/lib/udev/rules.d
        "$B" mount --bind /probe /newroot/run/swifthakchi
        require_binds
        require_mounts
        printf '/probe/no-module-loader\n' > /proc/sys/kernel/modprobe
        printf '/probe/no-hotplug\n' > /proc/sys/kernel/hotplug
        require_memory
        "$B" mkdir -p /etc
        "$B" cp /probe/inittab /etc/inittab
        trace starting-supervisor
        trap - EXIT
        exec "$B" init
        """#
        let run = #"""
        #!/bin/sh
        set -eu
        umask 077
        ulimit -c 0
        B=/probe/busybox
        fail() { trap - EXIT; printf 'failed:%s\n' "$1" >> /probe/startup-stages; printf 'failed:%s\n' "$1" > /probe/status; exit 1; }
        trap 'fail startup-command' EXIT
        . /probe/common
        require_files
        require_ro_blocks
        await_start_request
        require_startup_base
        startup_stage loading-drivers
        """# + "\n" + loadDrivers + #"""

        require_modules
        startup_stage starting-device-service
        "$B" mkfifo /probe/udev.pipe /probe/menu.pipe
        cap_log /probe/udev.log < /probe/udev.pipe &
        cap_log /probe/menu.log < /probe/menu.pipe &
        "$B" env -i PATH=/sbin:/usr/sbin:/bin:/usr/bin HOME=/root USER=root LANG=C LC_ALL=C \
          "$B" chroot /newroot /sbin/udevd -d > /probe/udev.pipe 2>&1
        startup_stage discovering-devices
        for args in '--type=subsystems --action=add' '--type=devices --action=add' '--settle'; do
          case "$args" in
            --settle) startup_stage settling-devices; "$B" env -i PATH=/sbin:/usr/sbin:/bin:/usr/bin "$B" chroot /newroot /usr/bin/udevadm settle --timeout=30;;
            *) "$B" env -i PATH=/sbin:/usr/sbin:/bin:/usr/bin "$B" chroot /newroot /usr/bin/udevadm trigger $args;;
          esac
        done
        startup_stage checking-devices
        require_devices
        require_memory
        require_runtime
        capture_menu_baseline
        await_menu_request
        startup_stage starting-menu
        "$B" env -i PATH=/sbin:/usr/sbin:/bin:/usr/bin HOME=/root USER=root LANG=C LC_ALL=C MALI_NOCLEAR=1 \
          "$B" chroot /newroot /usr/bin/clover-mcp --gui snes-usa --no-daemon --quiet-children > /probe/menu.pipe 2>&1 &
        mcp=$!
        printf '%s\n' "$mcp" > /probe/menu.pid
        "$B" sleep 2
        require_alive
        startup_stage ready
        trap - EXIT
        while kill -0 "$mcp" 2>/dev/null; do
          daemon=$("$B" cat /probe/daemon.pid)
          kill -0 "$daemon" 2>/dev/null || fail daemon-exited
          "$B" sleep 2
        done
        fail menu-exited
        """#
        let start = #"""
        #!/bin/sh
        set -eu
        umask 077
        B=/probe/busybox
        fail() { exit 1; }
        . /probe/common
        test "$#" = 1 || fail challenge
        challenge="$1"
        case "$challenge" in *[!0-9A-F-]*|'') fail challenge;; esac
        test "${#challenge}" = 36 || fail challenge
        printf 'SNES_STARTUP_STAGE=mac-connected\n' >&2
        test ! -e /probe/host-ready && test ! -L /probe/host-ready || fail startup-owner
        count=0
        while test "$("$B" cat /probe/status 2>/dev/null || printf starting)" != waiting-for-host; do
          test "$count" -lt 30 || fail startup-state
          count=$((count+1)); "$B" sleep 1
        done
        require_startup_base
        test ! -e /probe/host-ready && test ! -L /probe/host-ready || fail startup-owner
        (set -C; printf '%s\n' "$("$B" cat /probe/nonce)" > /probe/host-ready)
        release_menu_after_baseline
        exec "$B" sh /probe/report "$challenge"
        """#
        let report = #"""
        #!/bin/sh
        set -eu
        B=/probe/busybox
        fail() { exit 1; }
        . /probe/common
        test "$#" = 1 || fail challenge
        challenge="$1"
        case "$challenge" in *[!0-9A-F-]*|'') fail challenge;; esac
        test "${#challenge}" = 36 || fail challenge
        wait_until_ready
        require_runtime
        require_alive
        printf 'SWIFTHAKCHI_SNES_MENU_REPORT_V1\nNONCE=%s\nCHALLENGE=%s\nKERNEL=%s\nBOARD=%s\nREGION=%s\n' \
          "$("$B" cat /probe/nonce)" "$challenge" "$("$B" uname -r)" "$("$B" cat /newroot/etc/clover/boardtype)" "$("$B" cat /newroot/etc/clover/REGION)"
        printf 'HWID='
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32); printf '%08x' "$word"
        done
        printf '\n'
        for item in FILES:files.sha256 SOURCE_FILES:source-files.sha256; do
          sum=$("$B" sha256sum "/probe/${item#*:}")
          printf '%s_SHA=%s\n' "${item%%:*}" "${sum%% *}"
        done
        printf 'STATUS=ready\nBLOCKS=readonly\nMODULES=clovercon,mali,sunxi_keyboard,sunxi_knob\nCONTROLLER=loaded-arguments:1,-1,2,-1;36;0;0;8;0\nBINDS=verified\nDEVICES=ready\nUSB=verified-hvc-0\nPROFILE=temporary\nSUPERVISOR=busybox-init\n'
        printf 'TAINT=%s\nMCP_PID=%s\nDAEMON_PID=%s\n' "$("$B" cat /proc/sys/kernel/tainted)" "$("$B" cat /probe/menu.pid)" "$("$B" cat /probe/daemon.pid)"
        "$B" awk '$1=="MemTotal:" {t=$2} $1=="MemFree:" {f=$2} END {printf "FREE_KIB=%d\nTOTAL_KIB=%d\n",f,t}' /proc/meminfo
        printf 'MOUNTS_BEGIN\n'; "$B" cat /proc/mounts; printf 'MOUNTS_END\nEND\n'
        """#
        return ["probe/early-init": Data(early.utf8), "probe/common": Data(common.utf8),
            "probe/start": Data(start.utf8), "probe/report": Data(report.utf8), "probe/run": Data(run.utf8), "probe/source-files.sha256": Data(sourceFiles.utf8),
            "probe/diagnostics": Data(diagnostics.utf8),
            "probe/inittab": Data("::once:/probe/busybox sh /probe/run\n::shutdown:/probe/busybox sh /probe/shutdown\n".utf8),
            "probe/shutdown": Data("#!/bin/sh\nprintf 'stopped\\n' > /probe/status\n".utf8),
            "probe/rules/10-test.rules": Data(rules.utf8)]
    }
    static let diagnostics = #"""
    #!/bin/sh
    set -eu
    B=/probe/busybox
    printf 'SWIFTHAKCHI_SNES_MENU_DIAGNOSTIC_V1\n'
    for name in status stages.log startup-stages init.log daemon.log udev.log menu.log; do
      printf 'FILE:%s\n' "$name"
      if test -f "/probe/$name" && test ! -L "/probe/$name"; then
        "$B" head -c 8192 "/probe/$name"
      fi
      printf '\n'
    done
    printf 'END\n'
    """#
    static let rules = #"""
    SUBSYSTEM=="input", MODE="0660", GROUP="root"
    SUBSYSTEM=="input", DRIVERS=="clovercon", ENV{ID_INPUT}="1", ENV{ID_INPUT_JOYSTICK}="1"
    SUBSYSTEM=="sound", MODE="0660", GROUP="root"
    KERNEL=="mali", MODE="0660", GROUP="root"
    KERNEL=="fb[0-9]*", MODE="0660", GROUP="root"
    KERNEL=="ion", MODE="0660", GROUP="root"
    KERNEL=="disp", MODE="0660", GROUP="root"
    KERNEL=="cedar_dev", MODE="0660", GROUP="root"
    """# + "\n"
    // Linux 3.4 marks the initial rootfs MS_NOUSER: its directories cannot be
    // bind sources. Copy only the fixed test tree to a bounded ordinary tmpfs.
    static let probeRAM = #"""
    prepare_probe_ram() {
      test -d /probe && test ! -L /probe || fail helper-directory
      test ! -e /probe-source && test ! -L /probe-source || fail helper-source
      "$B" mv /probe /probe-source
      B=/probe-source/busybox
      "$B" mkdir /probe
      "$B" mount -t tmpfs -o size=16m,nosuid,nodev,mode=700 tmpfs /probe
      "$B" cp -a /probe-source/. /probe/
      B=/probe/busybox
      "$B" sha256sum -c /probe/files.sha256 > /probe/ram-check.log || fail helper-copy
    }
    """#
    static let common = guards + "\n" + logging + "\n" + supervisor + "\n" + startupGate + "\n" + startupFeedback + "\n" + menuCheckpoint + "\n" + waitReady + "\n" + probeRAM + #"""

    real_dir() {
      local path="$1"
      while test "$path" != /; do
        test -d "$path" && test ! -L "$path" || fail directory
        path=${path%/*}; test -n "$path" || path=/
      done
    }
    require_usb() {
      local g=/sys/devices/virtual/android_usb/android0
      test "$("$B" cat /sys/devices/sunxi_usb/usb_role)" = 2 || fail usb-role
      for pair in enable:1 idVendor:1f3a idProduct:efe8 bcdDevice:6a02 bDeviceClass:0 functions:clover f_clover/hvc:0; do
        test -f "$g/${pair%:*}" && test ! -L "$g/${pair%:*}" || fail usb-attribute
        test "$("$B" cat "$g/${pair%:*}")" = "${pair#*:}" || fail usb-readback
      done
      test "$("$B" cat "$g/iProduct")" = 'Swift Hakchi SNES Menu Test' || fail usb-name
      test -c /dev/usb_clover || fail usb-node
    }
    require_files() {
      "$B" sha256sum -c /probe/files.sha256 > /dev/null || fail recipe-files
      "$B" sha256sum -c /probe/source-files.sha256 > /dev/null || fail source-files
    }
    require_binds() {
      local pair source target
      for pair in /probe/rules:/newroot/etc/udev/rules.d /probe/empty-rules:/newroot/lib/udev/rules.d /probe:/newroot/run/swifthakchi; do
        source=${pair%:*}; target=${pair#*:}
        real_dir "$source"; real_dir "$target"
        test "$("$B" stat -c '%d:%i' "$source")" = "$("$B" stat -c '%d:%i' "$target")" || fail bind
      done
    }
    require_modules() {
      local name pair value
      for name in clovercon mali sunxi_keyboard sunxi_knob; do
        test -d "/sys/module/$name" || fail missing-driver
      done
      # The pinned clovercon ELF marks all six parameters permission zero:
      # the kernel accepts them at insmod but exposes no sysfs readback.
      test -f /probe/controller-load && test ! -L /probe/controller-load || fail controller-load
      test "$("$B" cat /probe/controller-load)" = 'loaded-arguments:1,-1,2,-1;36;0;0;8;0' || fail controller-load
      case "$("$B" cat /proc/sys/kernel/tainted)" in 0|4096) :;; *) fail kernel-taint;; esac
    }
    require_devices() {
      local path
      for path in /dev/mali /dev/fb0 /dev/clovercon1 /dev/snd/pcmC0D0p; do
        test -c "$path" && test ! -L "$path" || fail missing-device
      done
      local found=0
      for path in /dev/input/event*; do test -c "$path" && test ! -L "$path" && found=1; done
      test "$found" = 1 || fail missing-input
    }
    require_alive() {
      local file pid
      for file in /probe/menu.pid /probe/daemon.pid; do
        pid=$("$B" cat "$file")
        case "$pid" in ''|*[!0-9]*) fail process;; esac
        test "$pid" -gt 1 && kill -0 "$pid" 2>/dev/null || fail process
        "$B" awk '$1=="State:" {n++; if($2!~/^[RSDTtWPIN]$/) exit 1} END {if(n!=1) exit 1}' "/proc/$pid/status" || fail process
      done
      require_supervisor
    }
    require_mounts() {
      "$B" awk '
        NF!=6 || $5!="0" || $6!="0" {exit 1}
        seen[$2]++ {exit 1}
        $2=="/" {if($1!="rootfs" || $3!="rootfs") exit 1; next}
        $2=="/dev" || $2=="/newroot/dev" {if($3!="devtmpfs") exit 1; next}
        $2=="/proc" || $2=="/newroot/proc" {if($3!="proc") exit 1; next}
        $2=="/sys" || $2=="/newroot/sys" {if($3!="sysfs") exit 1; next}
        $2=="/newroot" {if(($1!="/dev/mapper/swifthakchi-probe-root" && $1!="/dev/dm-0") || $3!="squashfs" || !index(","$4",",",ro,") || index(","$4",",",rw,")) exit 1; next}
        $2=="/probe" || $2=="/newroot/etc/udev/rules.d" || $2=="/newroot/lib/udev/rules.d" || $2=="/newroot/run/swifthakchi" || $2=="/newroot/var" || $2=="/newroot/run" || $2=="/newroot/tmp" || $2=="/newroot/dev/shm" {
          size=($2=="/newroot/var"?32768:(($2=="/newroot/run" || $2=="/newroot/dev/shm")?8192:16384))
          if($1!="tmpfs" || $3!="tmpfs" || !index(","$4",",",nosuid,") || !index(","$4",",",nodev,") || !index(","$4",",",size="size"k,")) exit 1; next
        }
        $2=="/newroot/dev/pts" {if($3!="devpts") exit 1; next}
        {exit 1}
        END {if(length(seen)!=17) exit 1}
      ' /proc/mounts || fail mounts
    }
    require_startup_base() {
      require_supervisor
      require_files
      require_ro_blocks
      require_binds
      require_mounts
      require_usb
      test "$("$B" cat /proc/sys/kernel/modprobe)" = /probe/no-module-loader || fail autoload
      test "$("$B" cat /proc/sys/kernel/hotplug)" = /probe/no-hotplug || fail hotplug
    }
    require_runtime() {
      require_startup_base
      require_modules
      require_devices
    }
    """#
}

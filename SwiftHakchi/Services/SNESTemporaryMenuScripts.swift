import Foundation

/// Fixed guards shared by the temporary startup and report; no caller paths or commands.
enum SNESTemporaryMenuScripts {
    static let startupGate = #"""
    startup_stage() {
      printf '%s\n' "$1" >> /probe/startup-stages
      printf '%s\n' "$1" > /probe/status
    }
    await_start_request() {
      local count=0
      startup_stage waiting-for-host
      while test "$count" -lt 120; do
        if test -e /probe/host-ready || test -L /probe/host-ready; then
          test -f /probe/host-ready && test ! -L /probe/host-ready || fail startup-owner
          test "$("$B" cat /probe/host-ready)" = "$("$B" cat /probe/nonce)" || fail startup-owner
          return 0
        fi
        count=$((count+1)); "$B" sleep 1
      done
      fail host-timeout
    }
    """#
    // stderr evidence never grants readiness; only the final report can do so.
    static let startupFeedback = #"""
    emit_startup_stages() {
      local snapshot progress
      if test -f /probe/startup-stages && test ! -L /probe/startup-stages; then
        snapshot=$("$B" awk -v skip="$emitted" '
          NR>32 || length($0)>80 || $0!~/^[a-z-]+(:[a-z-]+)?$/ {exit 1}
          NR>skip {print "SNES_STARTUP_STAGE=" $0}
          END {if(NR>32) exit 1; printf "COUNT=%d",NR}
        ' /probe/startup-stages) || fail startup-log
        emitted=${snapshot##*COUNT=}; progress=${snapshot%COUNT=*}
        test -z "$progress" || printf '%s' "$progress" >&2
      fi
    }
    emit_menu_output() {
      local size count
      if test -f /probe/menu.log && test ! -L /probe/menu.log; then
        size=$("$B" wc -c < /probe/menu.log)
        test "$size" -le 8192 || size=8192
        if test "$size" -gt "$menu_emitted"; then
          count=$((size-menu_emitted))
          printf '\nSNES_MENU_OUTPUT_BYTES=%s\n' "$count" >&2
          "$B" dd if=/probe/menu.log bs=1 skip="$menu_emitted" count="$count" >&2 2>/dev/null || fail menu-log
          menu_emitted=$size
        fi
      fi
    }
    """#
    static let menuCheckpoint = #"""
    capture_menu_baseline() {
      local kernel
      test ! -e /probe/menu-baseline && test ! -L /probe/menu-baseline || fail menu-baseline
      test ! -e /probe/menu-host-ready && test ! -L /probe/menu-host-ready || fail menu-owner
      (set -C; {
        printf 'SNES_PRE_MENU_BEGIN\nPOWER_SWITCH='
        if test -f /sys/devices/knob/power_switch && test ! -L /sys/devices/knob/power_switch; then
          "$B" head -c 32 /sys/devices/knob/power_switch
        else printf 'unavailable\n'; fi
        printf '\nMEMORY_BEGIN\n'; "$B" head -c 2048 /proc/meminfo
        printf '\nINPUT_BEGIN\n'; "$B" head -c 4096 /proc/bus/input/devices
        printf '\nKERNEL_BEGIN\n'
        kernel=$("$B" dmesg -s 8192) || fail kernel-baseline
        printf '%s\n' "$kernel" | "$B" tail -c 8192
        printf '\nSNES_PRE_MENU_END\n'
      } > /probe/menu-baseline)
    }
    await_menu_request() {
      local count=0
      startup_stage waiting-for-menu-host
      while test "$count" -lt 45; do
        if test -e /probe/menu-host-ready || test -L /probe/menu-host-ready; then
          test -f /probe/menu-host-ready && test ! -L /probe/menu-host-ready || fail menu-owner
          test "$("$B" cat /probe/menu-host-ready)" = "$("$B" cat /probe/nonce)" || fail menu-owner
          return 0
        fi
        count=$((count+1)); "$B" sleep 1
      done
      fail menu-host-timeout
    }
    release_menu_after_baseline() {
      local count=0 emitted=0 status size
      test ! -e /probe/menu-host-ready && test ! -L /probe/menu-host-ready || fail menu-owner
      while test "$count" -lt 45; do
        emit_startup_stages
        status=$("$B" cat /probe/status 2>/dev/null || printf starting)
        case "$status" in
          waiting-for-menu-host) break;;
          failed:*|stopped) fail startup;;
        esac
        count=$((count+1)); "$B" sleep 1
      done
      test "$count" -lt 45 || fail menu-baseline-timeout
      require_runtime
      test -f /probe/menu-baseline && test ! -L /probe/menu-baseline || fail menu-baseline
      size=$("$B" wc -c < /probe/menu-baseline)
      test "$size" -gt 0 && test "$size" -le 16384 || fail menu-baseline-size
      "$B" cat /probe/menu-baseline >&2
      # Queues evidence to the owning USB process; this is not a host receipt.
      (set -C; printf '%s\n' "$("$B" cat /probe/nonce)" > /probe/menu-host-ready)
    }
    """#
    static let waitReady = #"""
    wait_until_ready() {
      local count=0 status emitted=0 menu_emitted=0
      while test "$count" -lt 75; do
        status=$("$B" cat /probe/status 2>/dev/null || printf starting)
        emit_startup_stages
        emit_menu_output
        case "$status" in ready) return 0;; failed:*|stopped) fail startup;; esac
        count=$((count+1)); "$B" sleep 1
      done
      fail startup-timeout
    }
    """#
    static let supervisor = #"""
    require_supervisor() {
      test "$("$B" readlink /proc/1/exe)" = /probe/busybox || fail supervisor
      test "$("$B" tr '\000' ' ' < /proc/1/cmdline)" = '/probe/busybox init ' || fail supervisor
    }
    """#
    static let logging = #"""
    cap_log() {
      "$B" head -c 1048576 > "$1"
      "$B" cat > /dev/null
    }
    """#
    static let guards = #"""
    block_identity() {
      local name="$1" node="/dev/$1" pair actual expected
      test -b "$node" && test ! -L "$node" || fail block-node
      pair=$("$B" stat -c '%t:%T' "$node") || fail block-stat
      actual=$(printf '%d:%d' "0x${pair%:*}" "0x${pair#*:}") || fail block-stat
      expected=$("$B" cat "/sys/class/block/$name/dev") || fail block-identity
      test "$actual" = "$expected" || fail block-identity
    }
    lock_blocks() {
      local name
      for name in nanda nandb nandc nandd nande; do
        block_identity "$name"
        "$B" blockdev --setro "/dev/$name" || fail block-protection
        test "$("$B" blockdev --getro "/dev/$name")" = 1 || fail block-protection
      done
    }
    require_ro_blocks() {
      local name
      for name in nanda nandb nandc nandd nande; do
        block_identity "$name"
        test "$("$B" blockdev --getro "/dev/$name")" = 1 || fail block-protection
      done
    }
    require_memory() {
      "$B" awk '$1=="MemFree:" || $1=="Buffers:" || $1=="Cached:" { n+=$2 } END { if(n<49152) exit 1 }' /proc/meminfo || fail memory
    }
    """#
    static let loadDrivers = #"""
    test ! -e /probe/controller-load && test ! -L /probe/controller-load || fail driver-state
    startup_stage loading-mali
    "$B" insmod /probe/mali.ko || fail driver-mali
    startup_stage loading-controller
    "$B" insmod /probe/clovercon.ko module_params=1,-1,2,-1 home_combination=36 autofire=0 autofire_xy=0 autofire_interval=8 fc_start=0 || fail driver-controller
    startup_stage loading-keyboard
    "$B" insmod /probe/sunxi-keyboard.ko || fail driver-keyboard
    startup_stage loading-power-button
    "$B" insmod /probe/sunxi-knob.ko || fail driver-knob
    printf 'loaded-arguments:1,-1,2,-1;36;0;0;8;0\n' > /probe/controller-load
    """#

}

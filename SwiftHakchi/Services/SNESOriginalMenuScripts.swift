import Foundation

/// Separate stock-component recipe. Old image capabilities and USB identities remain unchanged.
enum SNESOriginalMenuScripts {
    static func assets(base: SNESRAMProbeScripts, sourceFiles: String) throws -> [String: Data] {
        var files = try SNESTemporaryMenuScripts.assets(base: base, sourceFiles: sourceFiles)
        func text(_ name: String) throws -> String {
            guard let data = files[name], let value = String(data: data, encoding: .utf8) else { throw SNESRuntimeBinding.failure() }; return value
        }
        var early = try text("probe/early-init")
        try replace(&early, "# Pinned 3.4.112 exports boolean hvc, not stock 3.4.113 model.\n# hvc=0 selects only the legacy USB interface string.", "# Original dp-shvc USA startup uses the model attribute with value 3.")
        // The stock kernel and captured S90usb-gadget expose no custom usb_role control.
        try replace(&early, "role=/sys/devices/sunxi_usb/usb_role\ntest -f \"$role\" && test ! -L \"$role\" || fail usb-role\nprintf '0' > \"$role\"\ntest \"$(\"$B\" cat \"$role\")\" = 0 || fail usb-role\nprintf '2' > \"$role\"\ntest \"$(\"$B\" cat \"$role\")\" = 2 || fail usb-role\n", "")
        try replace(&early, "f_clover/hvc;", "f_clover/model;")
        try replace(&early, "printf '0' > \"$g/f_clover/hvc\"", "printf '3' > \"$g/f_clover/model\"")
        try replace(&early, "printf '6a02'", "printf '6a03'")
        try replace(&early, "'Swift Hakchi SNES Menu Test'", "'Swift Hakchi SNES Original Menu Test'")
        var common = try text("probe/common")
        try replace(&common, SNESTemporaryMenuScripts.menuCheckpoint, checkpointHelpers)
        try replace(&common, "  test \"$(\"$B\" cat /sys/devices/sunxi_usb/usb_role)\" = 2 || fail usb-role\n", "")
        try replace(&common, "bcdDevice:6a02", "bcdDevice:6a03")
        try replace(&common, "f_clover/hvc:0", "f_clover/model:3")
        try replace(&common, "'Swift Hakchi SNES Menu Test'", "'Swift Hakchi SNES Original Menu Test'")
        common = try block(common, from: "require_modules() {", to: "require_devices() {", replacement: modules + "\n")
        common = try block(common, from: "require_devices() {", to: "require_alive() {", replacement: devices + "\n")
        try replace(&common, "require_startup_base() {\n  require_supervisor", "require_startup_base() {\n  test \"$(\"$B\" uname -r)\" = 3.4.113 || fail kernel\n  require_supervisor")
        try replace(&common, "require_runtime() {\n  require_startup_base", "require_runtime() {\n  test \"$(\"$B\" cat /sys/devices/knob/power_switch)\" = 1 || fail power-switch\n  require_startup_base")
        var run = try text("probe/run")
        try replace(&run, SNESTemporaryMenuScripts.loadDrivers, drivers)
        try replace(&run, "\"$B\" mkfifo /probe/udev.pipe /probe/menu.pipe", #"""
        for log in udev.log menu.log; do
          test ! -e "/probe/$log" && test ! -L "/probe/$log" || fail log-owner
          (set -C; : > "/probe/$log") || fail log-create
        done
        "$B" mkfifo /probe/udev.pipe /probe/menu.pipe
        """#)

        var rules = try text("probe/rules/10-test.rules")
        try replace(&rules, "DRIVERS==\"clovercon\"", "DRIVERS==\"clvcon\"")
        // The power-only knob is not recognized by SDL's generic keyboard fallback.
        // Preserve the original input class without enabling captured udev programs.
        rules += #"""
        SUBSYSTEM=="input", ATTRS{name}=="sunxi-knob", ENV{ID_INPUT}="1", ENV{ID_INPUT_KEY}="1"
        SUBSYSTEM=="input", ATTRS{name}=="sunxi-keyboard", ENV{ID_INPUT}="1", ENV{ID_INPUT_KEY}="1"
        """# + "\n"
        files["probe/early-init"] = Data(early.utf8); files["probe/common"] = Data(common.utf8)
        files["probe/run"] = Data(run.utf8); files["probe/rules/10-test.rules"] = Data(rules.utf8)
        files.removeValue(forKey: "probe/start")
        files["probe/checkpoint"] = Data(checkpoint.utf8); files["probe/launch"] = Data(launch.utf8)
        files["probe/report"] = Data(report.utf8)
        files["probe/diagnostics"] = Data(diagnostics.utf8)
        return files
    }
    private static func replace(_ value: inout String, _ old: String, _ new: String) throws {
        guard let range = value.range(of: old), range == value.range(of: old, options: .backwards) else { throw SNESRuntimeBinding.failure() }
        value.replaceSubrange(range, with: new)
    }
    private static func block(_ value: String, from: String, to: String, replacement: String) throws -> String {
        guard let start = value.range(of: from), start == value.range(of: from, options: .backwards),
              let end = value.range(of: to), end == value.range(of: to, options: .backwards), start.lowerBound < end.lowerBound else { throw SNESRuntimeBinding.failure() }
        return String(value[..<start.lowerBound]) + replacement + value[end.lowerBound...]
    }
    static let drivers = #"""
    test ! -e /probe/controller-load && test ! -L /probe/controller-load || fail driver-state
    startup_stage loading-power-button
    "$B" insmod /probe/sunxi-knob.ko || fail driver-knob
    startup_stage loading-keyboard
    "$B" insmod /probe/sunxi-keyboard.ko || fail driver-keyboard
    startup_stage loading-controller
    "$B" insmod /probe/clvcon.ko module_params=1,195,2,194 || fail driver-controller
    printf 'loaded-arguments:1,195,2,194\n' > /probe/controller-load
    startup_stage loading-mali
    "$B" insmod /probe/mali.ko || fail driver-mali
    """#
    static let modules = #"""
    require_modules() {
      local name
      for name in clvcon mali sunxi_keyboard sunxi_knob; do
        test -d "/sys/module/$name" || fail missing-driver
      done
      # Audited original clvcon module_params permission is zero: no sysfs readback exists.
      test -f /probe/controller-load && test ! -L /probe/controller-load || fail controller-load
      test "$("$B" cat /probe/controller-load)" = 'loaded-arguments:1,195,2,194' || fail controller-load
      case "$("$B" cat /proc/sys/kernel/tainted)" in 0|4096) :;; *) fail kernel-taint;; esac
    }
    """#
    static let keyInputs = #"""
    require_key_properties() {
      local metadata count
      test -f "$1" && test ! -L "$1" || fail key-properties
      metadata=$("$B" stat -c '%s:%h' "$1") || fail key-properties
      case "$metadata" in *:1) count=${metadata%:*};; *) fail key-properties;; esac
      case "$count" in ''|*[!0-9]*) fail key-properties;; esac
      test "$count" -gt 0 && test "$count" -le 8192 || fail key-properties
      "$B" awk '
        /^E:ID_INPUT=/ {input++; if($0!="E:ID_INPUT=1") bad=1}
        /^E:ID_INPUT_KEY=/ {key++; if($0!="E:ID_INPUT_KEY=1") bad=1}
        END {if(bad || input!=1 || key!=1) exit 1}
      ' "$1" || fail key-properties
    }
    require_key_inputs() {
      local path name event device minor power=0 reset=0
      real_dir /newroot/run/udev
      real_dir /newroot/run/udev/data
      for path in /sys/class/input/event*/device/name; do
        test -f "$path" || continue
        name=$("$B" head -c 64 "$path") || fail input-name
        case "$name" in
          sunxi-knob|sunxi-keyboard)
            event=${path%/device/name}; event=${event##*/}
            test -c "/dev/input/$event" && test ! -L "/dev/input/$event" || fail key-event
            device=$("$B" head -c 64 "${path%/device/name}/dev") || fail key-device
            case "$device" in 13:*) minor=${device#13:};; *) fail key-device;; esac
            case "$minor" in ''|*[!0-9]*) fail key-device;; esac
            test "$minor" -le 1048575 || fail key-device
            require_key_properties "/newroot/run/udev/data/c13:$minor"
            case "$name" in sunxi-knob) power=$((power+1));; sunxi-keyboard) reset=$((reset+1));; esac;;
        esac
      done
      test "$power:$reset" = 1:1 || fail missing-key-input
    }
    """#
    static let devices = keyInputs + "\n" + #"""
    require_devices() {
      local path name found=0
      for path in /dev/mali /dev/fb0 /dev/snd/pcmC0D0p; do
        test -c "$path" && test ! -L "$path" || fail missing-device
      done
      for path in /sys/class/input/event*/device/name; do
        test -f "$path" || continue
        name=$("$B" cat "$path") || fail input-name
        if test "$name" = 'Nintendo Clovercon - controller1'; then
          name=${path%/device/name}; name=${name##*/}
          test -c "/dev/input/$name" && test ! -L "/dev/input/$name" || fail controller-event
          found=1
        fi
      done
      test "$found" = 1 || fail missing-controller
      require_key_inputs
    }
    """#
    // The pinned original 3.4.113 kernel maps syslog to sys_ni_syscall (ENOSYS).
    // Record that known absence explicitly; permission, usage and empty-output failures still stop.
    static let kernelLogReader = #"""
    read_kernel_log() {
      local output
      if output=$("$B" dmesg -s 8192 2>&1); then
        test -n "$output" || return 1
        printf '%s\n' "$output"
      else
        case "$output" in
          'dmesg: klogctl: Function not implemented')
            printf 'SNES_KERNEL_LOG_UNAVAILABLE=ENOSYS\n';;
          *) printf '%s\n' "$output" >&2; return 1;;
        esac
      fi
    }
    """#
    static let startupDetails = #"""
    capture_startup_details() {
      local path source maximum content count hash metadata
      printf 'SNES_STARTUP_DETAILS_BEGIN\n'
      for item in /proc/cmdline:1024 /sys/class/graphics/fb0/name:128 /sys/class/graphics/fb0/virtual_size:128 /sys/class/graphics/fb0/bits_per_pixel:128 /usr/share/applications/clover-mcp.desktop:4096 /usr/share/applications/clover-ui.menu.desktop:2048 /usr/share/applications/clover-ui.test.desktop:2048 /usr/share/applications/clover-reset.factory.desktop:2048 /usr/share/applications/clover-reset.menu.desktop:2048 /etc/clover/LANGUAGE:128 /proc/iomem:8192; do
        path=${item%:*}; maximum=${item##*:}; source="$path"
        case "$path" in
          /usr/*) source="/newroot$path"; real_dir /newroot/usr/share/applications;;
          /etc/*) source="/newroot$path"; real_dir /newroot/etc/clover;;
        esac
        test ! -L "$source" || fail detail-link
        if test ! -e "$source"; then
          case "$path" in /sys/*|/etc/clover/LANGUAGE|/usr/share/applications/clover-ui.*.desktop|/usr/share/applications/clover-reset.*.desktop) printf 'FILE %s A 0 -\n\n' "$path"; continue;; *) fail missing-detail;; esac
        fi
        test -f "$source" || fail detail-file
        case "$path" in /usr/*|/etc/*)
          metadata=$("$B" stat -c '%s:%h' "$source") || fail detail-stat
          test "${metadata##*:}" = 1 && test "${metadata%:*}" -le "$maximum" || fail detail-size;;
        esac
        # Sentinel preserves final newlines. Read at most limit+1; oversized files refuse.
        content=$("$B" head -c "$((maximum+1))" "$source" && printf '.') || fail detail-read
        content=${content%.}
        count=$(printf '%s' "$content" | "$B" wc -c) || fail detail-count
        test "$count" -gt 0 && test "$count" -le "$maximum" || fail detail-size
        case "$path" in /usr/*|/etc/*) test "$count" = "${metadata%:*}" || fail detail-size;; esac
        hash=$(printf '%s' "$content" | "$B" sha256sum) || fail detail-hash
        printf 'FILE %s F %s %s\n' "$path" "$count" "${hash%% *}"
        printf '%s\n' "$content"
      done
      printf 'SNES_STARTUP_DETAILS_END\n'
    }
    """#
    static let checkpointHelpers = kernelLogReader + "\n" + startupDetails + "\n" + #"""
    capture_menu_baseline() {
      local kernel
      test ! -e /probe/menu-baseline && test ! -L /probe/menu-baseline || fail menu-baseline
      test ! -e /probe/menu-host-ready && test ! -L /probe/menu-host-ready || fail menu-owner
      (set -C; {
        printf 'SNES_PRE_MENU_BEGIN\nPOWER_SWITCH='
        "$B" head -c 32 /sys/devices/knob/power_switch
        printf '\nMEMORY_BEGIN\n'; "$B" head -c 2048 /proc/meminfo
        printf '\nINPUT_BEGIN\n'; "$B" head -c 4096 /proc/bus/input/devices
        printf '\nKERNEL_BEGIN\n'
        kernel=$(read_kernel_log) || fail kernel-baseline
        printf '%s\n' "$kernel" | "$B" tail -c 8192
        printf '\n'
        capture_startup_details
        printf 'SNES_PRE_MENU_END\n'
      } > /probe/menu-baseline)
    }
    await_menu_request() {
      local count=0
      startup_stage waiting-for-menu-host
      while test "$count" -lt 180; do
        if test -e /probe/menu-host-ready || test -L /probe/menu-host-ready; then
          test -f /probe/menu-host-ready && test ! -L /probe/menu-host-ready || fail menu-owner
          test "$("$B" cat /probe/menu-host-ready)" = "$("$B" cat /probe/nonce)" || fail menu-owner
          return 0
        fi
        count=$((count+1)); "$B" sleep 1
      done
      fail menu-host-timeout
    }
    """#
    static let checkpoint = #"""
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
    test ! -e /probe/host-ready && test ! -L /probe/host-ready || fail startup-owner
    count=0
    while test "$("$B" cat /probe/status 2>/dev/null || printf starting)" != waiting-for-host; do
      test "$count" -lt 30 || fail startup-state
      count=$((count+1)); "$B" sleep 1
    done
    require_startup_base
    (set -C; printf '%s\n' "$("$B" cat /probe/nonce)" > /probe/host-ready)
    exec "$B" sh /probe/report pre-menu "$challenge"
    """#
    static let launch = #"""
    #!/bin/sh
    set -eu
    umask 077
    B=/probe/busybox
    fail() { exit 1; }
    . /probe/common
    test "$#" = 3 || fail request
    nonce="$1"; challenge="$2"; digest="$3"
    case "$nonce$challenge" in *[!0-9A-F-]*|'') fail request;; esac
    test "${#nonce}" = 36 && test "${#challenge}" = 36 || fail request
    case "$digest" in *[!0-9a-f]*|'') fail digest;; esac
    test "${#digest}" = 64 || fail digest
    test "$("$B" cat /probe/nonce)" = "$nonce" || fail nonce
    test "$("$B" cat /probe/status)" = waiting-for-menu-host || fail state
    test ! -e /probe/menu-host-ready && test ! -L /probe/menu-host-ready || fail owner
    test ! -e /probe/launch-check && test ! -L /probe/launch-check || fail owner
    require_runtime
    (set -C; "$B" sh /probe/report pre-menu "$challenge" > /probe/launch-check) || fail checkpoint
    actual=$("$B" sha256sum /probe/launch-check) || fail digest
    test "${actual%% *}" = "$digest" || fail digest
    require_runtime
    (set -C; printf '%s\n' "$nonce" > /probe/menu-host-ready) || fail owner
    printf 'SWIFTHAKCHI_SNES_ORIGINAL_LAUNCH_V1\nNONCE=%s\nCHECKPOINT_SHA=%s\nEND\n' "$nonce" "$digest"
    """#
    static let report = #"""
    #!/bin/sh
    set -eu
    B=/probe/busybox
    fail() { exit 1; }
    . /probe/common
    test "$#" = 2 || fail challenge
    state="$1"; challenge="$2"
    case "$challenge" in *[!0-9A-F-]*|'') fail challenge;; esac
    test "${#challenge}" = 36 || fail challenge
    case "$state" in
      pre-menu)
        count=0; emitted=0
        while test "$("$B" cat /probe/status 2>/dev/null || printf starting)" != waiting-for-menu-host; do
          emit_startup_stages
          case "$("$B" cat /probe/status 2>/dev/null || printf starting)" in failed:*|stopped|ready) fail state;; esac
          test "$count" -lt 60 || fail state
          count=$((count+1)); "$B" sleep 1
        done
        test ! -e /probe/menu.pid && test ! -L /probe/menu.pid || fail state
        test ! -e /probe/menu-host-ready && test ! -L /probe/menu-host-ready || fail state
        mcp=0;;
      ready) wait_until_ready; require_alive; mcp=$("$B" cat /probe/menu.pid) || fail pid;;
      *) fail state;;
    esac
    require_runtime
    test -f /probe/menu-baseline && test ! -L /probe/menu-baseline || fail baseline
    meta=$("$B" stat -c '%s:%h' /probe/menu-baseline) || fail baseline
    size=${meta%:*}; test "${meta##*:}" = 1 && test "$size" -gt 0 && test "$size" -le 32768 || fail baseline
    hash=$("$B" sha256sum /probe/menu-baseline) || fail baseline
    daemon=$("$B" cat /probe/daemon.pid) || fail pid
    case "$daemon" in ''|*[!0-9]*) fail pid;; esac
    test "$daemon" -gt 1 && kill -0 "$daemon" 2>/dev/null || fail pid
    printf 'SWIFTHAKCHI_SNES_ORIGINAL_MENU_V1\nNONCE=%s\nCHALLENGE=%s\nKERNEL=%s\nBOARD=%s\nREGION=%s\n' \
      "$("$B" cat /probe/nonce)" "$challenge" "$("$B" uname -r)" "$("$B" cat /newroot/etc/clover/boardtype)" "$("$B" cat /newroot/etc/clover/REGION)"
    printf 'HWID='
    for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
      word=$("$B" devmem "$address" 32); printf '%08x' "$word"
    done
    printf '\n'
    for item in FILES:files.sha256 SOURCE_FILES:source-files.sha256 COMPONENTS:components.sha256; do
      sum=$("$B" sha256sum "/probe/${item#*:}") || fail hash
      printf '%s_SHA=%s\n' "${item%%:*}" "${sum%% *}"
    done
    printf 'STATE=%s\nBLOCKS=readonly\nMODULES=clvcon,mali,sunxi_keyboard,sunxi_knob\nCONTROLLER=loaded-arguments:1,195,2,194\nBINDS=verified\nDEVICES=ready\nUSB=verified-model-3\nPROFILE=temporary\nSUPERVISOR=busybox-init\n' "$state"
    printf 'TAINT=%s\nMCP_PID=%s\nDAEMON_PID=%s\n' "$("$B" cat /proc/sys/kernel/tainted)" "$mcp" "$daemon"
    printf 'BASELINE %s %s\n' "$size" "${hash%% *}"
    "$B" cat /probe/menu-baseline || fail baseline
    printf '\nMOUNTS_BEGIN\n'; "$B" cat /proc/mounts
    printf 'MOUNTS_END\nEND\n'
    """#
}

extension SNESOriginalMenuScripts {
    static let diagnostics = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    B=/probe/busybox
    fail() { exit 1; }
    """# + "\n" + kernelLogReader + "\n" + #"""
    printf 'SWIFTHAKCHI_ORIGINAL_LOGS_V1\nNONCE=%s\n' "$("$B" cat /probe/nonce)"
    emit() {
      local count hash
      count=$(printf '%s' "$content" | "$B" wc -c) || fail count
      hash=$(printf '%s' "$content" | "$B" sha256sum) || fail hash
      printf 'LOG %s %s %s\n' "$name" "$count" "${hash%% *}"
      printf '%s\n' "$content"
    }
    for name in startup-stages init.log daemon.log udev.log menu.log; do
      path="/probe/$name"
      test -f "$path" && test ! -L "$path" || fail missing-log
      meta=$("$B" stat -c '%s:%h' "$path") || fail log-stat
      test "${meta##*:}" = 1 && test "${meta%:*}" -le 1048576 || fail log-size
      content=$("$B" head -c 8192 "$path") || fail log-read
      test "$name" != startup-stages || test -n "$content" || fail empty-stages
      emit
    done
    name=kernel
    content=$(read_kernel_log) || fail kernel-log
    test -n "$content" || fail kernel-log
    content=$(printf '%s' "$content" | "$B" tail -c 8192) || fail kernel-log
    emit
    printf 'END\n'
    """#
}

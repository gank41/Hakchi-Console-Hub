import Foundation
import SwiftHakchiCore

enum SNESStartupTrialCommands {
    static func script(trial:PreparedSNESStartupTrial,challenge:UUID) throws -> String {
        try trial.validateCurrent();let expected=try SNESStartupTrialExpectation.checked(trial)
        let material=trial.candidate.material
        let audit=try SNESStartupAdapterSource(stock:material.support.setup.stock,startup:material.support.source.preparation.startup)
        var checks=String(decoding:audit.rootChecks,as:UTF8.self)
            .replacingOccurrences(of:"/newroot/etc/init.d/S90usb-gadget",with:"/mnt/swifthakchi/original-usb").replacingOccurrences(of:"/newroot/",with:"/")
        var menuChecks=""
        if expected.menuEnabled {
            checks=checks.replacingOccurrences(of:"/etc/init.d/S81clover-mcp",with:"/mnt/swifthakchi/original-menu-init")
            checks+=SNESMenuAdapterScripts.mcpDesktopSHA256+"  /mnt/swifthakchi/mcp-template\n"
            menuChecks = #"""
            value=$("$B" sha256sum /etc/init.d/S81clover-mcp); test "${value%% *}" = '__MENU_SHA__'
            selected=$("$B" awk '$2=="/usr/share/applications/clover-mcp.desktop" {n++} END {print n+0}' /proc/mounts)
            case "$selected" in
              0) value=$("$B" sha256sum /usr/share/applications/clover-mcp.desktop);test "${value%% *}" = '__MCP_SHA__';;
              1)
                folder=$("$B" sh "$R/menu-selector")
                value=$("$B" awk -v folder="$folder" '$0=="GamesFolder = /usr/share/games" {print "GamesFolder = " folder;n++;next}{print}END{if(n!=1)exit 1}' "$R/mcp-template" | "$B" sha256sum)
                actual=$("$B" sha256sum /usr/share/applications/clover-mcp.desktop);test "${actual%% *}" = "${value%% *}"
                test "$("$B" stat -c '%d:%i' /usr/share/applications/clover-mcp.desktop)" = "$("$B" stat -c '%d:%i' "$R/mcp-selected")";;
              *) exit 1;;
            esac
            """#.replacingOccurrences(of:"__MENU_SHA__",with:expected.menuWrapperSHA256!)
                .replacingOccurrences(of:"__MCP_SHA__",with:SNESMenuAdapterScripts.mcpDesktopSHA256)+"\n"
        }
        if trial.candidate.hasLibrarySupport {
            menuChecks=menuChecks.replacingOccurrences(of:"$R/menu-selector",with:"$R/menu-route")
        }
        guard let mcp=material.support.frame.records.first(where:{$0.path=="usr/bin/clover-mcp"}),SNESDataSnapshotChunk.isDigest(mcp.digest) else {throw SNESRuntimeBinding.failure()}
        checks+=mcp.digest+"  /usr/bin/clover-mcp\n"
        var script = #"""
        set -eu
        set -o pipefail
        B=/mnt/swifthakchi/busybox
        R=/mnt/swifthakchi
        G=/sys/devices/virtual/android_usb/android0
        test -d "$R" && test ! -L "$R"
        for name in busybox runtime-files.sha256 daemon.pid; do test -f "$R/$name" && test ! -L "$R/$name"; done
        value=$("$B" sha256sum "$R/runtime-files.sha256"); test "${value%% *}" = '__RUNTIME__'
        "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
        printf '%s' __ROOT_CHECKS__ | "$B" sha256sum -c - >/dev/null
        value=$("$B" sha256sum /etc/init.d/S90usb-gadget); test "${value%% *}" = '__WRAPPER__'
        test "$("$B" uname -r)" = 3.4.113
        test "$("$B" cat /etc/clover/boardtype)" = dp-shvc
        test "$("$B" cat /etc/clover/REGION)" = USA
        chip=''
        for address in 0x01c23800 0x01c23804 0x01c23808 0x01c2380c; do
          word=$("$B" devmem "$address" 32); chip="$chip$(printf '%08x' "$word")"
        done
        test "$chip" = '__HWID__'
        for pair in enable:1 idVendor:1f3a idProduct:efe8 bcdDevice:__BCD__ bDeviceClass:0 functions:clover f_clover/model:3; do
          attr=${pair%%:*}; test -f "$G/$attr" && test ! -L "$G/$attr"
          test "$("$B" cat "$G/$attr")" = "${pair#*:}"
        done
        test "$("$B" cat "$G/iProduct")" = 'Swift Hakchi SNES Startup'
        test "$("$B" readlink -f /proc/1/exe)" = /bin/busybox
        test "$("$B" stat -c '%h' "$R/daemon.pid")" = 1
        test "$("$B" stat -c '%u' "$R/daemon.pid")" = 0
        daemon=$("$B" cat "$R/daemon.pid")
        mcp=$("$B" pidof clover-mcp)
        for pid in "$daemon" "$mcp"; do
          case "$pid" in ''|*[!0-9]*) exit 1;; esac
          test "$pid" -gt 1 && test "$pid" -le 4194304
        done
        test "$daemon" != "$mcp"
        test "$("$B" readlink -f "/proc/$daemon/exe")" = "$R/ld-linux-armhf.so.3"
        actual=$("$B" tr '\000' '\n' < "/proc/$daemon/cmdline")
        wanted=$(printf '%s\n' "$R/ld-linux-armhf.so.3" --inhibit-cache --inhibit-rpath '' --library-path "$R" "$R/clovershell")
        test "$actual" = "$wanted"
        test "$("$B" readlink -f "/proc/$mcp/exe")" = /usr/bin/clover-mcp
        for name in clvcon mali sunxi_keyboard sunxi_knob; do test -d "/sys/module/$name"; done
        for path in /dev/mali /dev/fb0 /dev/snd/pcmC0D0p; do test -c "$path" && test ! -L "$path" || exit 1; done
        found=0
        for path in /sys/class/input/event*/device/name; do
          test -f "$path" || continue
          if test "$("$B" cat "$path")" = 'Nintendo Clovercon - controller1'; then
            event=${path%/device/name}; event=${event##*/};test -c "/dev/input/$event" && test ! -L "/dev/input/$event" || exit 1;found=$((found+1))
          fi
        done
        test "$found" = 1
        __MENU_CHECKS__
        taint=$("$B" cat /proc/sys/kernel/tainted);case "$taint" in 0|4096) :;; *) exit 1;; esac
        printf 'SWIFTHAKCHI_SNES_STARTUP_TRIAL_V1\nCHALLENGE=__CHALLENGE__\nKERNEL=3.4.113\nBOARD=dp-shvc\nREGION=USA\nHWID=__HWID__\nRUNTIME_SHA=__RUNTIME__\nWRAPPER_SHA=__WRAPPER__\nROOT=verified\nINIT=original-busybox\nMCP_PID=%s\nDAEMON_PID=%s\nMODULES=clvcon,mali,sunxi_keyboard,sunxi_knob\nDEVICES=ready\nUSB=verified-model-3\nPROFILE=existing\nTAINT=%s\nMOUNTS_BEGIN\n' "$mcp" "$daemon" "$taint"
        "$B" cat /proc/mounts
        printf 'MOUNTS_END\nEND\n'
        """#.replacingOccurrences(of:"__RUNTIME__",with:expected.runtimeSHA256).replacingOccurrences(of:"__WRAPPER__",with:expected.wrapperSHA256)
            .replacingOccurrences(of:"__HWID__",with:expected.hwid).replacingOccurrences(of:"__CHALLENGE__",with:challenge.uuidString)
            .replacingOccurrences(of:"__BCD__",with:String(format:"%04x",expected.deviceVersion))
            .replacingOccurrences(of:"__MENU_CHECKS__",with:menuChecks)
            .replacingOccurrences(of:"__ROOT_CHECKS__",with:LaunchCommand.shellQuote(checks)) + "\n"
        if expected.requiresCleanMenuLaunch {
            // Preserve historical command bytes and add evidence only for the new identity.
            let marker = #"taint=$("$B" cat /proc/sys/kernel/tainted)"#
            guard script.components(separatedBy:marker).count==2 else {throw SNESRuntimeBinding.failure()}
            script=script.replacingOccurrences(of:marker,with:Self.cleanMenuProcessChecks+marker)
            let reportMarker = #"\nMOUNTS_BEGIN\n' "$mcp" "$daemon" "$taint""#
            let replacement = #"\nMCP_SIGBLK=%s\nUI_SIGBLK=%s\nMOUNTS_BEGIN\n' "$mcp" "$daemon" "$taint" "$mcp_sigblk" "$ui_sigblk""#
            guard script.components(separatedBy:reportMarker).count==2 else {throw SNESRuntimeBinding.failure()}
            script=script.replacingOccurrences(of:reportMarker,with:replacement)
        }
        return script
    }

    static let cleanMenuProcessChecks = #"""
    # A folder child inherits Clover's blocked signals. The new launcher must clear them.
    menu_process_token() {
      test "$("$B" readlink -f "/proc/$1/exe")" = "/usr/bin/$2" || return 1
      "$B" awk -v pid="$1" '$1!=pid {exit 1} {sub(/^[0-9]+ \([^)]*\) /,"");if(NF<20 || $2!~/^[0-9]+$/ || $20!~/^[0-9]+$/)exit 1;print $2 ":" $20;n++}END{if(n!=1)exit 1}' "/proc/$1/stat"
    }
    menu_signal_mask() {
      "$B" awk '$1=="SigBlk:" {if(NF!=2 || length($2)!=16 || $2!~/^[0-9a-f]+$/)exit 1;print $2;n++}END{if(n!=1)exit 1}' "/proc/$1/status"
    }
    ui=$("$B" pidof ReedPlayer-Clover)
    case "$ui" in ''|*[!0-9]*) exit 1;; esac
    test "$ui" -gt 1 && test "$ui" -le 4194304 && test "$ui" != "$mcp" && test "$ui" != "$daemon" || exit 1
    mcp_token=$(menu_process_token "$mcp" clover-mcp); test "${mcp_token%%:*}" = 1
    ui_token=$(menu_process_token "$ui" ReedPlayer-Clover); test "${ui_token%%:*}" = "$mcp"
    mcp_sigblk=$(menu_signal_mask "$mcp")
    ui_sigblk=$(menu_signal_mask "$ui")
    test "$mcp_sigblk" = 0000000000000000 && test "$ui_sigblk" = 0000000000000000 || exit 1
    test "$("$B" pidof clover-mcp)" = "$mcp" && test "$("$B" pidof ReedPlayer-Clover)" = "$ui" || exit 1
    test "$(menu_process_token "$mcp" clover-mcp)" = "$mcp_token"
    test "$(menu_process_token "$ui" ReedPlayer-Clover)" = "$ui_token"
    test "$(menu_signal_mask "$mcp")" = "$mcp_sigblk" && test "$(menu_signal_mask "$ui")" = "$ui_sigblk" || exit 1
    """# + "\n"
}

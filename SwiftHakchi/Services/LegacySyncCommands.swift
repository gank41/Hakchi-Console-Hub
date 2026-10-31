import Foundation
import SwiftHakchiCore

struct LegacySyncInspection: Sendable {
    enum Phase: String, Sendable {
        case missing = "MISSING", ready = "READY", stopped = "STOPPED"
        case oldMoved = "OLD_MOVED", newActive = "NEW_ACTIVE", menuStarted = "MENU_STARTED"
        case accepted = "ACCEPTED", rolledBack = "ROLLED_BACK"
    }
    enum Outcome: Sendable {
        case beforeRename, firstRenameUncertain, newTreePresent, inconsistent
    }
    let phase: Phase
    let transaction: Bool
    let live: Bool
    let old: Bool
    let stage: Bool
    let failed: Bool
    let lock: Bool
    let archive: Bool
    let verified: Bool
    init(phase: Phase, transaction: Bool = true, live: Bool, old: Bool,
         stage: Bool, failed: Bool = false, lock: Bool,
         archive: Bool = false, verified: Bool = false) {
        self.phase = phase; self.transaction = transaction
        self.live = live; self.old = old; self.stage = stage
        self.failed = failed; self.lock = lock
        self.archive = archive; self.verified = verified
    }
    var outcome: Outcome {
        if live && !old { return .beforeRename }
        if !live && old && (stage || failed) { return .firstRenameUncertain }
        if live && old && !stage { return .newTreePresent }
        return .inconsistent
    }
}

/// Fixed commands for the first verified old-core NES. No caller-supplied paths or shell text.
enum LegacySyncCommands {
    static func oldPath(for operationID: UUID) -> String {
        "/var/lib/hakchi/games/nes.swift-old-" + operationID.uuidString
    }

    static func activate(operationID: UUID, treeSHA256: String,
                         archiveSHA256: String, archiveBytes: Int64) throws -> String {
        func validSHA(_ value: String) -> Bool {
            value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        }
        guard validSHA(treeSHA256), validSHA(archiveSHA256),
              archiveBytes > 0, archiveBytes <= 256 * 1024 * 1024 else {
            throw SyncPlanError.invalidInput("The reviewed legacy stage identity is invalid.")
        }
        let tx = LegacyStageTransfer.directory(for: operationID)
        let stage = LegacyStageVerification.stagePath(for: operationID)
        let old = oldPath(for: operationID)
        let marker = "VERIFIED:\(operationID.uuidString):\(treeSHA256)"
        let markerBytes = marker.utf8.count + 1
        return #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        PATH=/bin:/sbin:/usr/bin:/usr/sbin; export PATH
        umask 077
        tx='\#(tx)'; base='/var/lib/hakchi/games'; live="$base/nes"
        stage='\#(stage)'; old='\#(old)'; lock='/var/lib/hakchi/.swift-hakchi-sync-lock'
        ui='/etc/init.d/S81clover-mcp'; active='/var/games'; fds='/proc/self/fd'
        fail() { echo "Legacy sync refused: $*" >&2; exit 1; }
        canonical() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f "$1")" = "$1" ]; }
        idle() { ! pidof kachikachi canoe-shvc retroarch >/dev/null 2>&1; }
        same_device() { [ "$(stat -c %d "$1")" = "$(stat -c %d "$2")" ]; }
        menu_players_ok() {
          for p in $(pidof ReedPlayer-Clover 2>/dev/null || true); do
            tr '\000' '\n' < "/proc/$p/cmdline" | grep -F -x -e '--bootapp=/usr/share/clover-ui' >/dev/null || return 1
          done
        }
        stop_ui() {
          idle && menu_players_ok || return 1
          if pidof clover-mcp >/dev/null 2>&1; then killall -KILL clover-mcp || return 1; fi
          if pidof ReedPlayer-Clover >/dev/null 2>&1; then killall -KILL ReedPlayer-Clover || return 1; fi
          n=0; while pidof clover-mcp ReedPlayer-Clover >/dev/null 2>&1; do n=$((n+1)); [ "$n" -lt 6 ] || return 1; sleep 1; done
          idle
        }
        restart_ui() {
          idle || return 1
          if ! pidof clover-mcp >/dev/null 2>&1; then
            (
              trap '' HUP
              exec </dev/null >/dev/null 2>&1
              for f in "$fds"/*; do
                fd=${f##*/}
                case "$fd" in 0|1|2) ;; ''|*[!0-9]*) exit 1;; *) eval "exec $fd>&-";; esac
              done
              exec "$ui" start
            ) &
          fi
          n=0; while ! pidof clover-mcp >/dev/null 2>&1; do n=$((n+1)); [ "$n" -lt 6 ] || return 1; sleep 1; done
        }
        phase() {
          printf '%s\n' "$1" > "$tx/phase.partial"
          sync
          mv "$tx/phase.partial" "$tx/phase"
          sync
        }
        tree_digest() {
          (
            cd "$1"
            find . -mindepth 1 -print | sed 's#^\./##' | sort | while IFS= read -r rel; do
              case "$rel" in ''|/*|*'..'*|*'\'*|*[![:print:]]*) exit 61;; esac
              if [ -L "$rel" ]; then
                target=$(readlink "$rel") || exit 62
                case "$target" in /var/squashfs/usr/share/games/nes/kachikachi/*) ;; *) exit 63;; esac
                case "$target" in *'..'*) exit 64;; esac
                [ -e "$rel" ] || [ -d "$rel" ] || exit 65
                printf '%s\tsymbolicLink\t0\t\t%s\n' "$rel" "$target"
              elif [ -d "$rel" ]; then
                printf '%s\tdirectory\t0\t\t\n' "$rel"
              elif [ -f "$rel" ]; then
                count=$(stat -c %s "$rel") || exit 66
                digest=$(sha256sum "$rel") || exit 67
                printf '%s\tregular\t%s\t%s\t\n' "$rel" "$count" "${digest%% *}"
              else exit 68; fi
            done
          ) | sha256sum | awk '{print $1}'
        }
        canonical "$base" && canonical "$live" && canonical "$stage" && canonical "$tx" || fail 'noncanonical transaction paths'
        [ ! -e "$old" ] && [ ! -L "$old" ] || fail 'old-tree destination already exists'
        [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail 'another sync needs recovery'
        [ ! -e /var/lib/hakchi/.swift-hakchi-transactions/lock ] || fail 'another legacy change needs recovery'
        [ "$(readlink -f "$active")" = "$live/000" ] || fail 'return to root menu 000'
        [ -f "$ui" ] && [ ! -L "$ui" ] || fail 'missing menu launcher'
        [ "$(sha256sum "$ui" | awk '{print $1}')" = '01e35fddb8c92960fd996e4b8908b845717f1baa40caec04cb7318743e35311c' ] || fail 'unrecognized menu launcher'
        idle || fail 'an emulator is running'
        [ -f "$tx/verified.marker" ] && [ ! -L "$tx/verified.marker" ] || fail 'missing verified stage marker'
        [ "$(wc -c < "$tx/verified.marker" | tr -d ' ')" = '\#(markerBytes)' ] || fail 'stage marker length changed'
        [ "$(cat "$tx/verified.marker")" = '\#(marker)' ] || fail 'stage marker changed'
        [ -f "$tx/menu.tar" ] && [ ! -L "$tx/menu.tar" ] || fail 'missing staged archive'
        [ "$(wc -c < "$tx/menu.tar" | tr -d ' ')" = '\#(archiveBytes)' ] || fail 'staged archive length changed'
        sum=$(sha256sum "$tx/menu.tar"); [ "${sum%% *}" = '\#(archiveSHA256)' ] || fail 'staged archive changed'
        [ "$(tree_digest "$stage")" = '\#(treeSHA256)' ] || fail 'staged tree changed'
        same_device "$stage" "$live" && same_device "$live" "$base" || fail 'cross-device rename refused'
        original=$(stat -c '%d:%i' "$live") || fail 'original menu identity unavailable'
        printf '%s\n' "$original" > "$tx/old.identity.partial"
        sync
        mv "$tx/old.identity.partial" "$tx/old.identity"
        sync
        mkdir "$lock" || fail 'sync lock could not be acquired'
        printf '%s\n%s\n' '\#(operationID.uuidString)' '\#(treeSHA256)' > "$lock/owner"
        phase READY
        stopped=0; moved=0
        cleanup() {
          result=$?; trap - EXIT HUP INT TERM; set +e
          if [ "$result" -ne 0 ] && [ "$moved" = 0 ] && [ "$stopped" = 1 ] && canonical "$live"; then restart_ui || result=1; fi
          exit "$result"
        }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        stopped=1; stop_ui || fail 'menu did not stop safely'
        phase STOPPED
        canonical "$live" && canonical "$stage" && [ ! -e "$old" ] && [ ! -L "$old" ] || fail 'tree changed after menu stop'
        [ "$(tree_digest "$stage")" = '\#(treeSHA256)' ] || fail 'staged tree changed after menu stop'
        mv "$live" "$old"
        moved=1; phase OLD_MOVED
        mv "$stage" "$live"
        phase NEW_ACTIVE
        restart_ui || fail 'menu restart failed'
        stopped=0; phase MENU_STARTED
        printf 'ACTIVE:\#(operationID.uuidString):\#(treeSHA256)\n'
        """#
    }

    static func requireActiveReceipt(_ result: SSHResult, operationID: UUID,
                                     treeSHA256: String) throws {
        let expected = "ACTIVE:\(operationID.uuidString):\(treeSHA256)\n"
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData == Data(expected.utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
    }

    static func inspect(operationID: UUID, treeSHA256: String) throws -> String {
        guard treeSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("The reviewed legacy stage identity is invalid.")
        }
        let tx = LegacyStageTransfer.directory(for: operationID)
        let stage = LegacyStageVerification.stagePath(for: operationID)
        let old = oldPath(for: operationID)
        let failed = "/var/lib/hakchi/games/nes.swift-failed-" + operationID.uuidString
        return #"""
        set -eu
        tx='\#(tx)'; live='/var/lib/hakchi/games/nes'; old='\#(old)'
        stage='\#(stage)'; failed='\#(failed)'; lock='/var/lib/hakchi/.swift-hakchi-sync-lock'
        state() {
          if [ -L "$1" ]; then printf 'UNSAFE'
          elif [ -d "$1" ]; then printf '1'
          elif [ -e "$1" ]; then printf 'UNSAFE'
          else printf '0'; fi
        }
        txstate=$(state "$tx")
        [ "$txstate" = 0 ] || [ "$txstate" = 1 ] || exit 71
        oldstate=$(state "$old"); livest=$(state "$live"); stagest=$(state "$stage")
        failedst=$(state "$failed")
        [ "$oldstate" != UNSAFE ] && [ "$livest" != UNSAFE ] && [ "$stagest" != UNSAFE ] && [ "$failedst" != UNSAFE ] || exit 76
        phase=MISSING
        if [ "$txstate" = 1 ] && { [ -e "$tx/phase" ] || [ -L "$tx/phase" ]; }; then
          [ -f "$tx/phase" ] && [ ! -L "$tx/phase" ] || exit 72
          phase=$(cat "$tx/phase")
        fi
        case "$phase" in MISSING|READY|STOPPED|OLD_MOVED|NEW_ACTIVE|MENU_STARTED|ACCEPTED|ROLLED_BACK) ;; *) exit 73;; esac
        locked=0
        if [ -e "$lock" ] || [ -L "$lock" ]; then
          [ -d "$lock" ] && [ ! -L "$lock" ] && [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] || exit 74
          owner=$(cat "$lock/owner")
          [ "$owner" = "$(printf '%s\n%s' '\#(operationID.uuidString)' '\#(treeSHA256)')" ] || exit 75
          locked=1
        fi
        archive=0; verified=0
        if [ "$txstate" = 1 ]; then
          if [ -f "$tx/menu.tar" ] && [ ! -L "$tx/menu.tar" ]; then archive=1; fi
          if [ -f "$tx/verified.marker" ] && [ ! -L "$tx/verified.marker" ]; then
            if [ "$(cat "$tx/verified.marker")" = 'VERIFIED:\#(operationID.uuidString):\#(treeSHA256)' ]; then verified=1; fi
          fi
        fi
        printf 'SYNC_STATE\nID=\#(operationID.uuidString)\nPHASE=%s\nTX=%s\nLIVE=%s\nOLD=%s\nSTAGE=%s\nFAILED=%s\nLOCK=%s\nARCHIVE=%s\nVERIFIED=%s\nEND\n' "$phase" "$txstate" "$livest" "$oldstate" "$stagest" "$failedst" "$locked" "$archive" "$verified"
        """#
    }

    static func parseInspection(_ data: Data, operationID: UUID) throws -> LegacySyncInspection {
        guard data.count <= 1024, let text = String(data: data, encoding: .utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count == 12, lines[0] == "SYNC_STATE", lines[1] == "ID=\(operationID.uuidString)",
              lines[11] == "END", lines[2].hasPrefix("PHASE="),
              let phase = LegacySyncInspection.Phase(rawValue: String(lines[2].dropFirst(6))) else {
            throw LegacyInspectionError.invalidResponse
        }
        func bit(_ index: Int, key: String) throws -> Bool {
            switch lines[index] {
            case key + "=0": return false
            case key + "=1": return true
            default: throw LegacyInspectionError.invalidResponse
            }
        }
        return try LegacySyncInspection(phase: phase, transaction: bit(3, key: "TX"),
                                         live: bit(4, key: "LIVE"), old: bit(5, key: "OLD"),
                                         stage: bit(6, key: "STAGE"), failed: bit(7, key: "FAILED"),
                                         lock: bit(8, key: "LOCK"), archive: bit(9, key: "ARCHIVE"),
                                         verified: bit(10, key: "VERIFIED"))
    }

    /// Removes only this operation's inactive transfer files. The live menu must still be
    /// in place, no rename destination may exist, and no activation lock may be held.
    static func discard(operationID: UUID, treeSHA256: String) throws -> String {
        guard treeSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("The reviewed legacy stage identity is invalid.")
        }
        let tx = LegacyStageTransfer.directory(for: operationID)
        let stage = LegacyStageVerification.stagePath(for: operationID)
        let old = oldPath(for: operationID)
        return #"""
        set -eu
        tx='\#(tx)'; base='/var/lib/hakchi/games'; live="$base/nes"
        stage='\#(stage)'; old='\#(old)'; lock='/var/lib/hakchi/.swift-hakchi-sync-lock'
        canonical() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f "$1")" = "$1" ]; }
        canonical "$base" && canonical "$live" || exit 91
        [ ! -e "$old" ] && [ ! -L "$old" ] && [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 92
        [ "$(readlink -f /var/games)" = "$live/000" ] || exit 93
        ! pidof kachikachi canoe-shvc retroarch >/dev/null 2>&1 || exit 94
        if [ -e "$tx" ] || [ -L "$tx" ]; then
          canonical "$tx" || exit 95
          case "$(cat "$tx/phase" 2>/dev/null || printf MISSING)" in
            MISSING) ;; *) exit 96;;
          esac
        fi
        if [ -e "$stage" ] || [ -L "$stage" ]; then canonical "$stage" || exit 97; fi
        # Neither path is active. Keep the host's backup and original ROMs.
        if [ -d "$stage" ]; then rm -rf -- "$stage"; fi
        if [ -d "$tx" ]; then rm -rf -- "$tx"; fi
        sync
        printf 'DISCARDED:\#(operationID.uuidString):\#(treeSHA256)\n'
        """#
    }

    /// Human-approved rollback after a switch attempt. Preserve the replacement tree in a
    /// uniquely named failed sibling when it reached the live path.
    static func rollback(operationID: UUID, treeSHA256: String) throws -> String {
        guard treeSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("The reviewed legacy stage identity is invalid.")
        }
        let tx = LegacyStageTransfer.directory(for: operationID)
        let stage = LegacyStageVerification.stagePath(for: operationID)
        let old = oldPath(for: operationID)
        let failed = "/var/lib/hakchi/games/nes.swift-failed-" + operationID.uuidString
        return #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        PATH=/bin:/sbin:/usr/bin:/usr/sbin; export PATH
        umask 077
        tx='\#(tx)'; base='/var/lib/hakchi/games'; live="$base/nes"
        stage='\#(stage)'; old='\#(old)'; failed='\#(failed)'
        lock='/var/lib/hakchi/.swift-hakchi-sync-lock'; ui='/etc/init.d/S81clover-mcp'
        canonical() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f "$1")" = "$1" ]; }
        idle() { ! pidof kachikachi canoe-shvc retroarch >/dev/null 2>&1; }
        same_device() { [ "$(stat -c %d "$1")" = "$(stat -c %d "$2")" ]; }
        menu_players_ok() {
          for p in $(pidof ReedPlayer-Clover 2>/dev/null || true); do
            tr '\000' '\n' < "/proc/$p/cmdline" | grep -F -x -e '--bootapp=/usr/share/clover-ui' >/dev/null || return 1
          done
        }
        stop_ui() {
          idle && menu_players_ok || return 1
          if pidof clover-mcp >/dev/null 2>&1; then killall -KILL clover-mcp || return 1; fi
          if pidof ReedPlayer-Clover >/dev/null 2>&1; then killall -KILL ReedPlayer-Clover || return 1; fi
          n=0; while pidof clover-mcp ReedPlayer-Clover >/dev/null 2>&1; do n=$((n+1)); [ "$n" -lt 6 ] || return 1; sleep 1; done
          idle
        }
        restart_ui() {
          idle || return 1
          if ! pidof clover-mcp >/dev/null 2>&1; then
            (
              trap '' HUP
              exec </dev/null >/dev/null 2>&1
              for f in /proc/self/fd/*; do
                fd=${f##*/}
                case "$fd" in 0|1|2) ;; ''|*[!0-9]*) exit 1;; *) eval "exec $fd>&-";; esac
              done
              exec "$ui" start
            ) &
          fi
          n=0; while ! pidof clover-mcp >/dev/null 2>&1; do n=$((n+1)); [ "$n" -lt 6 ] || return 1; sleep 1; done
        }
        phase() {
          printf '%s\n' "$1" > "$tx/phase.partial"
          sync
          mv "$tx/phase.partial" "$tx/phase"
          sync
        }
        canonical "$base" && canonical "$tx" && canonical "$lock" || exit 101
        [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] || exit 102
        [ "$(cat "$lock/owner")" = "$(printf '%s\n%s' '\#(operationID.uuidString)' '\#(treeSHA256)')" ] || exit 103
        [ -f "$tx/old.identity" ] && [ ! -L "$tx/old.identity" ] || exit 119
        original=$(cat "$tx/old.identity")
        case "$original" in ''|*[!0-9:]*|:*|*:) exit 120;; esac
        [ -f "$tx/phase" ] && [ ! -L "$tx/phase" ] || exit 104
        case "$(cat "$tx/phase")" in READY|STOPPED|OLD_MOVED|NEW_ACTIVE|MENU_STARTED|ROLLED_BACK) ;; *) exit 105;; esac
        if [ -e "$failed" ] || [ -L "$failed" ]; then canonical "$failed" || exit 107; fi
        if [ -e "$old" ] || [ -L "$old" ]; then
          canonical "$old" && [ -d "$old/000" ] && [ ! -L "$old/000" ] || exit 106
          [ "$(stat -c '%d:%i' "$old")" = "$original" ] || exit 121
          same_device "$old" "$base" || exit 117
          if [ -e "$live" ] || [ -L "$live" ]; then
            canonical "$live" || exit 108
            same_device "$live" "$base" || exit 118
            [ ! -e "$stage" ] && [ ! -L "$stage" ] || exit 109
            [ ! -e "$failed" ] && [ ! -L "$failed" ] || exit 110
          else
            # The second rename may have failed, or the failed tree was preserved already.
            if [ ! -e "$stage" ] && [ ! -L "$stage" ]; then
              canonical "$failed" || exit 110
            else canonical "$stage" || exit 110; fi
          fi
        else
          canonical "$live" && [ -d "$live/000" ] && [ ! -L "$live/000" ] || exit 106
          [ "$(stat -c '%d:%i' "$live")" = "$original" ] || exit 121
          same_device "$live" "$base" || exit 118
          if [ -d "$failed" ]; then
            [ ! -e "$stage" ] && [ ! -L "$stage" ] || exit 109
          else
            canonical "$stage" || exit 109
            case "$(cat "$tx/phase")" in READY|STOPPED|ROLLED_BACK) ;; *) exit 109;; esac
          fi
        fi
        [ -f "$ui" ] && [ ! -L "$ui" ] || exit 111
        [ "$(sha256sum "$ui" | awk '{print $1}')" = '01e35fddb8c92960fd996e4b8908b845717f1baa40caec04cb7318743e35311c' ] || exit 112
        idle && menu_players_ok || exit 113
        stop_ui || exit 114
        if [ -d "$old" ]; then
          if [ -d "$live" ]; then mv "$live" "$failed"; sync; fi
          mv "$old" "$live"; sync
        fi
        phase ROLLED_BACK
        restart_ui || exit 115
        [ "$(readlink -f /var/games)" = "$live/000" ] || exit 116
        rm "$lock/owner"; rmdir "$lock"; sync
        printf 'ROLLED_BACK:\#(operationID.uuidString):\#(treeSHA256)\n'
        """#
    }

    static func requireRecoveryReceipt(_ result: SSHResult, kind: String,
                                       operationID: UUID, treeSHA256: String) throws {
        let expected = "\(kind):\(operationID.uuidString):\(treeSHA256)\n"
        guard result.succeeded, result.stderr.isEmpty,
              result.stdoutData == Data(expected.utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
    }

    static func accept(operationID: UUID, treeSHA256: String) throws -> String {
        guard treeSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("The reviewed legacy stage identity is invalid.")
        }
        let tx = LegacyStageTransfer.directory(for: operationID)
        let old = oldPath(for: operationID)
        let stage = LegacyStageVerification.stagePath(for: operationID)
        return #"""
        set -eu
        umask 077
        tx='\#(tx)'; live='/var/lib/hakchi/games/nes'; old='\#(old)'
        stage='\#(stage)'; lock='/var/lib/hakchi/.swift-hakchi-sync-lock'
        canonical() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f "$1")" = "$1" ]; }
        canonical "$tx" && canonical "$live" && canonical "$old" && canonical "$lock" || exit 81
        [ ! -e "$stage" ] && [ ! -L "$stage" ] || exit 82
        [ -f "$tx/phase" ] && [ ! -L "$tx/phase" ] || exit 83
        current=$(cat "$tx/phase")
        case "$current" in MENU_STARTED|ACCEPTED) ;; *) exit 83;; esac
        [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] || exit 84
        [ "$(cat "$lock/owner")" = "$(printf '%s\n%s' '\#(operationID.uuidString)' '\#(treeSHA256)')" ] || exit 85
        [ "$(readlink -f /var/games)" = "$live/000" ] || exit 86
        ! pidof kachikachi canoe-shvc retroarch >/dev/null 2>&1 || exit 87
        pidof clover-mcp >/dev/null 2>&1 || exit 88
        phase() {
          printf '%s\n' "$1" > "$tx/phase.partial"
          sync
          mv "$tx/phase.partial" "$tx/phase"
          sync
        }
        [ "$current" = ACCEPTED ] || phase ACCEPTED
        rm "$lock/owner"
        rmdir "$lock"
        sync
        printf 'ACCEPTED:\#(operationID.uuidString):\#(treeSHA256)\n'
        """#
    }

    static func requireAcceptedReceipt(_ result: SSHResult, operationID: UUID,
                                       treeSHA256: String) throws {
        let expected = "ACCEPTED:\(operationID.uuidString):\(treeSHA256)\n"
        guard result.succeeded else {
            throw LegacyChangeError.refused("NES library acceptance stopped at precondition \(result.exitCode). Inspect the console state before another action.")
        }
        guard result.stderr.isEmpty, result.stdoutData == Data(expected.utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
    }
}

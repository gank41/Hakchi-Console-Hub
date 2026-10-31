import Foundation
import SwiftHakchiCore

/// Paths are compiled in for the console. Alternate roots are used only by filesystem tests,
/// never read from journals or supplied by the user.
struct LegacyChangeLayout: Sendable {
    let base: String, transactions: String, active: String, uiInit: String, proc: String, path: String
    let expectedUIHash: String?
    var descriptorDirectory = "/proc/self/fd"
    static let console = Self(base: LegacyConsoleReport.gameRoot, transactions: "/var/lib/hakchi/.swift-hakchi-transactions", active: "/var/games", uiInit: "/etc/init.d/S81clover-mcp", proc: "/proc", path: "/bin:/sbin:/usr/bin:/usr/sbin", expectedUIHash: "01e35fddb8c92960fd996e4b8908b845717f1baa40caec04cb7318743e35311c")
}

enum LegacyChangeScripts {
    static func validCode(_ code: String) -> Bool { code.range(of: #"^CLV-H-[A-Z0-9]{5}$"#, options: .regularExpression) != nil }
    private static func common(code: String, layout: LegacyChangeLayout, requireIdle: Bool = true) throws -> String {
        guard validCode(code) else { throw LegacyChangeError.refused("Only an existing custom NES game can be hidden.") }
        func q(_ s: String) -> String { LaunchCommand.shellQuote(s) }
        return #"""
        set -eu
        set -o pipefail
        umask 077
        export LC_ALL=C
        PATH=\#(q(layout.path)); export PATH
        base=\#(q(layout.base)); txroot=\#(q(layout.transactions)); active=\#(q(layout.active))
        ui=\#(q(layout.uiInit)); proc=\#(q(layout.proc)); fds=\#(q(layout.descriptorDirectory)); code=\#(q(code))
        preflight=1
        fail() { echo "Change refused: $*" >&2; if [ "$preflight" = 1 ]; then printf 'REFUSED_BEFORE_MUTATION\n'; fi; exit 1; }
        canonical() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f "$1")" = "$1" ]; }
        tree_ok() {
          canonical "$1" || return 1
          [ -z "$(find "$1" ! -type f ! -type d -print)" ] || return 1
          [ -z "$(find "$1" -exec sh -c 'case "$1" in *[![:print:]]*) echo unsafe;; esac' sh '{}' ';')" ]
        }
        digest() {
          tree_ok "$1" || return 1
          (cd "$1"; printf 'DIRECTORIES\n'; find . -type d | sort; printf 'FILES\n'; find . -type f | sort | while IFS= read -r f; do sha256sum "$f" || exit 1; done) | sha256sum | awk '{print $1}'
        }
        idle() { ! pidof kachikachi canoe-shvc retroarch >/dev/null 2>&1; }
        same_device() { [ "$(stat -c %d "$1")" = "$(stat -c %d "$2")" ]; }
        start_time() { sed 's/^.*) //' "$proc/$1/stat" | awk '{print $20}'; }
        menu_players_ok() {
          for p in $(pidof ReedPlayer-Clover 2>/dev/null || true); do
            tr '\000' '\n' < "$proc/$p/cmdline" | grep -F -x -e '--bootapp=/usr/share/clover-ui' >/dev/null || return 1
          done
        }
        restart_ui() {
          idle || return 1
          if ! pidof clover-mcp >/dev/null 2>&1; then
            (
              trap '' HUP
              exec </dev/null >/dev/null 2>&1
              # Old ash and Clovershell leave extra pipe/USB descriptors open.
              # Redirecting only 0/1/2 does not detach the menu from command completion.
              for f in "$fds"/*; do
                fd=${f##*/}
                case "$fd" in 0|1|2) ;; ''|*[!0-9]*) exit 1;; *) eval "exec $fd>&-";; esac
              done
              exec "$ui" start
            ) &
          fi
          n=0; while ! pidof clover-mcp >/dev/null 2>&1; do n=$((n+1)); [ "$n" -lt 6 ] || return 1; sleep 1; done
        }
        stop_ui() {
          idle && menu_players_ok || return 1
          # TERM requests hardware shutdown on this legacy firmware. Match hakchi2 2.30:
          # terminate only the idle menu supervisor and its verified menu frontend.
          if pidof clover-mcp >/dev/null 2>&1; then killall -KILL clover-mcp || return 1; fi
          if pidof ReedPlayer-Clover >/dev/null 2>&1; then killall -KILL ReedPlayer-Clover || return 1; fi
          n=0; while pidof clover-mcp ReedPlayer-Clover >/dev/null 2>&1; do n=$((n+1)); [ "$n" -lt 6 ] || return 1; sleep 1; done
          idle
        }
        canonical "$base" || fail 'noncanonical game root'
        [ "$(readlink -f "$active")" = "$base/000" ] || fail 'return to root menu 000'
        [ -f "$ui" ] && [ ! -L "$ui" ] || fail 'missing menu launcher'
        \#(layout.expectedUIHash.map { "[ \"$(sha256sum \"$ui\" | awk '{print $1}')\" = " + q($0) + " ] || fail 'unrecognized menu launcher'" } ?? ":")
        \#(requireIdle ? "idle || fail 'an emulator is running; return to the NES menu'" : ":")
        """# + "\n"
    }

    static func probe(code: String, layout: LegacyChangeLayout = .console) throws -> String {
        try common(code: code, layout: layout, requireIdle: false) + #"""
        [ ! -e "$txroot/lock" ] || fail 'another transaction needs recovery'
        locations=$(find "$base" -mindepth 2 -maxdepth 2 -name "$code" -print)
        [ "$(printf '%s\n' "$locations" | wc -l | tr -d ' ')" = 1 ] || fail 'duplicate or missing game'
        live=$locations
        page=$(basename "$(dirname "$live")")
        case "$page" in [0-9][0-9][0-9]) ;; *) fail 'unsupported page';; esac
        [ "$live" = "$base/$page/$code" ] || fail 'unexpected location'
        hash=$(digest "$live") || fail 'unsupported game files'
        size=$(du -sk "$live" | awk '{print $1}')
        [ "$size" -gt 0 ] && [ "$size" -le 65536 ] || fail 'game too large'
        printf 'PAGE=%s\nSHA256=%s\nBYTES=%s\n' "$page" "$hash" "$((size*1024))"
        """# + "\n"
    }
    static func parseProbe(_ text: String, code: String) throws -> LegacyGameTarget {
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count == 3, lines[0].hasPrefix("PAGE="), lines[1].hasPrefix("SHA256="), lines[2].hasPrefix("BYTES="),
              let bytes = Int64(lines[2].dropFirst(6)) else { throw LegacyChangeError.refused("Incomplete change preview.") }
        return try LegacyGameTarget(code: code, page: String(lines[0].dropFirst(5)), sha256: String(lines[1].dropFirst(7)), bytes: bytes)
    }

    private static func transaction(id: UUID, target: LegacyGameTarget, layout: LegacyChangeLayout, undo: Bool) throws -> String {
        _ = try target.validated()
        let setup = try common(code: target.code, layout: layout)
        let marker = [id.uuidString, target.code, target.page, target.sha256].joined(separator: "\n")
        return setup + #"""
        id=\#(LaunchCommand.shellQuote(id.uuidString)); page=\#(LaunchCommand.shellQuote(target.page)); expected=\#(LaunchCommand.shellQuote(target.sha256))
        marker=\#(LaunchCommand.shellQuote(marker))
        live="$base/$page/$code"; tx="$txroot/$id"; lock="$txroot/lock"
        [ ! -L "$txroot" ] || fail 'linked transaction root'
        if [ -e "$txroot" ]; then canonical "$txroot" || fail 'noncanonical transaction root'; fi
        boot=$(cat "$proc/sys/kernel/random/boot_id")
        case "$boot" in *[!a-f0-9-]*|'') fail 'cannot verify kernel boot identity';; esac
        [ "${#boot}" = 36 ] || fail 'invalid kernel boot identity'
        preflight=0
        mkdir -p "$txroot"
        canonical "$txroot" || fail 'noncanonical transaction root'
        if ! mkdir "$lock" 2>/dev/null; then
          \#(undo ? "recover=1" : "fail 'transaction lock already exists'")
          canonical "$tx" && [ ! -L "$tx/marker" ] && [ "$(cat "$tx/marker")" = "$marker" ] || fail 'transaction marker mismatch'
          canonical "$lock" && [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] || fail 'unknown lock owner'
          oldboot=$(sed -n '4p' "$lock/owner")
          case "$oldboot" in *[!a-f0-9-]*|'') fail 'unknown owner boot identity';; esac
          [ "${#oldboot}" = 36 ] && [ "$oldboot" != "$boot" ] || fail 'power the NES off and on normally before recovering an abandoned transaction; a previous mutation child may still be running'
          mkdir "$lock/recover" 2>/dev/null || fail 'recovery already running'
          owner=$(cat "$lock/owner")
          oldid=$(printf '%s\n' "$owner" | sed -n '1p'); oldpid=$(printf '%s\n' "$owner" | sed -n '2p'); oldstart=$(printf '%s\n' "$owner" | sed -n '3p')
          if [ "$oldid" != "$id" ]; then rmdir "$lock/recover"; fail 'another transaction owns lock'; fi
          case "$oldpid:$oldstart" in *[!0-9:]*|:*|*:) rmdir "$lock/recover"; fail 'unknown process identity';; esac
          if [ -e "$proc/$oldpid/stat" ]; then
            current=$(start_time "$oldpid") || { rmdir "$lock/recover"; fail 'cannot verify previous process'; }
            if [ "$current" = "$oldstart" ] || [ -z "$current" ]; then rmdir "$lock/recover"; fail 'previous remote process still active'; fi
          fi
          [ "$(cat "$lock/owner")" = "$owner" ] || fail 'lock changed'
          rm "$lock/owner"; rmdir "$lock/recover"; rmdir "$lock"
          mkdir "$lock" || fail 'lock was reacquired'
        fi
        started=$(start_time "$$")
        case "$started" in ''|*[!0-9]*) fail 'cannot establish process identity';; esac
        owner=$(printf '%s\n%s\n%s\n%s' "$id" "$$" "$started" "$boot")
        printf '%s\n' "$owner" > "$lock/owner"
        stopped=0; moved=0
        cleanup() {
          result=$?; trap - EXIT HUP INT TERM; set +e
          if [ "$result" -ne 0 ] && [ "$moved" = 1 ] && [ ! -e "$live" ] && [ ! -L "$live" ]; then
            if [ "$(digest "$tx/hidden/$code")" = "$expected" ] && canonical "$base/$page" && same_device "$tx/hidden/$code" "$base/$page"; then
              mv "$tx/hidden/$code" "$live"; sync
            fi
          fi
          if [ "$stopped" = 1 ]; then restart_ui || result=1; fi
          # Lock release is the final remote filesystem mutation. Never reclaim a live owner.
          if [ "$(cat "$lock/owner" 2>/dev/null)" = "$owner" ]; then rm "$lock/owner" && rmdir "$lock" || result=1; else result=1; fi
          if [ "$result" -ne 0 ] && [ ! -e "$lock" ] && [ ! -e "$tx" ] && [ ! -L "$tx" ] && [ "$(digest "$live")" = "$expected" ]; then
            printf 'REFUSED_BEFORE_MUTATION\n'
          fi
          exit "$result"
        }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        \#(undo ? undoBody : hideBody)
        """# + "\n"
    }
    private static let hideBody = #"""
    [ ! -e "$tx" ] && [ ! -L "$tx" ] || fail 'transaction already exists'
    [ "$(digest "$live")" = "$expected" ] || fail 'game changed since preview'
    locations=$(find "$base" -mindepth 2 -maxdepth 2 -name "$code" -print)
    [ "$locations" = "$live" ] || fail 'duplicate game'
    available=$(df -Pk "$base" | tail -1 | awk '{print $4}')
    needed=$(du -sk "$live" | awk '{print $1}')
    [ "$available" -gt "$((needed*2+8192))" ] || fail 'insufficient preservation space'
    same_device "$live" "$txroot" || fail 'cross-filesystem move refused'
    mkdir "$tx"; printf '%s\n' "$marker" > "$tx/marker"
    mkdir "$tx/preserved" "$tx/hidden"
    cp -a "$live" "$tx/preserved/$code"
    [ "$(digest "$tx/preserved/$code")" = "$expected" ] || fail 'preservation copy did not verify'
    sync
    stopped=1; stop_ui || fail 'menu did not stop safely'
    [ "$(digest "$live")" = "$expected" ] || fail 'game changed during staging'
    same_device "$live" "$tx/hidden" || fail 'cross-filesystem move refused'
    moved=1; mv "$live" "$tx/hidden/$code"
    sync
    [ ! -e "$live" ] && [ "$(digest "$tx/hidden/$code")" = "$expected" ] || fail 'hidden game verification failed'
    restart_ui || fail 'menu restart failed'
    stopped=0; moved=0
    printf 'APPLIED\n'
    """#
    private static let undoBody = #"""
    canonical "$tx" && [ ! -L "$tx/marker" ] && [ "$(cat "$tx/marker")" = "$marker" ] || fail 'transaction marker mismatch'
    if [ -e "$live" ] || [ -L "$live" ]; then
      [ ! -e "$tx/hidden/$code" ] && [ ! -L "$tx/hidden/$code" ] && [ "$(digest "$live")" = "$expected" ] || fail 'ambiguous live and hidden state'
      restart_ui || fail 'menu restart failed'
    else
      [ "$(digest "$tx/hidden/$code")" = "$expected" ] || fail 'hidden game changed or missing'
      canonical "$base/$page" && same_device "$tx/hidden/$code" "$base/$page" || fail 'cross-filesystem restore refused'
      stopped=1; stop_ui || fail 'menu did not stop safely'
      [ ! -e "$live" ] && [ ! -L "$live" ] || fail 'live game appeared'
      canonical "$base/$page" && same_device "$tx/hidden/$code" "$base/$page" || fail 'filesystem changed during menu shutdown'
      mv "$tx/hidden/$code" "$live"; sync
      [ "$(digest "$live")" = "$expected" ] || fail 'restored game did not verify'
      restart_ui || fail 'menu restart failed'
      stopped=0
    fi
    printf 'RESTORED\n'
    """#
    static func hide(id: UUID, target: LegacyGameTarget, layout: LegacyChangeLayout = .console) throws -> String { try transaction(id: id, target: target, layout: layout, undo: false) }
    static func undo(id: UUID, target: LegacyGameTarget, layout: LegacyChangeLayout = .console) throws -> String { try transaction(id: id, target: target, layout: layout, undo: true) }
}

enum LegacyChangeRequest: Sendable {
    case inventoryHistorical(LegacyHistoricalCleanup.Target)
    case removeHistorical(LegacyHistoricalCleanup.Target, String, String)
    case probe(String), hide(UUID, LegacyGameTarget), undo(UUID, LegacyGameTarget)
    case verifyStage(UUID, String, Int64, String, Int64, [LegacyMenuStageManifest.Entry])
    case activateStage(UUID, String, String, Int64)
    case inspectStage(UUID, String)
    case inventoryStage(UUID)
    case inventoryLive(UUID)
    case inventoryOld(UUID)
    case acceptStage(UUID, String)
    case discardStage(UUID, String)
    case rollbackStage(UUID, String)
    case inspectReclaimArchive(UUID, String, String, Int64)
    case removeReclaimArchive(UUID, String, String, Int64)
    case removeReclaimOldMenu(UUID, String, String)
    case inspectReclaimOldMenu(UUID, String, String)
    var maximumOutputBytes: Int {
        switch self {
        case .inventoryStage, .inventoryLive, .inventoryOld, .inventoryHistorical:
            return LegacyStageVerification.maximumInventoryBytes
        default: return 65536
        }
    }
    var command: String { get throws {
        switch self {
        case .inventoryHistorical(let target): return try LegacyHistoricalCleanupCommands.inventory(target: target)
        case .removeHistorical(let target, let live, let old):
            return try LegacyHistoricalCleanupCommands.remove(target: target, currentTreeSHA256: live, targetTreeSHA256: old)
        case .probe(let code): return try LegacyChangeScripts.probe(code: code)
        case .hide(let id, let target): return try LegacyChangeScripts.hide(id: id, target: target)
        case .undo(let id, let target): return try LegacyChangeScripts.undo(id: id, target: target)
        case .verifyStage(let id, let archive, let bytes, let tree, let budget, let entries):
            return try LegacyStageVerification.command(operationID: id, archiveSHA256: archive,
                                                        archiveBytes: bytes, treeSHA256: tree,
                                                        stageBudgetBytes: budget, entries: entries)
        case .activateStage(let id, let tree, let archive, let bytes):
            return try LegacySyncCommands.activate(operationID: id, treeSHA256: tree,
                                                   archiveSHA256: archive, archiveBytes: bytes)
        case .inspectStage(let id, let tree):
            return try LegacySyncCommands.inspect(operationID: id, treeSHA256: tree)
        case .inventoryStage(let id):
            return LegacyStageVerification.inventoryCommand(operationID: id)
        case .inventoryLive(let id):
            return LegacyStageVerification.liveInventoryCommand(operationID: id)
        case .inventoryOld(let id):
            return LegacyStageVerification.oldInventoryCommand(operationID: id)
        case .acceptStage(let id, let tree):
            return try LegacySyncCommands.accept(operationID: id, treeSHA256: tree)
        case .discardStage(let id, let tree):
            return try LegacySyncCommands.discard(operationID: id, treeSHA256: tree)
        case .rollbackStage(let id, let tree):
            return try LegacySyncCommands.rollback(operationID: id, treeSHA256: tree)
        case .inspectReclaimArchive(let id, let tree, let archive, let bytes):
            return try LegacyArchiveReclaimCommands.inspect(operationID: id, treeSHA256: tree,
                                                            archiveSHA256: archive, archiveBytes: bytes)
        case .removeReclaimArchive(let id, let tree, let archive, let bytes):
            return try LegacyArchiveReclaimCommands.remove(operationID: id, treeSHA256: tree,
                                                           archiveSHA256: archive, archiveBytes: bytes)
        case .removeReclaimOldMenu(let id, let liveTree, let oldTree):
            return try LegacyOldMenuReclaimCommands.remove(operationID: id,
                liveTreeSHA256: liveTree, oldTreeSHA256: oldTree)
        case .inspectReclaimOldMenu(let id, let liveTree, let oldTree):
            return try LegacyOldMenuReclaimCommands.inspect(operationID: id,
                liveTreeSHA256: liveTree, oldTreeSHA256: oldTree)
        }
    } }
}

import Foundation

enum LegacyHistoricalCleanupCommands {
    static func inventory(target: LegacyHistoricalCleanup.Target) throws -> String {
        _ = try LegacyHistoricalCleanup.Target(path: target.path)
        return LegacyStageVerification.inventoryCommand(operationID: target.operationID)
            .replacingOccurrences(of: LegacyStageVerification.stagePath(for: target.operationID), with: target.path)
    }

    static func remove(target: LegacyHistoricalCleanup.Target, currentTreeSHA256: String,
                       targetTreeSHA256: String) throws -> String {
        _ = try LegacyHistoricalCleanup.Target(path: target.path)
        guard [currentTreeSHA256, targetTreeSHA256].allSatisfy({
            $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        }) else { throw LegacySyncJournalError.invalidRecord }
        return #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        PATH=/bin:/sbin:/usr/bin:/usr/sbin; export PATH
        target='\#(target.path)'; live='/var/lib/hakchi/games/nes'
        canonical() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f "$1")" = "$1" ]; }
        tree_digest() {
          (
            cd "$1"
            find . -mindepth 1 -print | sed 's#^\./##' | sort | while IFS= read -r rel; do
              case "$rel" in ''|/*|*'..'*|*'\'*|*[![:print:]]*) exit 61;; esac
              if [ -L "$rel" ]; then
                link=$(readlink "$rel") || exit 62
                printf '%s\tsymbolicLink\t0\t\t%s\n' "$rel" "$link"
              elif [ -d "$rel" ]; then
                printf '%s\tdirectory\t0\t\t\n' "$rel"
              elif [ -f "$rel" ]; then
                bytes=$(stat -c %s "$rel") || exit 63
                hash=$(sha256sum "$rel") || exit 64
                printf '%s\tregular\t%s\t%s\t\n' "$rel" "$bytes" "${hash%% *}"
              else exit 65; fi
            done
          ) | sha256sum | awk '{print $1}'
        }
        canonical "$live" && canonical "$target" || exit 71
        canonical /var/lib/hakchi && canonical /var/lib/hakchi/games || exit 72
        [ "$(stat -c '%d:%i' "$live")" != "$(stat -c '%d:%i' "$target")" ] || exit 73
        [ ! -e /var/lib/hakchi/.swift-hakchi-sync-lock ] && [ ! -L /var/lib/hakchi/.swift-hakchi-sync-lock ] || exit 74
        [ ! -e /var/lib/hakchi/.swift-hakchi-transactions/lock ] || exit 75
        [ "$(readlink -f /var/games)" = "$live/000" ] || exit 76
        ! pidof kachikachi canoe-shvc retroarch >/dev/null 2>&1 || exit 77
        [ "$(tree_digest "$live")" = '\#(currentTreeSHA256)' ] || exit 78
        [ "$(tree_digest "$target")" = '\#(targetTreeSHA256)' ] || exit 79
        device=$(stat -c %d "$live")
        find "$target" -type d -print | while IFS= read -r directory; do
          [ "$(stat -c %d "$directory")" = "$device" ] || exit 80
        done
        rm -r -- "$target"
        [ ! -e "$target" ] && [ ! -L "$target" ] || exit 81
        [ "$(tree_digest "$live")" = '\#(currentTreeSHA256)' ] || exit 82
        printf 'REMOVED_OLD_FILES:\#(target.path)\n'
        """#
    }
}

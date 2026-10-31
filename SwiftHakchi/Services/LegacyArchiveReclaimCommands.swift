import Foundation
import SwiftHakchiCore

/// Fixed old-core commands for one accepted sync's redundant transfer archive.
enum LegacyArchiveReclaimCommands {
    struct Inspection: Equatable, Sendable {
        let archivePresent: Bool
        let archiveBytes: Int64
    }

    static func inspect(operationID: UUID, treeSHA256: String,
                        archiveSHA256: String, archiveBytes: Int64) throws -> String {
        let paths = try validatedPaths(operationID: operationID, treeSHA256: treeSHA256,
                                       archiveSHA256: archiveSHA256, archiveBytes: archiveBytes)
        return commonPrefix(paths: paths, operationID: operationID,
                            treeSHA256: treeSHA256) + "\n" + #"""
        if [ -e "$tx/menu.tar" ] || [ -L "$tx/menu.tar" ]; then
          [ -f "$tx/menu.tar" ] && [ ! -L "$tx/menu.tar" ] || exit 131
          bytes=$(wc -c < "$tx/menu.tar" | tr -d ' ')
          digest=$(sha256sum "$tx/menu.tar"); digest=${digest%% *}
          present=1
        else
          bytes=0; digest=-; present=0
        fi
        printf 'RECLAIM_ARCHIVE_V1\nID=\#(operationID.uuidString)\nPHASE=ACCEPTED\nLIVE=1\nOLD=1\nLOCK=0\nARCHIVE=%s\nBYTES=%s\nSHA256=%s\nTREE_SHA256=\#(treeSHA256)\nEND\n' "$present" "$bytes" "$digest"
        """#
    }

    static func remove(operationID: UUID, treeSHA256: String,
                       archiveSHA256: String, archiveBytes: Int64) throws -> String {
        let paths = try validatedPaths(operationID: operationID, treeSHA256: treeSHA256,
                                       archiveSHA256: archiveSHA256, archiveBytes: archiveBytes)
        return commonPrefix(paths: paths, operationID: operationID,
                            treeSHA256: treeSHA256) + "\n" + #"""
        [ -f "$tx/menu.tar" ] && [ ! -L "$tx/menu.tar" ] || exit 131
        [ "$(wc -c < "$tx/menu.tar" | tr -d ' ')" = '\#(archiveBytes)' ] || exit 132
        digest=$(sha256sum "$tx/menu.tar"); [ "${digest%% *}" = '\#(archiveSHA256)' ] || exit 133
        # A global sync stalled twice on this old kernel. The caller separately
        # re-inspects the exact path and keeps the durable intent until it can.
        rm -- "$tx/menu.tar"
        [ ! -e "$tx/menu.tar" ] && [ ! -L "$tx/menu.tar" ] || exit 134
        printf 'RECLAIMED_ARCHIVE:\#(operationID.uuidString):\#(archiveSHA256)\n'
        """#
    }

    static func parseState(_ data: Data, operationID: UUID,
                           archiveSHA256: String, archiveBytes: Int64,
                           treeSHA256: String) throws -> Inspection {
        guard data.count <= 1024, let text = String(data: data, encoding: .ascii) else {
            throw LegacyInspectionError.invalidResponse
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count == 11,
              lines[0] == "RECLAIM_ARCHIVE_V1", lines[1] == "ID=\(operationID.uuidString)",
              lines[2] == "PHASE=ACCEPTED", lines[3] == "LIVE=1", lines[4] == "OLD=1",
              lines[5] == "LOCK=0", lines[9] == "TREE_SHA256=\(treeSHA256)",
              lines[10] == "END" else { throw LegacyInspectionError.invalidResponse }
        switch (lines[6], lines[7], lines[8]) {
        case ("ARCHIVE=1", "BYTES=\(archiveBytes)", "SHA256=\(archiveSHA256)"):
            return Inspection(archivePresent: true, archiveBytes: archiveBytes)
        case ("ARCHIVE=0", "BYTES=0", "SHA256=-"):
            return Inspection(archivePresent: false, archiveBytes: 0)
        default:
            throw LegacyInspectionError.invalidResponse
        }
    }

    static func parseInspection(_ data: Data, operationID: UUID,
                                archiveSHA256: String, archiveBytes: Int64,
                                treeSHA256: String) throws -> Inspection {
        let state = try parseState(data, operationID: operationID,
                                   archiveSHA256: archiveSHA256, archiveBytes: archiveBytes,
                                   treeSHA256: treeSHA256)
        guard state.archivePresent else { throw LegacyInspectionError.invalidResponse }
        return state
    }

    static func requireRemovedReceipt(_ result: SSHResult, operationID: UUID,
                                      archiveSHA256: String) throws {
        guard result.succeeded, result.stderr.isEmpty,
              result.stdoutData == Data("RECLAIMED_ARCHIVE:\(operationID.uuidString):\(archiveSHA256)\n".utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
    }

    private struct Paths { let tx: String; let old: String }

    /// Shared accepted-operation preflight for removing its former menu. This
    /// remains valid after the redundant transfer archive has been reclaimed.
    static func acceptedOldMenuPrefix(operationID: UUID, treeSHA256: String) throws -> String {
        guard treeSHA256.range(of: #"^[a-f0-9]{64}$"#,
                              options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("The accepted menu identity is invalid.")
        }
        return commonPrefix(paths: Paths(tx: LegacyStageTransfer.directory(for: operationID),
                                         old: LegacySyncCommands.oldPath(for: operationID)),
                            operationID: operationID, treeSHA256: treeSHA256)
    }

    private static func validatedPaths(operationID: UUID, treeSHA256: String,
                                       archiveSHA256: String, archiveBytes: Int64) throws -> Paths {
        let valid = { (value: String) in
            value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        }
        guard valid(treeSHA256), valid(archiveSHA256),
              archiveBytes > 0, archiveBytes <= 256 * 1024 * 1024 else {
            throw SyncPlanError.invalidInput("The accepted archive identity is invalid.")
        }
        return Paths(tx: LegacyStageTransfer.directory(for: operationID),
                     old: LegacySyncCommands.oldPath(for: operationID))
    }

    private static func commonPrefix(paths: Paths, operationID: UUID,
                                     treeSHA256: String) -> String {
        #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        PATH=/bin:/sbin:/usr/bin:/usr/sbin; export PATH
        tx='\#(paths.tx)'; old='\#(paths.old)'
        base='/var/lib/hakchi/games'; live="$base/nes"
        lock='/var/lib/hakchi/.swift-hakchi-sync-lock'
        canonical() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(readlink -f "$1")" = "$1" ]; }
        tree_digest() {
          (
            cd "$1"
            find . -mindepth 1 -print | sed 's#^\./##' | sort | while IFS= read -r rel; do
              case "$rel" in ''|/*|*'..'*|*'\'*|*[![:print:]]*) exit 61;; esac
              case "$rel" in
                [0-9][0-9][0-9]/title.fnt|[0-9][0-9][0-9]/copyright.fnt)
                  [ -f "$rel" ] && [ ! -L "$rel" ] || exit 69
                  count=$(stat -c %s "$rel") || exit 69
                  [ "$count" -gt 0 ] && [ "$count" -le 1048576 ] || exit 69
                  [ "${2:-ignore}" = include ] || continue;;
              esac
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
        canonical "$base" && canonical "$live" && canonical "$old" && canonical "$tx" || exit 121
        [ -f "$tx/phase" ] && [ ! -L "$tx/phase" ] && [ "$(cat "$tx/phase")" = ACCEPTED ] || exit 122
        [ -f "$tx/verified.marker" ] && [ ! -L "$tx/verified.marker" ] &&
          [ "$(cat "$tx/verified.marker")" = 'VERIFIED:\#(operationID.uuidString):\#(treeSHA256)' ] || exit 128
        [ -f "$tx/old.identity" ] && [ ! -L "$tx/old.identity" ] || exit 129
        original=$(cat "$tx/old.identity")
        case "$original" in ''|*[!0-9:]*|:*|*:|*:*:*) exit 129;; esac
        [ "$(stat -c '%d:%i' "$old")" = "$original" ] || exit 129
        [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 123
        [ ! -e /var/lib/hakchi/.swift-hakchi-transactions/lock ] || exit 124
        [ "$(readlink -f /var/games)" = "$live/000" ] || exit 125
        ! pidof kachikachi canoe-shvc retroarch >/dev/null 2>&1 || exit 126
        if [ "$(tree_digest "$live" include)" != '\#(treeSHA256)' ]; then
          [ "$(tree_digest "$live" ignore)" = '\#(treeSHA256)' ] || exit 127
        fi
        """#
    }
}

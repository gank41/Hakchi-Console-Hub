import Foundation
import SwiftHakchiCore

/// Extracts and verifies a transferred archive without touching the active `games/nes` tree.
enum LegacyStageVerification {
    static let maximumEntries = 2_048
    static let maximumInventoryBytes = 1024 * 1024

    static func stagePath(for operationID: UUID) -> String {
        "/var/lib/hakchi/games/nes.swift-stage-" + operationID.uuidString
    }

    /// Emits only names, types, sizes and hashes from this operation's inactive tree.
    static func inventoryCommand(operationID: UUID) -> String {
        let stage = stagePath(for: operationID)
        return #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        stage='\#(stage)'
        [ -d "$stage" ] && [ ! -L "$stage" ] && [ "$(readlink -f "$stage")" = "$stage" ] || exit 71
        cd "$stage"
        printf 'STAGE_INVENTORY:\#(operationID.uuidString)\n'
        find . -mindepth 1 -print | sed 's#^\./##' | sort | while IFS= read -r rel; do
          case "$rel" in ''|/*|*'..'*|*'\'*|*[![:print:]]*) exit 72;; esac
          if [ -L "$rel" ]; then
            target=$(readlink "$rel") || exit 73
            printf '%s\tsymbolicLink\t0\t\t%s\n' "$rel" "$target"
          elif [ -d "$rel" ]; then
            printf '%s\tdirectory\t0\t\t\n' "$rel"
          elif [ -f "$rel" ]; then
            count=$(stat -c %s "$rel") || exit 74
            digest=$(sha256sum "$rel") || exit 75
            printf '%s\tregular\t%s\t%s\t\n' "$rel" "$count" "${digest%% *}"
          else exit 76; fi
        done
        printf 'END_STAGE_INVENTORY\n'
        """#
    }

    /// Reads the active menu through the same entry format as an inactive stage.
    /// The caller compares every entry with the accepted menu's saved stage manifest.
    static func liveInventoryCommand(operationID: UUID) -> String {
        let live = LegacyConsoleReport.gameRoot
        return #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        live='\#(live)'
        [ -d "$live" ] && [ ! -L "$live" ] && [ "$(readlink -f "$live")" = "$live" ] || exit 71
        cd "$live"
        printf 'STAGE_INVENTORY:\#(operationID.uuidString)\n'
        find . -mindepth 1 -print | sed 's#^\./##' | sort | while IFS= read -r rel; do
          case "$rel" in ''|/*|*'..'*|*'\'*|*[![:print:]]*) exit 72;; esac
          if [ -L "$rel" ]; then
            target=$(readlink "$rel") || exit 73
            printf '%s\tsymbolicLink\t0\t\t%s\n' "$rel" "$target"
          elif [ -d "$rel" ]; then
            printf '%s\tdirectory\t0\t\t\n' "$rel"
          elif [ -f "$rel" ]; then
            count=$(stat -c %s "$rel") || exit 74
            digest=$(sha256sum "$rel") || exit 75
            printf '%s\tregular\t%s\t%s\t\n' "$rel" "$count" "${digest%% *}"
          else exit 76; fi
        done
        printf 'END_STAGE_INVENTORY\n'
        """#
    }

    /// Reads only the former menu owned by one accepted sync. The transaction's
    /// original inode marker prevents a same-named replacement being accepted.
    static func oldInventoryCommand(operationID: UUID) -> String {
        let old = LegacySyncCommands.oldPath(for: operationID)
        let tx = LegacyStageTransfer.directory(for: operationID)
        return #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        old='\#(old)'; tx='\#(tx)'; live='/var/lib/hakchi/games/nes'
        [ -d "$old" ] && [ ! -L "$old" ] && [ "$(readlink -f "$old")" = "$old" ] || exit 71
        [ -d "$tx" ] && [ ! -L "$tx" ] && [ "$(readlink -f "$tx")" = "$tx" ] || exit 72
        [ -d "$live" ] && [ ! -L "$live" ] && [ "$(readlink -f "$live")" = "$live" ] || exit 73
        [ -f "$tx/phase" ] && [ ! -L "$tx/phase" ] && [ "$(cat "$tx/phase")" = ACCEPTED ] || exit 74
        [ -f "$tx/old.identity" ] && [ ! -L "$tx/old.identity" ] || exit 75
        original=$(cat "$tx/old.identity")
        case "$original" in ''|*[!0-9:]*|:*|*:|*:*:*) exit 75;; esac
        [ "$(stat -c '%d:%i' "$old")" = "$original" ] || exit 76
        [ "$(stat -c '%d:%i' "$live")" != "$original" ] || exit 77
        [ ! -e /var/lib/hakchi/.swift-hakchi-sync-lock ] || exit 78
        cd "$old"
        printf 'STAGE_INVENTORY:\#(operationID.uuidString)\n'
        find . -mindepth 1 -print | sed 's#^\./##' | sort | while IFS= read -r rel; do
          case "$rel" in ''|/*|*'..'*|*'\'*|*[![:print:]]*) exit 79;; esac
          if [ -L "$rel" ]; then
            target=$(readlink "$rel") || exit 80
            printf '%s\tsymbolicLink\t0\t\t%s\n' "$rel" "$target"
          elif [ -d "$rel" ]; then
            printf '%s\tdirectory\t0\t\t\n' "$rel"
          elif [ -f "$rel" ]; then
            count=$(stat -c %s "$rel") || exit 81
            digest=$(sha256sum "$rel") || exit 82
            printf '%s\tregular\t%s\t%s\t\n' "$rel" "$count" "${digest%% *}"
          else exit 83; fi
        done
        printf 'END_STAGE_INVENTORY\n'
        """#
    }

    static func compareInventory(_ data: Data, operationID: UUID,
                                 expected: [LegacyMenuStageManifest.Entry],
                                 allowGeneratedPageFonts: Bool = false) throws -> [String] {
        guard data.count <= maximumInventoryBytes, let text = String(data: data, encoding: .utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "STAGE_INVENTORY:\(operationID.uuidString)",
              lines.suffix(2) == ["END_STAGE_INVENTORY", ""],
              expected.count <= maximumEntries,
              lines.count <= maximumEntries + 3 else { throw LegacyInspectionError.invalidResponse }
        let actualLines = lines.dropFirst().dropLast(2)
        var actual: [String: [String]] = [:]
        for line in actualLines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, !fields[0].isEmpty, !fields[0].contains(".."),
                  !fields[0].hasPrefix("/"), actual[fields[0]] == nil else {
                throw LegacyInspectionError.invalidResponse
            }
            actual[fields[0]] = fields
        }
        var differences: [String] = []
        for entry in expected {
            guard let fields = actual.removeValue(forKey: entry.relativePath) else {
                differences.append(entry.relativePath + ": missing on NES"); continue
            }
            if fields[1] != entry.kind.rawValue { differences.append(entry.relativePath + ": type differs") }
            else if fields[2] != String(entry.byteCount) { differences.append(entry.relativePath + ": size differs") }
            else if fields[3] != (entry.sha256 ?? "") { differences.append(entry.relativePath + ": content hash differs") }
            else if fields[4] != (entry.linkTarget ?? "") { differences.append(entry.relativePath + ": link target differs") }
        }
        for path in actual.keys.sorted() {
            guard let fields = actual[path] else { continue }
            if allowGeneratedPageFonts,
               path.range(of: #"^[0-9]{3}/(copyright|title)\.fnt$"#,
                          options: .regularExpression) != nil,
               fields[1] == "regular", fields[4].isEmpty,
               let bytes = Int64(fields[2]), bytes >= 0, bytes <= 1024 * 1024,
               fields[3].range(of: #"^[a-f0-9]{64}$"#,
                               options: .regularExpression) != nil {
                continue
            }
            differences.append(path + ": extra on NES")
        }
        return differences
    }

    static func command(operationID: UUID, archiveSHA256: String, archiveBytes: Int64,
                        treeSHA256: String, stageBudgetBytes: Int64,
                        entries: [LegacyMenuStageManifest.Entry]) throws -> String {
        func validSHA(_ value: String) -> Bool {
            value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        }
        guard validSHA(archiveSHA256), validSHA(treeSHA256),
              archiveBytes > 0, archiveBytes <= 256 * 1024 * 1024,
              stageBudgetBytes >= archiveBytes, stageBudgetBytes <= 256 * 1024 * 1024 else {
            throw SyncPlanError.invalidInput("The inactive stage verification inputs are invalid.")
        }
        let tx = LegacyStageTransfer.directory(for: operationID)
        let stage = stagePath(for: operationID)
        guard entries.count <= maximumEntries else { throw SyncPlanError.invalidInput("Too many staged menu entries.") }
        let links = try entries.filter { $0.kind == .symbolicLink }.map { entry -> String in
            let parts = entry.relativePath.split(separator: "/").map(String.init)
            guard parts.count == 3, parts[0].range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil,
                  parts[1].range(of: #"^CLV-[A-Z]-[A-Z0-9]{5}$"#, options: .regularExpression) != nil,
                  parts[2].range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
                  parts[2] != ".", parts[2] != "..",
                  entry.byteCount == 0, entry.sha256 == nil,
                  entry.linkTarget == LegacyConsoleReport.factoryRoot + "/" + parts[1] + "/" + parts[2] else {
                throw SyncPlanError.invalidInput("A staged factory link is invalid.")
            }
            let relative = entry.relativePath
            let target = entry.linkTarget!
            return "target='\(target)'; link=\"$stage/\(relative)\"; " +
                "[ -e \"$target\" ] || exit 77; " +
                "if [ -L \"$link\" ]; then [ \"$(readlink \"$link\")\" = \"$target\" ] || exit 78; " +
                "else [ ! -e \"$link\" ] || exit 78; ln -s \"$target\" \"$link\" || exit 79; fi"
        }.joined(separator: "\n")
        let script = #"""
        set -eu
        set -o pipefail
        export LC_ALL=C
        umask 077
        tx='\#(tx)'; archive='\#(tx)/menu.tar'
        base='/var/lib/hakchi/games'; stage='\#(stage)'
        [ -d "$tx" ] && [ ! -L "$tx" ] && [ "$(readlink -f "$tx")" = "$tx" ] || exit 51
        [ -d "$base" ] && [ ! -L "$base" ] && [ "$(readlink -f "$base")" = "$base" ] || exit 52
        [ -d "$base/nes" ] && [ ! -L "$base/nes" ] || exit 53
        [ -f "$archive" ] && [ ! -L "$archive" ] || exit 54
        [ ! -e "$stage" ] && [ ! -L "$stage" ] || exit 55
        [ ! -e "$tx/verified.marker" ] && [ ! -L "$tx/verified.marker" ] || exit 55
        size=$(wc -c < "$archive" | tr -d ' ')
        [ "$size" = '\#(archiveBytes)' ] || exit 56
        sum=$(sha256sum "$archive"); [ "${sum%% *}" = '\#(archiveSHA256)' ] || exit 57
        available=$(df -Pk "$base" | tail -1 | awk '{print $4}')
        case "$available" in ''|*[!0-9]*) exit 58;; esac
        [ "$((available*1024))" -ge '\#(stageBudgetBytes + 64 * 1024 * 1024)' ] || exit 59
        mkdir "$stage"
        tar -xf "$archive" -C "$stage" || exit 60
        \#(links)
        tree=$(
          cd "$stage"
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
          done | sha256sum
        )
        [ "${tree%% *}" = '\#(treeSHA256)' ] || exit 69
        sync
        printf 'VERIFIED:\#(operationID.uuidString):\#(treeSHA256)\n' > "$tx/verified.marker.partial"
        sync
        mv "$tx/verified.marker.partial" "$tx/verified.marker"
        sync
        printf 'VERIFIED:\#(operationID.uuidString):\#(treeSHA256)\n'
        """#
        guard script.utf8.count <= 65_536 else {
            throw SyncPlanError.invalidInput("The staged link verifier is too large for this NES.")
        }
        return script
    }

    static func requireReceipt(_ result: SSHResult, operationID: UUID, treeSHA256: String) throws {
        let expected = "VERIFIED:\(operationID.uuidString):\(treeSHA256)\n"
        guard result.succeeded else {
            throw LegacyChangeError.refused(
                "The NES stopped inactive-stage verification at step \(result.exitCode). The active game menu was not changed. Inspect the saved operation before retrying.")
        }
        // A zero exit and exact receipt follow the complete content/type/link
        // digest check. Nonfatal tar diagnostics do not invalidate that proof.
        guard result.stdoutData == Data(expected.utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
    }
}

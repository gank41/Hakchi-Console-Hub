import Foundation
import SwiftHakchiCore

/// A prepared request is not a dispatch permit. The guarded native path is not
/// exposed to users while target behavior and concurrent writers are unverified.
enum SNESReplacementSaveProfilePublication {
    struct Request: Sendable {
        let script: String, receipt: Data, challenge: UUID
        func stream() throws -> SNESOneGameStream { try .init(script: script) }
    }

    static func dispatch(request: Request, before: SNESLibraryInventory,
                         permit: SNESReplacementSaveJournal.PublicationPermit,
                         send: (Request) async throws -> Data) async throws {
        try Task.checkCancellation(); try permit.claimDispatch(request: request, before: before)
        try Task.checkCancellation()
        let result = try await send(request)
        try Task.checkCancellation(); try permit.require(request: request, before: before)
        guard result == request.receipt else { throw SNESLibraryInventory.failure() }
    }

    static func eligibleGroup(review: SNESReplacementSaveEnvelope, group: Int, before: SNESLibraryInventory) throws -> SNESNativeSaveLayout.Group {
        try review.validate(); try review.plan.requireCurrent(before)
        let groups = try review.plan.protectedGroups(), layout = try review.plan.nativeLayout()
        guard groups.indices.contains(group), before.capacity.namespaceReady, before.excludedMenuID == nil,
              !before.incompleteNamespace else { throw SNESLibraryInventory.failure() }
        let selected = groups[group], game = selected.gameCode, prefix = "clover/profiles/0/\(game)"
        // This first publication case covers a whole new game profile. A game
        // with other save sets needs a different, separately checked approach.
        guard layout.groups.filter({ $0.gameCode == game }).count == 1,
              !before.directories.contains(where: { $0.path == prefix || $0.path.hasPrefix(prefix + "/") }),
              !before.files.contains(where: { $0.path == prefix || $0.path.hasPrefix(prefix + "/") }) else {
            throw SNESLibraryInventory.failure()
        }
        return selected
    }

    static func prepare(review: SNESReplacementSaveEnvelope, group: Int, before: SNESLibraryInventory,
                        runtimeSHA256: String, switcherSHA256: String, challenge: UUID, stageID: UUID, stagedChallenge: UUID) throws -> Request {
        guard SNESDataSnapshotChunk.isDigest(switcherSHA256) else { throw SNESLibraryInventory.failure() }
        try review.validate(); try review.plan.requireCurrent(before)
        let groups = try review.plan.protectedGroups()
        guard groups.indices.contains(group) else { throw SNESLibraryInventory.failure() }
        let candidate = groups[group], game = candidate.gameCode, profile = "clover/profiles/0/\(game)"
        let existing = before.directories.contains(where: { $0.path == profile })
        let selected: SNESNativeSaveLayout.Group, slot: String?
        if existing {
            guard case let .suspendPoint(number) = candidate.kind, (1...4).contains(number),
                  before.capacity.namespaceReady, before.excludedMenuID == nil, !before.incompleteNamespace,
                  before.directories.contains(where: { $0.path == profile && $0.mode == 0o700 }) else { throw SNESLibraryInventory.failure() }
            let target = profile + "/suspendpoint\(number)"
            guard !before.directories.contains(where: { $0.path == target || $0.path.hasPrefix(target + "/") }),
                  !before.files.contains(where: { $0.path == target || $0.path.hasPrefix(target + "/") }),
                  candidate.paths.allSatisfy({ $0.hasPrefix(target + "/") }) else { throw SNESLibraryInventory.failure() }
            selected = candidate; slot = "suspendpoint\(number)"
        } else {
            selected = try eligibleGroup(review: review, group: group, before: before); slot = nil
        }
        let prefix = slot.map { profile + "/" + $0 } ?? profile
        let payload = try SNESReplacementSavePayload.prepare(review: review, group: group, challenge: stagedChallenge)
        let entries = Dictionary(uniqueKeysWithValues: review.plan.files.map { ($0.path, $0) })
        let paths = selected.paths.sorted()
        let block = before.capacity.blockSize
        guard paths.count == payload.fileCount, paths.count <= 128, (512...65536).contains(block), block.nonzeroBitCount == 1 else { throw SNESLibraryInventory.failure() }
        var directories = Set<String>(), files: [(String, SNESReplacementSaveReview.Entry)] = []
        for path in paths {
            guard path.hasPrefix(prefix + "/"), let entry = entries[path] else { throw SNESLibraryInventory.failure() }
            let relative = String(path.dropFirst(prefix.count + 1))
            guard !relative.isEmpty, relative.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }) else { throw SNESLibraryInventory.failure() }
            var parent = relative
            while let slash = parent.lastIndex(of: "/") { parent = String(parent[..<slash]); directories.insert(parent) }
            files.append((relative, entry))
        }
        let needed = Int64(payload.body.count) + (Int64(files.count + directories.count) + 4) * block + 2 * 1024 * 1024
        guard needed <= before.totalBytes else { throw SNESLibraryInventory.failure() }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmm.ss"
        var script = try SNESLibraryInventoryCommands.prefix(context: before.contextSHA256, hwid: before.hwid, runtime: runtimeSHA256)
        script += "current_selection() {\n" + SNESReplacementSaveStageCommands.selectionCheck(before.selection) + "}\ncurrent_selection\numask 077\n"
        script += #"""
        data_directory "${N%/*}";data_directory "$N";data_directory "$N/objects";data_directory "$N/menus"
        data_directory /var/lib/clover;data_directory /var/lib/clover/profiles;data_directory /var/lib/clover/profiles/0
        H=/mnt/swifthakchi/snes-save-profile-switch
        helper_check() { regular "$H";value=$("$B" sha256sum "$H");test "${value%% *}" = '__HELPER_HASH__'; }
        helper_check
        parent=/var/lib/clover/profiles/0;root="$N/save-staging";stage="$root/__ID__";ready="$stage/publication";target="$parent/__GAME__"
        data_directory "$root";data_directory "$stage"
        parent_token=$("$B" stat -c '%d %i %a' "$parent");root_token=$("$B" stat -c '%d %i %a' "$root");stage_token=$("$B" stat -c '%d %i %a' "$stage")
        roots() {
          data_directory /var/lib/clover;data_directory /var/lib/clover/profiles
          data_directory "${N%/*}";data_directory "$N"
          data_directory "$parent";data_directory "$root";data_directory "$stage"
          test "$("$B" stat -c '%d %i %a' "$parent")" = "$parent_token"
          test "$("$B" stat -c '%d %i %a' "$root")" = "$root_token"
          test "$("$B" stat -c '%d %i %a' "$stage")" = "$stage_token"
        }
        roots;current_selection;no_game
        test ! -e "$target" && test ! -L "$target"
        test ! -e "$ready" && test ! -L "$ready"
        space=$("$B" stat -f -c '%S %b %a' /var/lib);set -- $space;test "$#" -eq 3
        test "$1" = __BLOCK__;test "$3" -ge 0;test "$3" -le 1048576
        test "$(( $1 * $3 ))" -ge __NEEDED__
        regular "$stage/plan";test "$("$B" stat -c '%d' "$stage/plan")" = "$device"
        value=$("$B" sha256sum "$stage/plan");test "${value%% *}" = '__TABLE_HASH__'
        entries=$("$B" find "$stage" -mindepth 1 -maxdepth 1 -print | "$B" wc -l);test "$entries" -eq __STAGE_ENTRIES__
        """# + "\n"
        for (index, (_, entry)) in files.enumerated() {
            let staged = String(format: "%04d", index)
            script += "roots;current_selection;no_game\nregular \"$stage/\(staged)\"; test \"$(\"$B\" stat -c '%d %s' \"$stage/\(staged)\")\" = \"$device \(entry.byteCount)\"\n"
            script += "value=$(\"$B\" sha256sum \"$stage/\(staged)\");test \"${value%% *}\" = '\(entry.sourceSHA256)'\n"
        }
        script += "roots;current_selection;no_game\n\"$B\" mkdir -m 0700 \"$ready\";data_directory \"$ready\"\n"
        for directory in directories.sorted(by: { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }) {
            script += "roots;current_selection;no_game;\"$B\" mkdir -m 0700 \"$ready/\(directory)\";data_directory \"$ready/\(directory)\"\n"
        }
        for (index, (relative, entry)) in files.enumerated() {
            let staged = String(format: "%04d", index), mode = String(entry.sourceMode, radix: 8)
            let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.sourceModified)))
            script += "roots;current_selection;no_game;regular \"$stage/\(staged)\"\n"
            script += "set -C;\"$B\" dd bs=65536 conv=fsync < \"$stage/\(staged)\" > \"$ready/\(relative)\" 2>/dev/null;set +C\n"
            script += "\"$B\" chmod \(mode) \"$ready/\(relative)\";TZ=UTC0 \"$B\" touch -t \(date) \"$ready/\(relative)\"\n"
            script += "regular \"$ready/\(relative)\";test \"$(\"$B\" stat -c '%d %s %Y %a' \"$ready/\(relative)\")\" = \"$device \(entry.byteCount) \(entry.sourceModified) \(mode)\"\n"
            script += "value=$(\"$B\" sha256sum \"$ready/\(relative)\");test \"${value%% *}\" = '\(entry.sourceSHA256)'\n"
        }
        script += "verify_ready() {\ndata_directory \"$ready\"\n"
        for directory in directories.sorted() { script += "data_directory \"$ready/\(directory)\"\n" }
        for (relative, entry) in files {
            let mode = String(entry.sourceMode, radix: 8)
            script += "regular \"$ready/\(relative)\";test \"$(\"$B\" stat -c '%d %s %Y %a' \"$ready/\(relative)\")\" = \"$device \(entry.byteCount) \(entry.sourceModified) \(mode)\"\n"
            script += "value=$(\"$B\" sha256sum \"$ready/\(relative)\");test \"${value%% *}\" = '\(entry.sourceSHA256)'\n"
        }
        script += "entries=$(\"$B\" find \"$ready\" -mindepth 1 -print | \"$B\" wc -l);test \"$entries\" -eq __READY_ENTRIES__\n}\n"
        script += #"""
        roots;current_selection;no_game;verify_ready
        ready_token=$("$B" stat -c '%d %i %a' "$ready")
        "$B" sync
        roots;current_selection;no_game
        test ! -e "$target" && test ! -L "$target"
        "$B" mkdir -m 0700 "$target";data_directory "$target"
        reservation=$("$B" stat -c '%d %i %a' "$target")
        entries=$("$B" find "$target" -mindepth 1 -maxdepth 1 -print | "$B" wc -l);test "$entries" -eq 0
        roots;current_selection;no_game
        test "$("$B" stat -c '%d %i %a' "$target")" = "$reservation"
        test "$("$B" stat -c '%d %i %a' "$ready")" = "$ready_token"
        verify_ready;roots;current_selection;no_game
        test "$("$B" stat -c '%d %i %a' "$target")" = "$reservation"
        test "$("$B" stat -c '%d %i %a' "$ready")" = "$ready_token"
        set -- $ready_token;test "$#" -eq 3;source_dev=$1;source_ino=$2
        set -- $reservation;test "$#" -eq 3;dest_dev=$1;dest_ino=$2
        helper_check
        result=$("$H" '__ID__' '__GAME__' "$source_dev" "$source_ino" "$dest_dev" "$dest_ino")
        test "$result" = PROFILE_SWITCHED
        roots;current_selection;no_game;data_directory "$target"
        test "$("$B" stat -c '%d %i %a' "$target")" = "$ready_token"
        "$B" sync
        roots;current_selection;no_game
        """# + "\n"
        for directory in directories.sorted() { script += "data_directory \"$target/\(directory)\"\n" }
        for (relative, entry) in files {
            let mode = String(entry.sourceMode, radix: 8)
            script += "regular \"$target/\(relative)\";test \"$(\"$B\" stat -c '%d %s %Y %a' \"$target/\(relative)\")\" = \"$device \(entry.byteCount) \(entry.sourceModified) \(mode)\"\n"
            script += "value=$(\"$B\" sha256sum \"$target/\(relative)\");test \"${value%% *}\" = '\(entry.sourceSHA256)'\n"
        }
        script += "roots;current_selection;no_game\nentries=$(\"$B\" find \"$target\" -mindepth 1 -print | \"$B\" wc -l);test \"$entries\" -eq __READY_ENTRIES__\nroots;current_selection;no_game\nprintf '%s\\n' 'SWIFTHAKCHI_SNES_SAVE_PROFILE_PUBLISHED_V1' 'CHALLENGE \(challenge.uuidString)' 'CONTEXT \(before.contextSHA256)' 'HWID \(before.hwid)' 'REVIEW \(review.sha256)' 'STAGE \(stageID.uuidString)' 'TABLE \(payload.tableSHA256)' 'HELPER \(switcherSHA256)' 'GAME \(game)' 'END'\n"
        if let slot {
            // Preserve every previously observed file; never switch or replace
            // the enclosing profile. A later native observation is still required.
            let oldFiles = before.files.filter { $0.path.hasPrefix(profile + "/") }
            let oldDirectories = before.directories.filter { $0.path.hasPrefix(profile + "/") }
            func safe(_ path: String) -> Bool {
                path.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }
            }
            guard oldFiles.count + oldDirectories.count <= 512,
                  oldFiles.allSatisfy({ safe($0.path) }),
                  oldDirectories.allSatisfy({ safe($0.path) && $0.mode == 0o700 }) else { throw SNESLibraryInventory.failure() }
            var check = "verify_existing() {\ndata_directory \"$parent\";case \"$(\"$B\" stat -c '%d %i %a' \"$parent\")\" in *' 700') :;; *) return 1;; esac\n"
            for dir in oldDirectories {
                let name = String(dir.path.dropFirst(profile.count + 1))
                check += "data_directory \"$parent/\(name)\";case \"$(\"$B\" stat -c '%d %i %a' \"$parent/\(name)\")\" in *' 700') :;; *) return 1;; esac\n"
            }
            for file in oldFiles {
                let name = String(file.path.dropFirst(profile.count + 1)), mode = String(file.mode, radix: 8)
                check += "regular \"$parent/\(name)\";test \"$(\"$B\" stat -c '%d %s %Y %a' \"$parent/\(name)\")\" = \"$device \(file.byteCount) \(file.modified) \(mode)\"\n"
                check += "value=$(\"$B\" sha256sum \"$parent/\(name)\");test \"${value%% *}\" = '\(file.sha256)'\n"
            }
            check += "entries=$(\"$B\" find \"$parent\" -mindepth 1 -print | \"$B\" wc -l);test \"$entries\" -eq $((\(oldFiles.count + oldDirectories.count) + $1))\n}\n"
            func replaceOnce(_ needle: String, _ replacement: String) throws {
                let parts = script.components(separatedBy: needle)
                guard parts.count == 2 else { throw SNESLibraryInventory.failure() }
                script = parts[0] + replacement + parts[1]
            }
            try replaceOnce("parent=/var/lib/clover/profiles/0;root=", "parent=/var/lib/clover/profiles/0/__GAME__;root=")
            try replaceOnce("target=\"$parent/__GAME__\"", "target=\"$parent/\(slot)\"")
            let begin = "}\nroots;current_selection;no_game\ntest ! -e \"$target\" && test ! -L \"$target\""
            try replaceOnce(begin, "}\n" + check + "roots;current_selection;no_game;verify_existing 0\ntest ! -e \"$target\" && test ! -L \"$target\"")
            let beforeReserve = "\"$B\" sync\nroots;current_selection;no_game\ntest ! -e \"$target\""
            try replaceOnce(beforeReserve, "\"$B\" sync\nroots;current_selection;no_game;verify_existing 0\ntest ! -e \"$target\"")
            try replaceOnce("verify_ready;roots;current_selection;no_game\ntest \"$(\"$B\" stat -c '%d %i %a' \"$target\")\"",
                            "verify_ready;roots;current_selection;no_game;verify_existing 1\ntest \"$(\"$B\" stat -c '%d %i %a' \"$target\")\"")
            let oldSwitch = "result=$(\"$H\" '__ID__' '__GAME__' \"$source_dev\" \"$source_ino\" \"$dest_dev\" \"$dest_ino\")"
            let newSwitch = "set -- $parent_token;test \"$#\" -eq 3;profile_dev=$1;profile_ino=$2\nresult=$(\"$H\" '__ID__' '__GAME__' '\(slot)' \"$source_dev\" \"$source_ino\" \"$dest_dev\" \"$dest_ino\" \"$profile_dev\" \"$profile_ino\")"
            try replaceOnce(oldSwitch, newSwitch)
            let endCheck = "roots;current_selection;no_game\nentries=$(\"$B\" find \"$target\" -mindepth 1"
            try replaceOnce(endCheck, "roots;current_selection;no_game;verify_existing \(files.count + directories.count + 1)\nentries=$(\"$B\" find \"$target\" -mindepth 1")
        }
        for (key, value) in [("__ID__", stageID.uuidString), ("__GAME__", game), ("__TABLE_HASH__", payload.tableSHA256), ("__HELPER_HASH__", switcherSHA256), ("__STAGE_ENTRIES__", String(files.count + 1)), ("__READY_ENTRIES__", String(files.count + directories.count)), ("__BLOCK__", String(block)), ("__NEEDED__", String(needed))] {
            script = script.replacingOccurrences(of: key, with: value)
        }
        guard script.utf8.count <= 65536 else { throw SNESLibraryInventory.failure() }
        try review.validate(); try review.plan.requireCurrent(before)
        let receipt = Data("SWIFTHAKCHI_SNES_SAVE_PROFILE_PUBLISHED_V1\nCHALLENGE \(challenge.uuidString)\nCONTEXT \(before.contextSHA256)\nHWID \(before.hwid)\nREVIEW \(review.sha256)\nSTAGE \(stageID.uuidString)\nTABLE \(payload.tableSHA256)\nHELPER \(switcherSHA256)\nGAME \(game)\nEND\n".utf8)
        return .init(script: script, receipt: receipt, challenge: challenge)
    }
}

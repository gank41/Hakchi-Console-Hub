import Foundation

/// A read-only comparison. Its result carries no save-transfer authority.
struct SNESLibrarySaveComparison: Sendable {
    struct Differences: Sendable {
        var changed = 0, backupOnly = 0, consoleOnly = 0
    }
    struct GameDifference: Identifiable, Sendable {
        let gameCode: String
        let differences: Differences
        var id: String { gameCode }
        var changed: Int { differences.changed }
        var backupOnly: Int { differences.backupOnly }
        var consoleOnly: Int { differences.consoleOnly }
    }
    let matching: Int, changed: Int, backupOnly: Int, consoleOnly: Int
    let gameDifferences: [GameDifference]
    let otherDifferences: Differences

    static func compare(backup: SNESLibraryBackup, observed: SNESLibraryInventory) throws -> Self {
        try backup.validate()
        let verified = try SNESLibraryBackup.open(directory: backup.directory)
        guard verified.manifestSHA256 == backup.manifestSHA256,
              verified.inventory.hwid == observed.hwid,
              verified.inventory.catalogSHA256 == observed.catalogSHA256,
              observed.excludedMenuID == nil, !observed.incompleteNamespace else {
            throw RecoveryProbeError.refused("This backup does not match the connected SNES. Nothing was copied.")
        }
        let prefix = "clover/profiles/0/"
        let older = Dictionary(uniqueKeysWithValues: verified.inventory.files.filter { $0.path.hasPrefix(prefix) }.map { ($0.path, $0) })
        let current = Dictionary(uniqueKeysWithValues: observed.files.filter { $0.path.hasPrefix(prefix) }.map { ($0.path, $0) })
        var matching = 0, changed = 0, backupOnly = 0
        var games: [String: Differences] = [:], other = Differences()
        enum Category { case changed, backupOnly, consoleOnly }
        func record(_ path: String, _ category: Category) {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let code = parts.count >= 5 ? String(parts[3]) : ""
            let isGame = code.range(of: #"^CLV-[PUS]-[A-Z0-9]{5}$"#, options: .regularExpression) != nil
            var difference = isGame ? games[code, default: Differences()] : other
            switch category {
            case .changed: difference.changed += 1
            case .backupOnly: difference.backupOnly += 1
            case .consoleOnly: difference.consoleOnly += 1
            }
            if isGame { games[code] = difference } else { other = difference }
        }
        for (path, file) in older {
            guard let currentFile = current[path] else { backupOnly += 1; record(path, .backupOnly); continue }
            if file.byteCount == currentFile.byteCount && file.sha256 == currentFile.sha256 { matching += 1 }
            else { changed += 1; record(path, .changed) }
        }
        let onlyCurrent = current.keys.filter { older[$0] == nil }
        for path in onlyCurrent { record(path, .consoleOnly) }
        try verified.validate(); try backup.validate()
        return .init(matching: matching, changed: changed, backupOnly: backupOnly, consoleOnly: onlyCurrent.count,
                     gameDifferences: games.keys.sorted().compactMap { code in
                         games[code].map { GameDifference(gameCode: code, differences: $0) }
                     }, otherDifferences: other)
    }
}

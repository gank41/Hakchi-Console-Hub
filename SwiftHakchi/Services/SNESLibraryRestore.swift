import Foundation
import SwiftHakchiCore

enum SNESLibraryRestoreScope: Sendable { case sameConsole, replacementConsole }

/// A comparison of two verified Mac backups, not permission to change a console.
struct SNESReplacementSaveReview: Sendable {
    enum Disposition: Sendable { case new, unchanged, conflict }
    enum GameMatch: Sendable { case includedGame, matchingAddedGame, addedGameMissing, addedGameDifferent }
    struct Entry: Sendable {
        let path: String, sourceSHA256: String, destinationSHA256: String?, blockerPath: String?
        let byteCount: Int, sourceMode: Int, sourceModified: Int64, disposition: Disposition
        let gameMatch: GameMatch
    }
    struct GameOption: Identifiable, Sendable {
        let code: String, title: String, eligible: Bool, reason: String?
        var id: String { code }
    }
    let entries: [Entry]
    fileprivate let source: SNESLibraryBackup, destination: SNESLibraryBackup

    func validate() throws { try source.validate(); try destination.validate() }

    static func sameSavedFile(_ lhs: SNESLibraryInventory.File, _ rhs: SNESLibraryInventory.File) -> Bool {
        lhs.path == rhs.path && lhs.byteCount == rhs.byteCount && lhs.sha256 == rhs.sha256 && lhs.mode == rhs.mode && lhs.modified == rhs.modified
    }

    /// A matching inventory is only a point-in-time check, not a write permit.
    func requireCurrent(_ inventory: SNESLibraryInventory) throws {
        try validate()
        let saved = destination.inventory
        guard inventory.hwid == saved.hwid, inventory.catalogSHA256 == saved.catalogSHA256,
              inventory.selection == saved.selection, inventory.snapshotSHA256 == saved.snapshotSHA256,
              inventory.stateSHA256 == saved.stateSHA256, inventory.excludedMenuID == nil, !inventory.incompleteNamespace else {
            throw RecoveryProbeError.refused("The connected SNES changed since its backup. Make a new backup and review it again. Nothing was copied.")
        }
        try validate()
    }
}

/// A provisional offline, non-overwriting selection. It does not authorize a
/// console write; a transfer must still validate allowed file types, related
/// suspend-point files, the live destination and interruption recovery.
struct SNESReplacementSavePlan: Sendable {
    let files: [SNESReplacementSaveReview.Entry]
    let gameCodes: Set<String>
    fileprivate let comparison: SNESReplacementSaveReview
    private let replacement: SNESLibraryReplacement
    private let selected: [SNESReplacementSaveReview.Entry]

    static func prepare(replacement: SNESLibraryReplacement, destination: SNESLibraryBackup,
                        gameCodes: Set<String>) throws -> Self {
        guard !gameCodes.isEmpty else { throw SNESLibraryInventory.failure() }
        let comparison = try replacement.compareSaves(to: destination)
        var found = Set<String>(), files: [SNESReplacementSaveReview.Entry] = [], selected: [SNESReplacementSaveReview.Entry] = []
        for entry in comparison.entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 5 else { throw SNESLibraryInventory.failure() }
            let code = String(parts[3])
            guard gameCodes.contains(code) else { continue }
            found.insert(code)
            guard entry.gameMatch == .includedGame || entry.gameMatch == .matchingAddedGame,
                  entry.disposition != .conflict else {
                throw RecoveryProbeError.refused("A selected game's saved files conflict or the matching game is not on this SNES. Nothing was copied.")
            }
            selected.append(entry)
            if entry.disposition == .new { files.append(entry) }
        }
        guard found == gameCodes else { throw SNESLibraryInventory.failure() }
        try comparison.validate()
        return .init(files: files, gameCodes: gameCodes, comparison: comparison, replacement: replacement, selected: selected)
    }

    static func prepare(replacement: SNESLibraryReplacement, comparison: SNESReplacementSaveReview,
                        gameCodes: Set<String>) throws -> Self {
        guard comparison.source.directory == replacement.backup.directory,
              comparison.source.manifestSHA256 == replacement.backup.manifestSHA256 else { throw SNESLibraryInventory.failure() }
        try comparison.validate()
        return try prepare(replacement: replacement, destination: comparison.destination, gameCodes: gameCodes)
    }

    func validate() throws { try comparison.validate() }

    var destinationInventory: SNESLibraryInventory { comparison.destination.inventory }

    func requireCurrent(_ inventory: SNESLibraryInventory) throws { try comparison.requireCurrent(inventory) }

    func requireReplacement(_ value: SNESLibraryReplacement) throws {
        try validate(); try value.backup.validate()
        guard value.backup.directory == replacement.backup.directory,
              value.backup.manifestSHA256 == replacement.backup.manifestSHA256,
              value.destinationHWID == replacement.destinationHWID,
              try SNESLibraryCatalogIdentity.digest(value.originals) == SNESLibraryCatalogIdentity.digest(replacement.originals) else {
            throw SNESLibraryInventory.failure()
        }
        try validate(); try value.backup.validate()
    }

    func nativeLayout() throws -> SNESNativeSaveLayout {
        try validate()
        let layout = try SNESNativeSaveLayout(paths: selected.map(\.path))
        guard layout.gameCodes == gameCodes else { throw SNESLibraryInventory.failure() }
        try validate(); return layout
    }

    /// Avoid splitting a related save set between existing and new files.
    func protectedGroups() throws -> [SNESNativeSaveLayout.Group] {
        let layout = try nativeLayout()
        let entries = Dictionary(uniqueKeysWithValues: selected.map { ($0.path, $0) })
        var groups: [SNESNativeSaveLayout.Group] = []
        for group in layout.groups {
            let dispositions = try group.paths.map { path -> SNESReplacementSaveReview.Disposition in
                guard let entry = entries[path] else { throw SNESLibraryInventory.failure() }
                return entry.disposition
            }
            if dispositions.allSatisfy({ $0 == .new }) { groups.append(group) }
            else if !dispositions.allSatisfy({ $0 == .unchanged }) {
                throw RecoveryProbeError.refused("A saved-game set is partly present on this SNES. Review it before copying; nothing was changed.")
            }
        }
        try validate(); return groups
    }

    func read(path: String) throws -> Data {
        try validate()
        guard let entry = files.first(where: { $0.path == path }) else { throw SNESLibraryInventory.failure() }
        let data = try replacement.readSave(path: path)
        guard data.count == entry.byteCount, BackupManifest.digest(data) == entry.sourceSHA256 else { throw SNESLibraryInventory.failure() }
        try validate()
        return data
    }
}

/// A reopenable Mac-only review. No decoded record authorizes console access.
struct SNESReplacementSaveEnvelope: Sendable {
    struct Identity: Sendable { let source: SNESLibrarySnapshotReference, destination: SNESLibrarySnapshotReference }
    private struct File: Codable { let path: String, bytes: Int, sha256: String, mode: Int, modified: Int64 }
    private struct Record: Codable {
        let version: Int, scope: String, source: SNESLibrarySnapshotReference, destination: SNESLibrarySnapshotReference
        let gameCodes: [String], files: [File]
    }
    let data: Data, sha256: String, plan: SNESReplacementSavePlan

    /// Ensure a review's serialized identity still describes this exact plan.
    func validate() throws {
        let rebuilt = try Self.prepare(plan: plan)
        guard rebuilt.data == data, rebuilt.sha256 == sha256 else { throw SNESLibraryInventory.failure() }
    }

    static func identity(data: Data, expectedSHA256: String) throws -> Identity {
        guard data.count <= 4 * 1024 * 1024, SNESDataSnapshotChunk.isDigest(expectedSHA256),
              BackupManifest.digest(data) == expectedSHA256 else { throw SNESLibraryInventory.failure() }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard (record.version == 2 && record.scope == "snes-replacement-saves-offline-review") ||
              (record.version == 3 && record.scope == "snes-same-console-saves-offline-review") else { throw SNESLibraryInventory.failure() }
        guard
              !record.gameCodes.isEmpty, record.gameCodes == Array(Set(record.gameCodes)).sorted(),
              !record.files.isEmpty, record.files.count <= 4096,
              record.files.allSatisfy({ SNESLibraryInventory.safePath($0.path) && $0.bytes >= 0 && $0.bytes <= 16 * 1024 * 1024 && SNESDataSnapshotChunk.isDigest($0.sha256) && (0...511).contains($0.mode) }),
              Set(record.files.map(\.path)).count == record.files.count, try encode(record) == data else { throw SNESLibraryInventory.failure() }
        try record.source.validateMetadata(); try record.destination.validateMetadata()
        return .init(source: record.source, destination: record.destination)
    }

    static func prepare(plan: SNESReplacementSavePlan) throws -> Self {
        try plan.validate(); _ = try plan.protectedGroups()
        guard !plan.files.isEmpty, plan.files.count <= 4096 else { throw SNESLibraryInventory.failure() }
        let sameConsole = plan.comparison.source.inventory.hwid == plan.comparison.destination.inventory.hwid
        let record = Record(version: sameConsole ? 3 : 2, scope: sameConsole ? "snes-same-console-saves-offline-review" : "snes-replacement-saves-offline-review",
            source: try SNESLibrarySnapshotReference(plan.comparison.source), destination: try SNESLibrarySnapshotReference(plan.comparison.destination),
            gameCodes: plan.gameCodes.sorted(), files: plan.files.map { .init(path: $0.path, bytes: $0.byteCount, sha256: $0.sourceSHA256, mode: $0.sourceMode, modified: $0.sourceModified) })
        let data = try encode(record)
        guard data.count <= 4 * 1024 * 1024 else { throw SNESLibraryInventory.failure() }
        try plan.validate(); return .init(data: data, sha256: BackupManifest.digest(data), plan: plan)
    }

    static func load(data: Data, expectedSHA256: String, originals: SNESOriginalGamesFrame) throws -> Self {
        _ = try identity(data: data, expectedSHA256: expectedSHA256)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard ((record.version == 2 && record.scope == "snes-replacement-saves-offline-review") ||
               (record.version == 3 && record.scope == "snes-same-console-saves-offline-review")),
              !record.gameCodes.isEmpty, record.gameCodes == Array(Set(record.gameCodes)).sorted(),
              try encode(record) == data else { throw SNESLibraryInventory.failure() }
        let source = try record.source.reopen(), destination = try record.destination.reopen()
        let replacement = try record.version == 2
            ? SNESLibraryRestore.prepareReplacement(backup: source, originals: originals, destinationHWID: destination.inventory.hwid)
            : SNESLibraryRestore.prepareSameConsoleSavedData(backup: source, originals: originals, destinationHWID: destination.inventory.hwid)
        let plan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: destination, gameCodes: Set(record.gameCodes))
        let rebuilt = try prepare(plan: plan)
        guard rebuilt.data == data, rebuilt.sha256 == expectedSHA256 else { throw SNESLibraryInventory.failure() }
        return rebuilt
    }

    private static func encode(_ value: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// A Mac-only review of saved content for this SNES or a replacement. It grants no write authority.
struct SNESLibraryReplacement: Sendable {
    let sourceHWID: String, destinationHWID: String
    let menu: SNESLibraryMenu?
    let saveFiles: [SNESLibraryInventory.File]
    let unmatchedProfileFiles: [String]
    fileprivate let backup: SNESLibraryBackup
    fileprivate let originals: SNESOriginalGamesFrame

    func saveOptions(comparison: SNESReplacementSaveReview) throws -> [SNESReplacementSaveReview.GameOption] {
        guard comparison.source.directory == backup.directory, comparison.source.manifestSHA256 == backup.manifestSHA256,
              comparison.destination.inventory.hwid == destinationHWID else { throw SNESLibraryInventory.failure() }
        try comparison.validate()
        var grouped: [String: [SNESReplacementSaveReview.Entry]] = [:]
        for entry in comparison.entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 5 else { throw SNESLibraryInventory.failure() }
            grouped[String(parts[3]), default: []].append(entry)
        }
        let options = grouped.keys.sorted().map { code -> SNESReplacementSaveReview.GameOption in
            let entries = grouped[code] ?? [], title = gameTitle(code)
            let reason: String?
            if entries.contains(where: { $0.gameMatch == .addedGameMissing }) { reason = "Add this game to the SNES first." }
            else if entries.contains(where: { $0.gameMatch == .addedGameDifferent }) { reason = "The game on this SNES is different." }
            else if entries.contains(where: { $0.disposition == .conflict }) { reason = "Existing saved data needs a separate review." }
            else if let layout = try? SNESNativeSaveLayout(paths: entries.map(\.path)) {
                let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.disposition) })
                let split = layout.groups.contains { group in
                    let states = group.paths.compactMap { values[$0] }
                    return states.count != group.paths.count || (!states.allSatisfy { $0 == .new } && !states.allSatisfy { $0 == .unchanged })
                }
                if split { reason = "Part of this save is already present and needs a separate review." }
                else if !entries.contains(where: { $0.disposition == .new }) { reason = "This saved data already matches." }
                else { reason = nil }
            } else { reason = "This save format needs a separate review." }
            return .init(code: code, title: title, eligible: reason == nil, reason: reason)
        }
        try comparison.validate(); return options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func gameTitle(_ code: String) -> String {
        if let original = originals.entries.first(where: { $0.code == code }),
           let desktop = original.files.first(where: { $0.name == code + ".desktop" }),
           let title = try? SNESOneGameMenu.fields(desktop.data)["name"], !title.isEmpty { return title }
        if let menu, let placement = menu.description.placements.first(where: { $0.code == code && $0.kind == "import" }) {
            let path = String(format: "pages/%03d/%@/%@.desktop", placement.page, code, code)
            if let desktop = menu.files[path], let title = try? SNESOneGameMenu.fields(desktop)["name"], !title.isEmpty { return title }
        }
        return code
    }

    func readSave(path: String) throws -> Data {
        guard saveFiles.contains(where: { $0.path == path }) else { throw SNESLibraryInventory.failure() }
        return try backup.read(path: path)
    }

    /// Classify changes against a full backup of the replacement, including
    /// file-versus-directory collisions. This does not select or copy files.
    func compareSaves(to destination: SNESLibraryBackup) throws -> SNESReplacementSaveReview {
        try backup.validate()
        let checked = try SNESLibraryBackup.open(directory: destination.directory)
        guard checked.manifestSHA256 == destination.manifestSHA256,
              checked.inventory.hwid == destinationHWID,
              checked.inventory.catalogSHA256 == backup.inventory.catalogSHA256,
              checked.inventory.excludedMenuID == nil, !checked.inventory.incompleteNamespace else {
            throw RecoveryProbeError.refused("A backup of the connected SNES could not be verified. Nothing was copied.")
        }
        let files = Dictionary(uniqueKeysWithValues: checked.inventory.files.map { ($0.path, $0) })
        let directories = Set(checked.inventory.directories.map(\.path))
        let targetMenu = try SNESLibraryRestore.prepare(backup: checked, originals: originals, expectedHWID: destinationHWID).menu
        let sourceGames = try Self.importedGames(menu), targetGames = try Self.importedGames(targetMenu)
        let includedCodes = Set(originals.entries.map(\.code))
        let entries = try saveFiles.map { source -> SNESReplacementSaveReview.Entry in
            let parts = source.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 5 else { throw SNESLibraryInventory.failure() }
            let code = String(parts[3])
            let gameMatch: SNESReplacementSaveReview.GameMatch
            if includedCodes.contains(code) { gameMatch = .includedGame }
            else {
                guard let original = sourceGames[code] else { throw SNESLibraryInventory.failure() }
                if let target = targetGames[code] { gameMatch = original == target ? .matchingAddedGame : .addedGameDifferent }
                else { gameMatch = .addedGameMissing }
            }
            if let existing = files[source.path] {
                let match = SNESReplacementSaveReview.sameSavedFile(source, existing)
                return .init(path: source.path, sourceSHA256: source.sha256, destinationSHA256: existing.sha256,
                             blockerPath: match ? nil : source.path, byteCount: source.byteCount, sourceMode: source.mode, sourceModified: source.modified, disposition: match ? .unchanged : .conflict, gameMatch: gameMatch)
            }
            var blocker: String? = directories.contains(source.path) ? source.path : nil
            var parent = source.path
            while blocker == nil, let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                if files[parent] != nil { blocker = parent }
            }
            return .init(path: source.path, sourceSHA256: source.sha256, destinationSHA256: nil,
                         blockerPath: blocker, byteCount: source.byteCount, sourceMode: source.mode, sourceModified: source.modified, disposition: blocker == nil ? .new : .conflict, gameMatch: gameMatch)
        }
        try backup.validate(); try checked.validate()
        return .init(entries: entries, source: backup, destination: checked)
    }

    private struct GameIdentity: Equatable { let rom: String, launch: String }
    private static func importedGames(_ menu: SNESLibraryMenu?) throws -> [String: GameIdentity] {
        guard let menu else { return [:] }
        var result: [String: GameIdentity] = [:]
        for placement in menu.description.placements where placement.kind == "import" {
            guard let rom = placement.rom, result[placement.code] == nil else { throw SNESLibraryInventory.failure() }
            let path = String(format: "pages/%03d/%@/%@.desktop", placement.page, placement.code, placement.code)
            guard let desktop = menu.files[path], let launch = try SNESOneGameMenu.fields(desktop)["exec"], !launch.isEmpty else {
                throw SNESLibraryInventory.failure()
            }
            result[placement.code] = .init(rom: rom, launch: launch)
        }
        return result
    }
}

/// Reconstructs inert Mac material from a verified snapshot. No console access or writes.
struct SNESLibraryRestore: Sendable {
    let backup: SNESLibraryBackup, menu: SNESLibraryMenu?
    static func prepareSameConsoleSavedData(backup: SNESLibraryBackup, originals: SNESOriginalGamesFrame,
                                            destinationHWID: String) throws -> SNESLibraryReplacement {
        try prepareSavedData(backup: backup, originals: originals, destinationHWID: destinationHWID, sameConsole: true, id: UUID())
    }
    static func prepareForSync(backup: SNESLibraryBackup, originals: SNESOriginalGamesFrame,
                               destinationHWID: String, scope: SNESLibraryRestoreScope) throws -> Self {
        switch scope {
        case .sameConsole:
            return try prepare(backup: backup, originals: originals, expectedHWID: destinationHWID)
        case .replacementConsole:
            let replacement = try prepareReplacement(backup: backup, originals: originals, destinationHWID: destinationHWID)
            return .init(backup: replacement.backup, menu: replacement.menu)
        }
    }
    static func prepare(backup: SNESLibraryBackup, originals: SNESOriginalGamesFrame, expectedHWID: String, id: UUID = UUID()) throws -> Self {
        let saved = try SNESLibraryBackup.open(directory: backup.directory), inventory = saved.inventory
        guard saved.manifestSHA256 == backup.manifestSHA256, inventory.hwid == expectedHWID,
              inventory.catalogSHA256 == (try SNESLibraryCatalogIdentity.digest(originals)) else { throw SNESLibraryInventory.failure() }
        return try rebuild(saved, originals: originals, id: id)
    }

    /// Prepare content for a different SNES only when its included games match.
    /// The resulting plan is inert; a later transfer must independently verify
    /// the connected replacement and protect its existing saves.
    static func prepareReplacement(backup: SNESLibraryBackup, originals: SNESOriginalGamesFrame,
                                   destinationHWID: String, id: UUID = UUID()) throws -> SNESLibraryReplacement {
        try prepareSavedData(backup: backup, originals: originals, destinationHWID: destinationHWID, sameConsole: false, id: id)
    }

    private static func prepareSavedData(backup: SNESLibraryBackup, originals: SNESOriginalGamesFrame,
                                         destinationHWID: String, sameConsole: Bool, id: UUID) throws -> SNESLibraryReplacement {
        let saved = try SNESLibraryBackup.open(directory: backup.directory), inventory = saved.inventory
        guard saved.manifestSHA256 == backup.manifestSHA256 else { throw SNESLibraryInventory.failure() }
        guard originals.hwid == destinationHWID, (inventory.hwid == destinationHWID) == sameConsole else {
            throw RecoveryProbeError.refused(sameConsole ? "Choose a backup from this SNES and connect it again. Nothing was copied." : "Choose a backup from another SNES and connect the replacement. Nothing was copied.")
        }
        guard inventory.catalogSHA256 == (try SNESLibraryCatalogIdentity.digest(originals)) else {
            throw RecoveryProbeError.refused("The connected SNES's included games do not match this backup. Nothing was copied.")
        }
        let restored = try rebuild(saved, originals: originals, id: id)
        var codes = Set(originals.entries.map(\.code))
        if let menu = restored.menu { codes.formUnion(menu.description.placements.filter { $0.kind == "import" }.map(\.code)) }
        let profiles = inventory.files.filter { $0.path.hasPrefix("clover/profiles/") }.sorted { $0.path < $1.path }
        var saves: [SNESLibraryInventory.File] = [], unmatched: [String] = []
        for file in profiles {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count >= 5, parts[2] == "0", codes.contains(String(parts[3])) { saves.append(file) }
            else { unmatched.append(file.path) }
        }
        try saved.validate()
        return .init(sourceHWID: inventory.hwid, destinationHWID: destinationHWID, menu: restored.menu,
                     saveFiles: saves, unmatchedProfileFiles: unmatched, backup: saved, originals: originals)
    }

    private static func rebuild(_ saved: SNESLibraryBackup, originals: SNESOriginalGamesFrame, id: UUID) throws -> Self {
        let inventory = saved.inventory
        switch inventory.selection.kind {
        case .builtin: return .init(backup: saved, menu: nil)
        case .legacy: return .init(backup: saved, menu: try migrateLegacy(saved, originals: originals, id: id))
        case .library:
            guard let oldID = inventory.selection.id else { throw SNESLibraryMenu.failure() }
            let raw = try saved.read(path: "descriptions/\(oldID.uuidString).json")
            let description = try JSONDecoder().decode(SNESLibraryMenu.Manifest.self, from: raw)
            guard raw == (try SNESLibraryMenu.encode(description)), description.id == oldID else { throw SNESLibraryMenu.failure() }
            var files: [String: Data] = [:], objects: [String: Data] = [:]
            for record in description.files { files[record.path] = try saved.read(path: "menus/\(oldID.uuidString)/" + record.path) }
            for record in description.objects {
                let bytes = try saved.read(path: "objects/" + record.name)
                if record.name.hasSuffix(".sfrom") {
                    guard bytes.count >= 96, try SNESCanoeImage.prepare(rom: Data(bytes[48..<(bytes.count-48)])).data == bytes else { throw SNESLibraryMenu.failure() }
                }
                objects[record.name] = bytes
            }
            let old = try make(description, files: files, objects: objects)
            try old.validate()
            guard try saved.read(path: "menus/\(oldID.uuidString)/menu.manifest") == SNESLibraryStartupScripts.manifest(for: old) else { throw SNESLibraryMenu.failure() }
            try validateStock(old, originals: originals)
            if description.version==2 {
                let oldPrefix="Icon="+old.consoleRoot+"/",newPrefix="Icon="+SNESLibraryMenu.namespace+"/menus/"+id.uuidString+"/"
                for path in files.keys where path.hasSuffix(".desktop") {
                    guard let raw=files[path],let text=String(data:raw,encoding:.utf8) else {throw SNESLibraryMenu.failure()}
                    files[path]=Data(text.components(separatedBy:"\n").map {$0.hasPrefix(oldPrefix) ? newPrefix+String($0.dropFirst(oldPrefix.count)):$0}.joined(separator:"\n").utf8)
                }
            }
            for placement in description.placements where placement.kind == "import" {
                let path = String(format: "pages/%03d/%@/%@.desktop", placement.page, placement.code, placement.code)
                guard let raw = files[path] else { throw SNESLibraryMenu.failure() }
                files[path] = try SNESLibraryMenu.cloverDesktop(raw)
            }
            let fileRecords=description.files.map {record in
                SNESLibraryMenu.FileRecord(path:record.path,byteCount:files[record.path]!.count,sha256:BackupManifest.digest(files[record.path]!))
            }
            let next = SNESLibraryMenu.Manifest(version: description.version, id: id, catalogSHA256: BackupManifest.digest(originals.raw), graph: description.graph,
                structure: description.structure, order: description.order, objects: description.objects, files: fileRecords,
                stock: description.stock, placements: description.placements)
            let menu = try make(next, files: files, objects: objects); try menu.validate()
            return .init(backup: saved, menu: menu)
        }
    }
    private static func make(_ description: SNESLibraryMenu.Manifest, files: [String: Data], objects: [String: Data]) throws -> SNESLibraryMenu {
        let sources: [SNESLibrarySourceFile] = []
        return .init(description: description, files: files, objects: objects, sources: sources,
            manifest: try SNESLibraryMenu.encode(description), sourceSHA256: BackupManifest.digest(try SNESLibraryMenu.encode(sources)))
    }
    static func validateStock(_ menu: SNESLibraryMenu, originals: SNESOriginalGamesFrame) throws {
        let entries = Dictionary(uniqueKeysWithValues: originals.entries.map { ($0.code, $0) })
        for reference in menu.description.stock {
            guard let entry = entries[reference.code], let desktop = entry.files.first(where: { $0.name == entry.code + ".desktop" }),
                  reference.desktopSHA256 == BackupManifest.digest(desktop.data), reference.romSHA256 == entry.romSHA256,
                  reference.romBytes == entry.romBytes else { throw SNESLibraryMenu.failure() }
            var expected = try SNESOneGameMenu.fields(desktop.data); expected.removeValue(forKey: "sortrawtitle")
            for placement in menu.description.placements where placement.code == entry.code {
                let path = String(format: "pages/%03d/%@/%@.desktop", placement.page, entry.code, entry.code)
                guard let bytes = menu.files[path] else { throw SNESLibraryMenu.failure() }
                var actual = try SNESOneGameMenu.fields(bytes); actual.removeValue(forKey: "sortrawtitle")
                guard actual == expected else { throw SNESLibraryMenu.failure() }
            }
        }
    }
    private static func replace(_ raw: Data, fields: [String: String]) throws -> Data {
        _ = try SNESOneGameMenu.fields(raw)
        guard let text = String(data: raw, encoding: .utf8) else { throw SNESLibraryMenu.failure() }
        var remaining = fields, lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line == "[Description]" { break }
            if let equal = line.firstIndex(of: "="), let value = remaining.removeValue(forKey: String(line[..<equal]).lowercased()) {
                lines.append(String(line[..<equal]) + "=" + value)
            } else { lines.append(line) }
        }
        while lines.last == "" { lines.removeLast() }
        if !remaining.isEmpty {
            let names = ["sortrawtitle": "SortRawTitle", "code": "Code", "exec": "Exec", "path": "Path", "icon": "Icon"]
            lines.append("[X-CLOVER Game]")
            for key in remaining.keys.sorted() {
                guard let name = names[key], let value = remaining[key] else { throw SNESLibraryMenu.failure() }
                lines.append(name + "=" + value)
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    private static func migrateLegacy(_ saved: SNESLibraryBackup, originals: SNESOriginalGamesFrame, id: UUID) throws -> SNESLibraryMenu {
        guard let oldID = saved.inventory.selection.id else { throw SNESLibraryMenu.failure() }
        let prefix = "legacy/menus/\(oldID.uuidString)/"
        var legacy: [String: Data] = [:]
        for file in saved.inventory.files where file.path.hasPrefix(prefix) && file.path != prefix + "menu.manifest" {
            legacy[String(file.path.dropFirst(prefix.count))] = try saved.read(path: file.path)
        }
        let wire = Data(("SWIFTHAKCHI_SNES_MENU_V1\n" + legacy.keys.sorted().map { BackupManifest.digest(legacy[$0]!) + " " + String(legacy[$0]!.count) + " " + $0 + "\n" }.joined()).utf8)
        guard try saved.read(path: prefix + "menu.manifest") == wire else { throw SNESLibraryMenu.failure() }
        var desktops: [String: Data] = [:], objects: [String: Data] = [:], custom: [String: (String, String, String)] = [:]
        let stock = Dictionary(uniqueKeysWithValues: originals.entries.map { ($0.code, $0) })
        for (path, raw) in legacy where path.hasSuffix(".desktop") {
            let bits = path.components(separatedBy: "/")
            guard bits.count == 3, bits[0] == "games", bits[2] == bits[1] + ".desktop" else { throw SNESLibraryMenu.failure() }
            let code = bits[1]; desktops[code] = raw
            if let original = stock[code] {
                guard original.files.first(where: { $0.name == code + ".desktop" })?.data == raw else { throw SNESLibraryMenu.failure() }
            } else {
                guard code.range(of: #"^CLV-U-[A-Z0-9]{5}$"#, options: .regularExpression) != nil,
                      let sfrom = legacy["games/\(code)/\(code).sfrom"], sfrom.count >= 96,
                      try SNESCanoeTrialImage(rom: Data(sfrom[48..<(sfrom.count-48)])).data == sfrom,
                      let large = legacy["games/\(code)/\(code).png"], let small = legacy["games/\(code)/\(code)_small.png"] else { throw SNESLibraryMenu.failure() }
                let rom = BackupManifest.digest(sfrom) + ".sfrom"; objects[rom] = sfrom
                let pair = SNESLibraryObjects.storeImages((large, small), in: &objects)
                custom[code] = (rom, pair.large, pair.small)
            }
        }
        guard custom.count == 1, Set(desktops.keys) == Set(stock.keys).union(custom.keys), legacy.count == stock.count + 4 else { throw SNESLibraryMenu.failure() }
        let games = desktops.map { Game(code: $0.key, desktopContent: String(decoding: $0.value, as: UTF8.self), consoleType: .snesUsa, source: stock[$0.key] == nil ? .local : .stock) }
        let structure = ConsoleStructure(mode: .flat, maximumGamesPerPage: .thirtyFive)
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: Set(stock.keys), order: .title, structure: structure)
        var files: [String: Data] = [:], placements: [SNESLibraryMenu.Placement] = []
        for page in graph.screens {
            for (position, item) in page.entries.enumerated() {
                guard case .game(let code) = item, let raw = desktops[code] else { throw SNESLibraryMenu.failure() }
                var edits = ["sortrawtitle": String(format: "%05d", position)]
                if let (rom, large, small) = custom[code] {
                    edits["exec"] = "/usr/bin/clover-canoe-shvc -rom " + SNESLibraryMenu.namespace + "/objects/" + rom + " --volume 100 -rollback-snapshot-period 600"
                    edits["path"] = "/var/lib/clover/profiles/0/" + code
                    edits["icon"] = SNESLibraryMenu.namespace + "/objects/" + large; edits["code"] = code
                    placements.append(.init(page: page.number, position: position, code: code, kind: "import", target: nil, rom: rom, artwork: large, smallArtwork: small))
                } else { placements.append(.init(page: page.number, position: position, code: code, kind: "stock", target: nil, rom: nil, artwork: nil, smallArtwork: nil)) }
                var rendered = try replace(raw, fields: edits)
                if custom[code] != nil { rendered = try SNESLibraryMenu.cloverDesktop(rendered) }
                files[String(format: "pages/%03d/%@/%@.desktop", page.number, code, code)] = rendered
            }
        }
        let references = try originals.entries.sorted { $0.code < $1.code }.map { entry -> SNESLibraryMenu.StockReference in
            guard let raw = desktops[entry.code] else { throw SNESLibraryMenu.failure() }
            return .init(code: entry.code, desktopSHA256: BackupManifest.digest(raw), romSHA256: entry.romSHA256, romBytes: entry.romBytes)
        }
        let description = SNESLibraryMenu.Manifest(version: 1, id: id, catalogSHA256: BackupManifest.digest(originals.raw), graph: graph, structure: structure,
            order: .title, objects: objects.keys.sorted().map { .init(name: $0, byteCount: objects[$0]!.count, sha256: BackupManifest.digest(objects[$0]!)) },
            files: files.keys.sorted().map { .init(path: $0, byteCount: files[$0]!.count, sha256: BackupManifest.digest(files[$0]!)) }, stock: references, placements: placements)
        let menu = try make(description, files: files, objects: objects); try menu.validate(); try validateStock(menu, originals: originals); return menu
    }
}

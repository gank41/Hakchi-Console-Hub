import Foundation
import SwiftHakchiCore

/// Mac-only folder preview. It does not contain console files or authorize sync.
struct SNESCompatibilityMenuPreview {
    let graph: ConsoleMenuGraph
    let requests: [String: SNESCompatibilityLaunchRequest]
    let resolvedCodes: Set<String>
}
struct SNESCompatibilityObjects {
    let items: [String: SNESLibraryObjects.Item], objects: [String: Data], sources: [SNESLibrarySourceFile]
    /// Separate support data; never mixed into the game-object transfer set.
    let controllerProfile: SNESCompatibilityControllerProfile.Prepared?
    let corePackage: SNESCompatibilityCorePackage?
    let frontendPackage: SNESCompatibilityFrontendPackage?
    let supportPayload: SNESCompatibilitySupportPayload?
}
/// Local choices only. Unavailable games stay selected until an explicit per-sync exclusion.
@MainActor struct SNESLibraryReviewDraft {
    let review: SNESLibraryCompatibility
    private let originals: SNESOriginalGamesFrame, cache: SNESLibraryObjectCache
    private(set) var selected: Set<String>, decisions: [String: SNESLibraryCompatibility.Resolution] = [:]
    private(set) var structure: ConsoleStructure, order: ConsoleMenuOrder, allowSkippingUnavailable = false
    private(set) var revision = 0
    init(review: SNESLibraryCompatibility, originals: SNESOriginalGamesFrame, cache: SNESLibraryObjectCache,
         selected: Set<String>, structure: ConsoleStructure, order: ConsoleMenuOrder) throws {
        guard selected.isSubset(of: Set(review.rows.map { $0.game.code })), review.stockCodes == Set(originals.entries.map(\.code)) else { throw SNESLibraryMenu.failure() }
        self.review = review; self.originals = originals; self.cache = cache; self.selected = selected; self.structure = structure; self.order = order
    }
    var unavailableCodes: Set<String> { Set(cache.unavailable.keys).union(review.rows.filter { $0.issue != nil }.map { $0.game.code }) }
    func unavailableReason(_ code: String) -> String? { review.rows.first { $0.game.code == code }?.issue ?? cache.unavailable[code] }
    var unresolvedDuplicateCodes: Set<String> { Set(review.rows.filter { (allowSkippingUnavailable ? selected.subtracting(excludedCodes) : selected).contains($0.game.code) && $0.needsDecision && decisions[$0.game.code] == nil }.map { $0.game.code }) }
    var excludedCodes: Set<String> {
        Set(review.rows.filter { row in
            guard selected.contains(row.game.code), unavailableCodes.contains(row.game.code) else { return false }
            return row.matches.isEmpty || decisions[row.game.code] == .keepImported || (row.needsDecision && decisions[row.game.code] == nil)
        }.map { $0.game.code })
    }
    var effectiveImportCount: Int {
        review.rows.filter { row in
            selected.contains(row.game.code) && !unavailableCodes.contains(row.game.code) &&
                (row.matches.isEmpty || (row.matches.count == 1 && decisions[row.game.code] == .keepImported))
        }.count
    }
    var fingerprint: String {
        let choices = decisions.keys.sorted().map { $0 + ":" + (decisions[$0] == .keepBuiltIn ? "builtin" : "import") }
        let settings = (try? SNESLibraryMenu.encode(structure)) ?? Data()
        return BackupManifest.digest(Data(([String(revision), selected.sorted().joined(separator: ","), choices.joined(separator: ","), String(allowSkippingUnavailable)].joined(separator: "\n")).utf8) + settings + ((try? SNESLibraryMenu.encode(order)) ?? Data()))
    }
    mutating func setSelected(_ code: String, selected: Bool) throws {
        guard review.rows.contains(where: { $0.game.code == code }) else { throw SNESLibraryMenu.failure() }
        if selected { self.selected.insert(code) } else { self.selected.remove(code) }; revision += 1
    }
    mutating func setDecision(_ code: String, resolution: SNESLibraryCompatibility.Resolution?) throws {
        guard review.rows.contains(where: { $0.game.code == code && !$0.matches.isEmpty }) else { throw SNESLibraryMenu.failure() }
        decisions[code] = resolution; revision += 1
    }
    mutating func setStructure(_ value: ConsoleStructure) { structure = value; revision += 1 }
    mutating func setOrder(_ value: ConsoleMenuOrder) { order = value; revision += 1 }
    mutating func setAllowSkippingUnavailable(_ value: Bool) { allowSkippingUnavailable = value; revision += 1 }
    /// Prepare an inert request using the current review choices. This does
    /// not authorize console writes or enable the compatibility launcher.
    func prepareCompatibilityLaunch(code: String, session: Data, epoch: UInt64) throws -> SNESCompatibilityLaunchRequest {
        try review.prepareCompatibilityLaunch(code: code, selected: selected, decisions: decisions,
                                              session: session, epoch: epoch)
    }
    /// Prepares only local review material. It does not enable compatibility sync.
    func prepareCompatibilityLaunches(sessions: [String: Data], epoch: UInt64) throws -> [String: SNESCompatibilityLaunchRequest] {
        let effective = allowSkippingUnavailable ? selected.subtracting(excludedCodes) : selected
        return try review.prepareCompatibilityLaunches(selected: effective, decisions: decisions.filter { effective.contains($0.key) }, sessions: sessions, epoch: epoch)
    }
    /// Prepare small Mac-only session references for the currently reviewed
    /// compatibility selection. No result permits a transfer or console launch.
    /// The caller authenticates the current console observation and controls
    /// the selected Backups Folder exclusively. Partial failures retain any
    /// already-created references for inspection rather than deleting them.
    func prepareCompatibilityRecoveryReferences(backup: SNESLibraryBackup, current: SNESLibraryInventory, root: URL,
                                                sessions: [String: Data], epoch: UInt64) throws -> [String: SNESCompatibilityRecoveryReference] {
        let requests = try prepareCompatibilityLaunches(sessions: sessions, epoch: epoch)
        var evidence: [String: SNESCompatibilityBackupEvidence] = [:]
        for code in requests.keys.sorted() {
            guard let request = requests[code] else { throw SNESLibraryMenu.failure() }
            evidence[code] = try SNESCompatibilityBackupEvidence.capture(backup: backup, current: current, request: request)
        }
        if requests.isEmpty { return [:] }
        let directory = try RestoreDirectory(root)
        let existing = Set(try directory.names().map { $0.lowercased() })
        let planned = evidence.values.map { SNESCompatibilityRecoveryReference.plannedName(for: $0).lowercased() }
        guard Set(planned).count == requests.count, existing.isDisjoint(with: planned) else { throw SNESLibraryMenu.failure() }
        try directory.check(); try backup.validate()
        var references: [String: SNESCompatibilityRecoveryReference] = [:]
        for code in requests.keys.sorted() {
            guard let request = requests[code] else { throw SNESLibraryMenu.failure() }
            references[code] = try SNESCompatibilityRecoveryReference.create(root: directory.url, backup: backup, current: current, request: request)
        }
        try directory.check(); try backup.validate()
        return references
    }
    func compatibilityMenuPreview(sessions: [String: Data], epoch: UInt64) throws -> SNESCompatibilityMenuPreview {
        let effective = allowSkippingUnavailable ? selected.subtracting(excludedCodes) : selected
        let choices = decisions.filter { effective.contains($0.key) }
        let selection = try review.compatibilitySelection(selected: effective, decisions: choices)
        let requests = try review.prepareCompatibilityLaunches(selected: effective, decisions: choices, sessions: sessions, epoch: epoch)
        guard Set(requests.keys) == selection.candidates else { throw SNESLibraryMenu.failure() }
        return .init(graph: try compatibilityGraph(resolved: selection.resolved), requests: requests, resolvedCodes: selection.resolved)
    }
    /// Folder layout only; no tokens, capacity measurement or console files.
    func compatibilityLayoutPreview() throws -> ConsoleMenuGraph {
        let effective = allowSkippingUnavailable ? selected.subtracting(excludedCodes) : selected
        let choices = decisions.filter { effective.contains($0.key) }
        let selection = try review.compatibilitySelection(selected: effective, decisions: choices)
        guard !selection.candidates.isEmpty else { throw SNESLibraryMenu.failure() }
        return try compatibilityGraph(resolved: selection.resolved)
    }
    /// Builds local content only. A production compatibility menu and transfer
    /// still require a verified launcher and a separately supported format.
    func prepareCompatibilityObjects(sessions: [String: Data], epoch: UInt64) throws -> SNESCompatibilityObjects {
        let requests = try prepareCompatibilityLaunches(sessions: sessions, epoch: epoch)
        var items: [String: SNESLibraryObjects.Item] = [:], objects: [String: Data] = [:], sources: [SNESLibrarySourceFile] = []
        var artworkCache: [String: (large: Data, small: Data)] = [:]
        for code in requests.keys.sorted() {
            try Task.checkCancellation()
            guard let request = requests[code], let row = review.rows.first(where: { $0.game.code == code }),
                  let source = row.source, source.directory.standardizedFileURL == request.source.directory.standardizedFileURL,
                  source.filename == request.source.filename, source.sha256 == request.source.sha256,
                  source.byteCount == request.source.byteCount else { throw SNESLibraryMenu.failure() }
            try request.verifySource()
            let game = row.game, directory = URL(fileURLWithPath: game.romPath, isDirectory: true)
            let rom = try SNESLibrarySourceFile.capture(directory: directory, name: source.filename, maximum: 4 * 1024 * 1024 + 512)
            let ext = URL(fileURLWithPath: source.filename).pathExtension.lowercased()
            guard ["sfc", "smc"].contains(ext), rom.0.sha256 == source.sha256, rom.0.byteCount == source.byteCount else { throw SNESLibraryMenu.failure() }
            let metadata = try SNESLibrarySourceFile.capture(directory: directory, name: code + ".desktop", maximum: 16384)
            _ = try SNESOneGameMenu.fields(metadata.1)
            let disk = Game(code: code, desktopContent: String(decoding: metadata.1, as: UTF8.self), consoleType: .snesUsa, source: .local)
            guard disk.code == code, disk.name == game.name, disk.sortName == game.sortName, disk.publisher == game.publisher,
                  disk.releaseDate == game.releaseDate, disk.players == game.players, disk.saveCount == game.saveCount,
                  disk.simultaneous == game.simultaneous, disk.copyright == game.copyright else {
                throw SNESLibraryCompatibility.failure("Game details changed. Save your edits and prepare a new review.")
            }
            let artwork = try SNESLibrarySourceFile.capture(directory: directory, name: code + ".png", maximum: 8 * 1024 * 1024)
            let rendered: (large: Data, small: Data)
            if let cached = artworkCache[artwork.0.sha256] { rendered = cached }
            else { rendered = try SNESLibraryObjects.images(from: artwork.1); artworkCache[artwork.0.sha256] = rendered }
            let names = SNESLibraryObjects.storeImages(rendered, in: &objects), romName = source.sha256 + "." + ext
            guard objects[romName] == nil || objects[romName] == rom.1 else { throw SNESLibraryMenu.failure() }
            objects[romName] = rom.1
            items[code] = .init(game: game, rom: romName, artwork: names.large, smallArtwork: names.small, saveCount: game.saveCount)
            sources += [rom.0, metadata.0, artwork.0]
        }
        guard objects.values.reduce(0, { $0 + $1.count }) <= 128 * 1024 * 1024 else { throw SNESLibraryMenu.failure() }
        for source in sources { try source.verify() }
        for code in requests.keys.sorted() { guard let request = requests[code] else { throw SNESLibraryMenu.failure() }; try request.verifySource() }
        let controller = try requests.isEmpty ? nil : SNESCompatibilityControllerProfile.prepare()
        let core = try requests.isEmpty ? nil : SNESCompatibilityCorePackage.loadBundled()
        let frontend = try requests.isEmpty ? nil : SNESCompatibilityFrontendPackage.loadBundled()
        let support: SNESCompatibilitySupportPayload?
        if let controller, let core, let frontend {
            support = try SNESCompatibilitySupportPayload(controller: controller, core: core, frontend: frontend)
        } else {
            support = nil
        }
        return .init(items: items, objects: objects, sources: sources, controllerProfile: controller, corePackage: core, frontendPackage: frontend, supportPayload: support)
    }
    /// Mac-only menu candidate. It may be saved for offline review but cannot be transferred or synced.
    func compatibilityMenuCandidate(sessions: [String: Data], epoch: UInt64, artwork: SNESLibraryMenu.NavigationArtwork) throws -> SNESLibraryMenu {
        let effective = allowSkippingUnavailable ? selected.subtracting(excludedCodes) : selected
        let choices = decisions.filter { effective.contains($0.key) }
        let selection = try review.compatibilitySelection(selected: effective, decisions: choices)
        guard !selection.candidates.isEmpty else { throw SNESLibraryMenu.failure() }
        let compatible = try prepareCompatibilityObjects(sessions: sessions, epoch: epoch)
        guard Set(compatible.items.keys) == selection.candidates else { throw SNESLibraryMenu.failure() }
        let native = try SNESLibraryObjects.prepare(review: review, resolvedCodes: selection.resolved.subtracting(selection.candidates))
        var items = native.items, objects = native.objects
        for (code, item) in compatible.items { guard items[code] == nil else { throw SNESLibraryMenu.failure() }; items[code] = item }
        for (name, data) in compatible.objects {
            guard objects[name] == nil || objects[name] == data else { throw SNESLibraryMenu.failure() }
            objects[name] = data
        }
        let content = SNESLibraryObjects(items: items, objects: objects, sources: native.sources + compatible.sources)
        for source in content.sources { try source.verify() }
        let candidate = try SNESLibraryMenu.build(review: review, originals: originals, resolved: selection.resolved, content: content,
            compatibilityCodes: selection.candidates, order: order, structure: structure, artwork: artwork, id: UUID())
        for source in content.sources { try source.verify() }
        return candidate
    }
    private func compatibilityGraph(resolved: Set<String>) throws -> ConsoleMenuGraph {
        guard review.stockCodes == Set(originals.entries.map(\.code)) else { throw SNESLibraryMenu.failure() }
        var games = review.rows.filter { resolved.contains($0.game.code) }.map(\.game)
        var stocks = Set<String>()
        for entry in originals.entries where resolved.contains(entry.code) {
            guard let desktop = entry.files.first(where: { $0.name == entry.code + ".desktop" }),
                  let text = String(data: desktop.data, encoding: .utf8),
                  let title = try SNESOneGameMenu.fields(desktop.data)["name"], !title.isEmpty,
                  SNESLibraryMenu.safeText(title) else { throw SNESLibraryMenu.failure() }
            stocks.insert(entry.code)
            games.append(Game(code: entry.code, desktopContent: text, consoleType: .snesUsa, source: .stock))
        }
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: stocks, order: order, structure: structure)
        guard Set(graph.screens.flatMap(\.gameCodes)) == resolved else { throw SNESLibraryMenu.failure() }
        return graph
    }
    func menu(id: UUID = UUID(), artwork: SNESLibraryMenu.NavigationArtwork? = nil) throws -> SNESLibraryMenu {
        guard allowSkippingUnavailable || excludedCodes.isEmpty else { throw SNESLibraryCompatibility.failure("To sync the supported games now, select “Keep unsupported games on this Mac”. Your other games stay in the library.") }
        let effective = allowSkippingUnavailable ? selected.subtracting(excludedCodes) : selected
        let decisions = decisions.filter { effective.contains($0.key) }
        let navigation: SNESLibraryMenu.NavigationArtwork
        if let artwork { navigation = artwork }
        else { navigation = try SNESLibraryNavigationArtwork.standard() }
        return try SNESLibraryMenu.prepare(review: review, originals: originals, selected: effective, decisions: decisions,
            order: order, structure: structure, artwork: navigation, id: id, cache: cache)
    }
}

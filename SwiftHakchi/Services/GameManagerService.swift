import Foundation
import CoreGraphics
import ImageIO
import os
import SwiftHakchiCore

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameManager")

/// Manages the local game library — loading, saving, importing ROMs
@MainActor
final class GameManagerService: ObservableObject {
    @Published var games: [Game] = [] { didSet { persistSelections() } }
    @Published var isLoading: Bool = false
    @Published private var includedCatalogs: [ConsoleType: [Game]] = [:]
    var knownIncludedGames: [Game] { games.filter(\.isStock) + includedCatalogs.values.flatMap { $0 } }
    func includedCatalog(for console: ConsoleType) -> [Game] { includedCatalogs[console] ?? [] }
    /// Metadata cache for duplicate hints only; never a console write/selection authority.
    func rememberSNESOriginalGames(_ frame: SNESOriginalGamesFrame) throws {
        let originals = try frame.entries.map { entry -> Game in
            guard let metadata = entry.files.first(where: { $0.name == entry.code + ".desktop" }),
                  let text = String(data: metadata.data, encoding: .utf8) else { throw SNESOriginalGamesFrame.failure() }
            let game = Game(code: entry.code, desktopContent: text, consoleType: .snesUsa, source: .stock)
            guard game.code == entry.code else { throw SNESOriginalGamesFrame.failure() }
            return game
        }
        includedCatalogs[.snesUsa] = originals
    }


    let metadataProvider: any GameMetadataProviding
    init(metadataProvider: any GameMetadataProviding = ScraperService(), config: AppConfig = .shared) {
        self.metadataProvider = metadataProvider
        self.config = config
    }

    private let config: AppConfig
    @Published var selectionError: String?
    private var currentProfile: ConsoleProfile?
    private var restoringSelection = false
    private var inspectionPreviousGames: [Game]?
    private var inspectionPreviousProfile: ConsoleProfile?
    @Published private(set) var isInspectingLegacy = false
    @Published private(set) var legacyRemoteGames: [Game] = []

    var legacyLocalGames: [Game] {
        (inspectionPreviousGames ?? games).filter { $0.source == .local }
    }

    func mergeInspectionGames(_ remote: [Game]) {
        let previousRestoring = restoringSelection
        restoringSelection = true
        defer { restoringSelection = previousRestoring }
        if inspectionPreviousGames == nil {
            inspectionPreviousGames = games
            inspectionPreviousProfile = currentProfile
        }
        isInspectingLegacy = true
        currentProfile = nil
        legacyRemoteGames = remote
        let local = inspectionPreviousGames?.filter { $0.source == .local } ?? []
        let installed = Set(remote.filter { $0.source == .console }.map(\.code))
        var merged = local
        for index in merged.indices { merged[index].isOnConsole = installed.contains(merged[index].code) }
        let localCodes = Set(local.map(\.code))
        games = (merged + remote.filter { !localCodes.contains($0.code) })
            .sorted { ($0.name, $0.code) < ($1.name, $1.code) }
    }

    func configureSelection(deviceID: String, consoleType: ConsoleType, visibleCodes: Set<String>? = nil) {
        currentProfile = nil
        let previousRestoring = restoringSelection
        restoringSelection = true
        defer { restoringSelection = previousRestoring }
        guard !deviceID.isEmpty, consoleType != .unknown else {
            for i in games.indices where !games[i].isStock { games[i].isSelected = false }
            return
        }
        do {
            let store = ConsoleProfileStore(directory: config.workspace.profiles)
            let saved = try store.load(deviceID: deviceID, systemCode: consoleType.syncCode)
            let profile = saved ?? ConsoleProfile(deviceID: deviceID, systemCode: consoleType.syncCode,
                selectedCustomCodes: Set(games.filter { !$0.isStock && (visibleCodes?.contains($0.code) ?? $0.isOnConsole) }.map(\.code)),
                hiddenStockCodes: Set(games.filter { $0.isStock && !(visibleCodes?.contains($0.code) ?? $0.isOnConsole) }.map(\.code)))
            for i in games.indices {
                games[i].isSelected = games[i].isStock ? !profile.hiddenStockCodes.contains(games[i].code) : profile.selectedCustomCodes.contains(games[i].code)
            }
            currentProfile = profile
            selectionError = nil
        } catch {
            for i in games.indices where !games[i].isStock { games[i].isSelected = false }
            selectionError = "Could not load console selections: " + error.localizedDescription
        }
    }

    func resetSelectionsToInstalled() {
        guard !config.lastDeviceId.isEmpty else { return }
        currentProfile = ConsoleProfile(deviceID: config.lastDeviceId, systemCode: config.lastConsoleType.syncCode)
        restoringSelection = true
        for i in games.indices { games[i].isSelected = games[i].isOnConsole }
        restoringSelection = false
        selectionError = nil
        persistSelections()
    }

    /// Apply a checkbox action to a snapshot of matching codes, publishing and saving once.
    func setSelection(_ selected: Bool, codes: Set<String>) {
        guard !isInspectingLegacy, !isLoading, selectionError == nil, !codes.isEmpty else { return }
        var updated = games
        var changed = false
        for index in updated.indices where codes.contains(updated[index].code) && updated[index].isSelected != selected {
            updated[index].isSelected = selected
            changed = true
        }
        if changed { games = updated }
    }

    private func persistSelections() {
        guard !restoringSelection, !isInspectingLegacy, var profile = currentProfile, selectionError == nil else { return }
        profile.selectedCustomCodes = Set(games.filter { !$0.isStock && $0.isSelected }.map(\.code))
        profile.hiddenStockCodes = Set(games.filter { $0.isStock && !$0.isSelected }.map(\.code))
        do {
            try ConsoleProfileStore(directory: config.workspace.profiles).save(profile)
            currentProfile = profile
        } catch { selectionError = "Could not save console selections: " + error.localizedDescription }
    }


    /// Load games from the local games directory, plus cached stock games from the last known device.
    func loadGames() {
        let previousRestoring = restoringSelection
        restoringSelection = true
        defer { restoringSelection = previousRestoring }
        isLoading = true
        defer { isLoading = false }

        let gamesDir = config.gamesDirectory
        var loadedGames: [Game] = []

        if FileManager.default.fileExists(atPath: gamesDir.path),
           let contents = try? FileManager.default.contentsOfDirectory(
               at: gamesDir, includingPropertiesForKeys: nil
           ) {
            for dir in contents where dir.hasDirectoryPath {
                let desktopPath = dir
                    .appendingPathComponent(dir.lastPathComponent)
                    .appendingPathExtension("desktop")

                guard FileManager.default.fileExists(atPath: desktopPath.path),
                      let data = try? Data(contentsOf: desktopPath)
                else { continue }

                let desktop = DesktopFile(data: data)
                if desktop.code.isEmpty {
                    desktop.code = dir.lastPathComponent
                }

                let game = Game(
                    desktopFile: desktop,
                    consoleType: config.lastConsoleType,
                    basePath: gamesDir.path,
                    source: .local
                )
                if GameGenieVariantStore.hasLegacyTitle(desktop), (try? GameGenieVariantStore.isManagedCopy(game)) == true {
                    GameGenieVariantStore.relabelLegacyTitle(desktop)
                    loadedGames.append(Game(desktopFile: desktop, consoleType: config.lastConsoleType,
                                            basePath: gamesDir.path, source: .local))
                } else {
                    loadedGames.append(game)
                }
            }
        }

        // Apply cached installed status to local games — instant, no SSH
        let cachedInstalled = Set(config.installedGameCodes)
        if !cachedInstalled.isEmpty {
            for i in loadedGames.indices where loadedGames[i].source == .local {
                loadedGames[i].isOnConsole = cachedInstalled.contains(loadedGames[i].id)
            }
        }

        // Load cached stock games from the last known device — instant, no SSH
        let localIds = Set(loadedGames.map { $0.id })
        let lastDeviceId = config.lastDeviceId
        if !lastDeviceId.isEmpty, let cache = StockGameCache.load(deviceId: lastDeviceId),
           cache.consoleType == config.lastConsoleType {
            let cachedGames = cache.toGames().filter { !localIds.contains($0.id) }
            loadedGames.append(contentsOf: cachedGames)
            logger.info("Loaded \(cachedGames.count) cached stock games for device \(lastDeviceId)")
        }

        // Merge with any existing console-pulled games still in memory
        let consoleGames = games.filter { ($0.source == .stock || $0.source == .console)
            && $0.consoleType == config.lastConsoleType }
        let allIds = Set(loadedGames.map { $0.id })
        let nonConflicting = consoleGames.filter { !allIds.contains($0.id) }
        loadedGames.append(contentsOf: nonConflicting)

        games = loadedGames.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        configureSelection(deviceID: config.lastDeviceId, consoleType: config.lastConsoleType)

        // Apply cached covers immediately
        applyCachedCovers()
    }

    func mergeConsoleGames(_ remote: [Game], installedCodes: Set<String>, deviceID: String, consoleType: ConsoleType, visibleCodes: Set<String>? = nil) {
        let previousRestoring = restoringSelection
        restoringSelection = true
        defer { restoringSelection = previousRestoring }
        var locals = games.filter { $0.source == .local }
        for i in locals.indices { locals[i].isOnConsole = installedCodes.contains(locals[i].code) }
        let localCodes = Set(locals.map(\.code))
        games = (locals + remote.filter { !localCodes.contains($0.code) }).sorted { ($0.name, $0.code) < ($1.name, $1.code) }
        configureSelection(deviceID: deviceID, consoleType: consoleType, visibleCodes: visibleCodes)
    }

    // MARK: - Pull games from console

    /// Pull the game list from a connected console via SSH.
    /// Stock games may already be loaded from cache at launch — this verifies and updates.
    /// User-installed games are always pulled fresh.
    func pullGamesFromConsole(shell: SSHService, consoleType: ConsoleType, deviceId: String) async {
        isLoading = true
        defer { isLoading = false }

        // Remember this device for instant cache load on next launch
        if !deviceId.isEmpty && config.lastDeviceId != deviceId {
            config.lastDeviceId = deviceId
            config.lastConsoleType = consoleType
            config.save()
            logger.info("Saved device ID \(deviceId) for next launch")
        }

        var pulledGames: [Game] = []

        // 1. Stock games — use cache if available, otherwise pull over SSH
        if let cache = StockGameCache.load(deviceId: deviceId) {
            pulledGames.append(contentsOf: cache.toGames())
        } else {
            let stockPath = consoleType.originalGamesPath
            let stockResults = await pullDesktopFiles(
                shell: shell, basePath: stockPath, consoleType: consoleType, source: .stock
            )
            pulledGames.append(contentsOf: stockResults.games)

            // Cache for next time
            if !stockResults.games.isEmpty {
                let cache = StockGameCache(
                    deviceId: deviceId,
                    consoleType: consoleType,
                    cachedAt: Date(),
                    games: stockResults.raw.map {
                        StockGameCache.CachedGame(code: $0.code, desktopContent: $0.content)
                    }
                )
                cache.save()
            }
        }

        // 2. User-installed games — always pull fresh
        let userGamesPath = await resolveUserGamesPath(shell: shell)
        if let userGamesPath {
            let userResults = await pullDesktopFiles(
                shell: shell, basePath: userGamesPath, consoleType: consoleType, source: .console
            )
            pulledGames.append(contentsOf: userResults.games)
        }

        // 3. Check which games are installed on the console (.storage directory)
        let installedCodes = await getInstalledGameCodes(shell: shell, consoleType: consoleType)

        // Cache installed codes for instant status on next launch
        config.installedGameCodes = Array(installedCodes)
        config.save()

        mergeConsoleGames(pulledGames, installedCodes: installedCodes, deviceID: deviceId, consoleType: consoleType)

        // 5. Apply locally cached cover art immediately (no SSH needed)
        applyCachedCovers()

        // 6. Download any missing covers from console in the background
        Task { @MainActor in
            await self.pullCoverArtFromConsole(shell: shell, consoleType: consoleType)
        }
    }

    /// Set cover art paths from locally cached files — instant, no network.
    private func applyCachedCovers() {
        let cacheDir = AppConfig.configDirectory
            .appendingPathComponent("covers", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return }

        for i in games.indices {
            guard games[i].coverArtPath == nil || games[i].coverImage == nil else { continue }
            let localCover = cacheDir.appendingPathComponent("\(games[i].code).png")
            if FileManager.default.fileExists(atPath: localCover.path) {
                games[i].coverArtPath = localCover.path
            }
        }
    }

    /// Download cover art for stock/console games directly from the console via SSH.
    /// Only downloads for games that don't already have a cover (e.g. from TGDB).
    /// Covers are resized to console dimensions and cached locally.
    private func pullCoverArtFromConsole(shell: SSHService, consoleType: ConsoleType) async {
        let cacheDir = AppConfig.configDirectory
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        for i in games.indices {
            let game = games[i]
            guard game.source == .stock || game.source == .console else { continue }

            let localCover = cacheDir.appendingPathComponent("\(game.code).png")

            // Skip if already has a cover (from TGDB download or previous cache)
            if FileManager.default.fileExists(atPath: localCover.path) {
                if games[i].coverArtPath == nil {
                    games[i].coverArtPath = localCover.path
                }
                continue
            }
            // Also skip if cover exists elsewhere (e.g. game directory)
            if let path = game.coverArtPath, FileManager.default.fileExists(atPath: path) {
                continue
            }

            // Determine remote path — stock games are under the original games path
            let basePath: String
            if game.source == .stock {
                basePath = consoleType.originalGamesPath
            } else {
                basePath = (await resolveUserGamesPath(shell: shell)) ?? "/var/lib/hakchi/games"
            }

            let remotePath = "\(basePath)/\(game.code)/\(game.code).png"

            // Download via base64 encoding (safe for binary over SSH text channel)
            guard let result = try? await shell.execute("base64 \"\(remotePath)\" 2>/dev/null"),
                  result.succeeded else {
                continue
            }

            let base64Str = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base64Str.isEmpty,
                  let imageData = Data(base64Encoded: base64Str, options: .ignoreUnknownCharacters),
                  !imageData.isEmpty else {
                continue
            }

            // Save original image (sync service handles resizing at upload time)
            try? imageData.write(to: localCover)
            games[i].coverArtPath = localCover.path
            ImageCache.shared.evict(localCover.path)
            logger.info("Cover from console: \(game.code) (\(imageData.count) bytes)")
        }
    }

    /// Raw desktop file data from a console pull (code + content pairs)
    struct PullResult {
        struct RawEntry {
            let code: String
            let content: String
        }
        let games: [Game]
        let raw: [RawEntry]
    }

    /// Pull .desktop files from a directory on the console
    private func pullDesktopFiles(
        shell: SSHService, basePath: String, consoleType: ConsoleType, source: GameSource
    ) async -> PullResult {
        var games: [Game] = []
        var rawEntries: [PullResult.RawEntry] = []

        // List game directories
        guard let result = try? await shell.execute("ls -1 \(basePath)/ 2>/dev/null"),
              result.succeeded else {
            return PullResult(games: [], raw: [])
        }

        let dirs = result.output.components(separatedBy: .newlines).filter {
            !$0.isEmpty && !$0.hasPrefix("CLV-S-") // Skip folder navigation entries
        }

        for dir in dirs {
            let dirPath = "\(basePath)/\(dir)"

            // Find .desktop file — could be dir/dir.desktop or dir/*.desktop
            let desktopContent: String?
            if let r = try? await shell.execute("cat \"\(dirPath)/\(dir).desktop\" 2>/dev/null"),
               r.succeeded, !r.output.isEmpty {
                desktopContent = r.output
            } else if let r = try? await shell.execute(
                "cat \"\(dirPath)\"/*.desktop 2>/dev/null | head -200"
            ), r.succeeded, !r.output.isEmpty {
                desktopContent = r.output
            } else {
                continue
            }

            guard let content = desktopContent else { continue }

            let game = Game(
                code: dir,
                desktopContent: content,
                consoleType: consoleType,
                source: source
            )
            games.append(game)
            rawEntries.append(PullResult.RawEntry(code: dir, content: content))
        }

        return PullResult(games: games, raw: rawEntries)
    }

    /// List CLV codes in .storage on the console — these are the currently installed custom games.
    func getInstalledGameCodes(shell: SSHService, consoleType: ConsoleType) async -> Set<String> {
        let storagePath = "/var/lib/hakchi/games/\(consoleType.syncCode)/.storage"
        guard let result = try? await shell.execute("ls -1 \"\(storagePath)/\" 2>/dev/null"),
              result.succeeded else {
            return []
        }
        let codes = result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("CLV-") }
        return Set(codes)
    }

    /// Resolve the user games path from the console config
    func resolveUserGamesPath(shell: SSHService) async -> String? {
        // Try reading from config
        if let result = try? await shell.execute(
            "grep cfg_gamepath /etc/preinit.d/p0000_config 2>/dev/null | sed \"s/.*='\\(.*\\)'/\\1/\""
        ), result.succeeded, !result.output.isEmpty {
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Default
        return "/var/lib/hakchi/games"
    }

    // MARK: - Refresh installed status

    /// Re-check which games are installed on the console and update the green checkmarks.
    func refreshInstalledStatus(shell: SSHService, consoleType: ConsoleType) async {
        let installedCodes = await getInstalledGameCodes(shell: shell, consoleType: consoleType)

        for i in games.indices {
            if games[i].source == .local {
                games[i].isOnConsole = installedCodes.contains(games[i].id)
            }
        }

        // Cache for next launch
        config.installedGameCodes = Array(installedCodes)
        config.save()
    }

    // MARK: - Import games from console

    /// Find the .storage path on the console using multiple strategies.
    /// Returns nil if no .storage directory can be found.
    private func findStoragePath(shell: SSHService, consoleType: ConsoleType) async -> String? {
        // Strategy 1: syncCode-based path (standard Hakchi2-CE layout)
        let syncCodePath = "/var/lib/hakchi/games/\(consoleType.syncCode)/.storage"
        if let r = try? await shell.execute("[ -d \"\(syncCodePath)\" ] && echo yes"),
           r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" {
            logger.info("Found .storage via syncCode: \(syncCodePath)")
            return syncCodePath
        }

        // Strategy 2: resolve user games path from console config + .storage
        if let userPath = await resolveUserGamesPath(shell: shell) {
            let userStoragePath = "\(userPath)/.storage"
            if let r = try? await shell.execute("[ -d \"\(userStoragePath)\" ] && echo yes"),
               r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" {
                logger.info("Found .storage via userGamesPath: \(userStoragePath)")
                return userStoragePath
            }
        }

        // Strategy 3: search for .storage directories under /var/lib/hakchi/games
        if let r = try? await shell.execute(
            "find /var/lib/hakchi/games -maxdepth 2 -name .storage -type d 2>/dev/null | head -1"
        ), r.succeeded {
            let found = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !found.isEmpty {
                logger.info("Found .storage via find: \(found)")
                return found
            }
        }

        logger.warning("No .storage directory found on console")
        return nil
    }

    /// List CLV codes from a .storage path on the console.
    private func listStorageCodes(shell: SSHService, storagePath: String) async -> Set<String> {
        guard let result = try? await shell.execute("ls -1 \"\(storagePath)/\" 2>/dev/null"),
              result.succeeded else {
            return []
        }
        let codes = result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("CLV-") }
        return Set(codes)
    }

    /// Import custom games from the console into the local library.
    /// Downloads ROMs, cover art, and .desktop files for each console game
    /// not already present locally.
    func importGamesFromConsole(shell: SSHService, consoleType: ConsoleType,
                                progress: @escaping @Sendable (String, Double) -> Void) async throws -> Int {
        let inventory = try await DeviceInventoryService.inspect(shell: shell)
        guard let base = inventory.syncBase else { throw SyncPlanError.unsupportedConsole }
        let remote = try await ConsoleLibraryService.read(inventory: inventory, shell: shell).filter { !$0.isStock }
        var imported = 0
        for game in remote where !games.contains(where: { $0.code == game.code && $0.source == .local }) {
            try Task.checkCancellation()
            progress("Importing and verifying \(game.name)...", Double(imported) / Double(max(1, remote.count)))
            let selected = games.first(where: { $0.code == game.code })?.isSelected ?? true
            let folder = try await ConsoleGameImporter.importGame(code: game.code, storage: base + "/.storage",
                desktop: SyncPlanAdapter.desktopFile(for: game).toData(), destination: config.gamesDirectory, shell: shell)
            let metadata = DesktopFile(data: try Data(contentsOf: folder.appendingPathComponent(game.code + ".desktop")))
            var local = Game(desktopFile: metadata, consoleType: consoleType, basePath: config.gamesDirectory.path, source: .local)
            local.isSelected = selected; local.isOnConsole = true
            let previousRestoring = restoringSelection
            restoringSelection = true
            games.removeAll { $0.code == game.code }
            games.append(local)
            restoringSelection = previousRestoring
            persistSelections()
            imported += 1
        }
        games.sort { ($0.name, $0.code) < ($1.name, $1.code) }
        return imported
    }

    // MARK: - Clear console games

    /// Remove user-installed console games on disconnect, but keep stock games from cache
    func clearConsoleGames() {
        let previousRestoring = restoringSelection
        restoringSelection = true
        defer { restoringSelection = previousRestoring }
        if let previous = inspectionPreviousGames {
            games = previous; currentProfile = inspectionPreviousProfile
            inspectionPreviousGames = nil; inspectionPreviousProfile = nil; isInspectingLegacy = false
            legacyRemoteGames = []
        } else {
            games.removeAll { $0.source != .local }
        }
    }

    // MARK: - Import ROMs

    private struct ROMImportCandidate: Sendable {
        let url: URL, desktopData: Data, match: IncludedGameDuplicate?
        let sourceDigest: String?
        var desktop: DesktopFile { DesktopFile(data: desktopData) }
    }
    private struct ROMImportPlan: Sendable {
        let candidates: [ROMImportCandidate], skippedLocal: Int
    }

    private nonisolated static func prepareImport(_ sourceURLs: [URL], consoleType: ConsoleType,
                                                   stock: [Game], seen initial: Set<String>, verifySource: Bool = false) throws -> ROMImportPlan {
        var seen = initial, skippedLocal = 0, candidates: [ROMImportCandidate] = []
        for url in sourceURLs {
            try Task.checkCancellation()
            let sourceDigest = verifySource ? BackupManifest.digest(try Data(contentsOf: url, options: .mappedIfSafe)) : nil
            let code = generateCode(for: consoleType, crc32: CRC32.romChecksum(file: url))
            guard seen.insert(code).inserted else { skippedLocal += 1; continue }
            let desktop = DesktopFile(); desktop.code = code
            if let dbEntry = GameDatabase.shared.lookup(romURL: url, consoleType: consoleType), !dbEntry.name.isEmpty {
                desktop.name = dbEntry.name; desktop.publisher = dbEntry.publisher ?? "UNKNOWN"
                desktop.releaseDate = dbEntry.releaseDate ?? ""; desktop.players = dbEntry.players ?? 1
            } else {
                desktop.name = cleanTitle(url.deletingPathExtension().lastPathComponent)
                desktop.releaseDate = ""; desktop.publisher = "UNKNOWN"; desktop.players = 1
            }
            desktop.displayPublisher = desktop.publisher; desktop.addedAt = Date(); desktop.modifiedAt = desktop.addedAt
            desktop.defaultName = desktop.name
            desktop.exec = defaultExec(for: consoleType, rom: url.lastPathComponent, code: code)
            desktop.profilePath = "/var/saves"; desktop.iconPath = "/var/games"
            desktop.iconFilename = "\(code).png"; desktop.snesExtraFields = consoleType.isSNES
            let included = IncludedGameDuplicates.titleHint(title: desktop.name, console: consoleType, stock: stock)
            let match = included.map { IncludedGameDuplicate(importCode: code, importedTitle: desktop.name, builtInTitle: $0) }
            if let sourceDigest, BackupManifest.digest(try Data(contentsOf: url, options: .mappedIfSafe)) != sourceDigest {
                throw SyncPlanError.invalidInput("\(url.lastPathComponent) changed while it was being checked. Add it again when it is no longer changing.")
            }
            candidates.append(.init(url: url, desktopData: desktop.toData(), match: match, sourceDigest: sourceDigest))
        }
        return .init(candidates: candidates, skippedLocal: skippedLocal)
    }

    /// Review the complete source set while the current library and choices still exist.
    private func withReviewedROMImport<T>(urls: [URL], consoleType: ConsoleType, replacing: Bool,
        reviewIncluded: ([IncludedGameDuplicate]) -> IncludedGameImportChoice,
        perform: ([ROMImportCandidate], IncludedGameImportChoice, Int, URL) throws -> T) throws -> T {
        guard !isInspectingLegacy else { throw SyncPlanError.invalidInput("Disconnect legacy inspection before adding local games.") }
        try ROMImportPolicy.validate(urls, for: consoleType)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftHakchiImport-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURLs = try ROMArchiveImporter.materialize(urls, for: consoleType, in: temporaryDirectory)
        let gamesDir = config.gamesDirectory
        let stock = knownIncludedGames.filter { $0.consoleType == consoleType }
        let existingCodes = Set(games.map(\.code))
        let seen = replacing ? Set(games.filter { $0.source != .local }.map(\.code)) : existingCodes
        let plan = try Self.prepareImport(sourceURLs, consoleType: consoleType, stock: stock, seen: seen)
        let candidates = plan.candidates
        let matches = candidates.compactMap(\.match)
        let choice = matches.isEmpty ? .keepCopies : reviewIncluded(matches)
        guard choice != .cancel else { throw CancellationError() }
        // A modal review can run the event loop. Never commit into a switched library.
        guard !isInspectingLegacy, gamesDir == config.gamesDirectory,
              Set(games.map(\.code)) == existingCodes else { throw LegacyInspectionError.busy }
        return try perform(candidates, choice, plan.skippedLocal, gamesDir)
    }

    private func commitROMImport(_ candidates: [ROMImportCandidate], choice: IncludedGameImportChoice,
                                 skippedLocal: Int, gamesDir: URL, consoleType: ConsoleType) throws -> ROMImportSummary {
        var added = 0, skippedIncluded = 0, keptIncluded = 0
        for candidate in candidates {
            if candidate.match != nil && choice == .skipMatches { skippedIncluded += 1; continue }
            let desktop = candidate.desktop, code = desktop.code
            let gameDir = gamesDir.appendingPathComponent(code)
            try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: candidate.url, to: gameDir.appendingPathComponent(candidate.url.lastPathComponent))
            try candidate.desktopData.write(to: gameDir.appendingPathComponent(code + ".desktop"))
            var game = Game(desktopFile: desktop, consoleType: consoleType, basePath: gamesDir.path, source: .local)
            if candidate.match != nil { game.isSelected = false; keptIncluded += 1 }
            games.append(game); added += 1
        }
        games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        return ROMImportSummary(added: added, skippedLocal: skippedLocal, skippedIncluded: skippedIncluded, keptIncluded: keptIncluded)
    }

    @discardableResult
    func importROMs(urls: [URL], consoleType: ConsoleType,
                    reviewIncluded: ([IncludedGameDuplicate]) -> IncludedGameImportChoice = { _ in .keepCopies }) throws -> ROMImportSummary {
        try withReviewedROMImport(urls: urls, consoleType: consoleType, replacing: false, reviewIncluded: reviewIncluded) {
            try commitROMImport($0, choice: $1, skippedLocal: $2, gamesDir: $3, consoleType: consoleType)
        }
    }

    /// Extract, inspect and copy on a worker. The duplicate choice and final
    /// same-volume moves happen on the main actor after rechecking the library.
    /// A failed or cancelled preparation never commits a game to the library.
    func importROMsResponsive(urls: [URL], consoleType: ConsoleType,
                              reviewIncluded: @MainActor ([IncludedGameDuplicate]) -> IncludedGameImportChoice,
                              forceUnselected: Bool = false,
                              progress: @escaping @Sendable (String, Double?) async -> Void) async throws -> ROMImportSummary {
        guard !isInspectingLegacy, !isLoading, consoleType == config.lastConsoleType else { throw LegacyInspectionError.busy }
        let gamesDir = config.gamesDirectory, existingCodes = Set(games.map(\.code))
        let stock = knownIncludedGames.filter { $0.consoleType == consoleType }
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftHakchiImport-" + UUID().uuidString, isDirectory: true)
        isLoading = true
        defer { isLoading = false; try? FileManager.default.removeItem(at: temporaryDirectory) }
        await progress("Checking your game files…", nil)
        let preparation = Task.detached(priority: .userInitiated) {
            let sources = try ROMArchiveImporter.materialize(urls, for: consoleType, in: temporaryDirectory)
            return try Self.prepareImport(sources, consoleType: consoleType, stock: stock, seen: existingCodes, verifySource: true)
        }
        let plan = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
        try Task.checkCancellation()
        guard !isInspectingLegacy, gamesDir == config.gamesDirectory, consoleType == config.lastConsoleType,
              Set(games.map(\.code)) == existingCodes else { throw LegacyInspectionError.busy }
        let matches = plan.candidates.compactMap(\.match)
        let choice = matches.isEmpty ? IncludedGameImportChoice.keepCopies : reviewIncluded(matches)
        guard choice != .cancel else { throw CancellationError() }
        try Task.checkCancellation()
        guard !isInspectingLegacy, gamesDir == config.gamesDirectory, consoleType == config.lastConsoleType,
              Set(games.map(\.code)) == existingCodes else { throw LegacyInspectionError.busy }
        let chosen = plan.candidates.filter { $0.match == nil || choice == .keepCopies }
        let skippedIncluded = plan.candidates.count - chosen.count
        let keptIncluded = chosen.filter { $0.match != nil }.count
        guard !chosen.isEmpty else {
            return ROMImportSummary(added: 0, skippedLocal: plan.skippedLocal, skippedIncluded: skippedIncluded, keptIncluded: 0)
        }
        try FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)
        let parent = try RestoreDirectory(gamesDir)
        let stagingURL = gamesDir.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        let staging = try RestoreDirectory(stagingURL)
        defer {
            if (try? parent.check()) != nil && (try? staging.check()) != nil {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }
        await progress("Copying game files to your Mac…", 0)
        let worker = Task.detached(priority: .userInitiated) {
            for (index, candidate) in chosen.enumerated() {
                try Task.checkCancellation()
                let code = candidate.desktop.code
                let directory = stagingURL.appendingPathComponent(code, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let copied = directory.appendingPathComponent(candidate.url.lastPathComponent)
                try FileManager.default.copyItem(at: candidate.url, to: copied)
                guard let expected = candidate.sourceDigest,
                      BackupManifest.digest(try Data(contentsOf: copied, options: .mappedIfSafe)) == expected else {
                    throw SyncPlanError.invalidInput("\(candidate.url.lastPathComponent) changed while it was being added. Your original file is unchanged by this app; try again when it is no longer changing.")
                }
                try candidate.desktopData.write(to: directory.appendingPathComponent(code + ".desktop"))
                await progress("Copying game files to your Mac…", Double(index + 1) / Double(chosen.count))
            }
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation(); try parent.check(); try staging.check()
        guard !isInspectingLegacy, gamesDir == config.gamesDirectory, consoleType == config.lastConsoleType,
              Set(games.map(\.code)) == existingCodes else { throw LegacyInspectionError.busy }
        var added: [Game] = []
        do {
            for candidate in chosen {
                let desktop = candidate.desktop, code = desktop.code
                try FileManager.default.moveItem(at: stagingURL.appendingPathComponent(code), to: gamesDir.appendingPathComponent(code))
                var game = Game(desktopFile: desktop, consoleType: consoleType, basePath: gamesDir.path, source: .local)
                if candidate.match != nil || forceUnselected { game.isSelected = false }
                added.append(game)
            }
        } catch {
            games.append(contentsOf: added)
            if !added.isEmpty {
                throw SyncPlanError.invalidInput("\(added.count) games were added before the import stopped. Review your Mac library before trying again. " + error.localizedDescription)
            }
            throw error
        }
        games.append(contentsOf: added)
        games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        return ROMImportSummary(added: added.count, skippedLocal: plan.skippedLocal, skippedIncluded: skippedIncluded, keptIncluded: keptIncluded)
    }

    /// Replace imports while retaining an untouched, recoverable Mac library.
    /// Only deterministic ROM matches inherit descriptive edits; launch commands
    /// and ROM filenames always come from the new import.
    @discardableResult
    func replaceLocalLibrary(urls: [URL], consoleType: ConsoleType, preservingEdits: Bool,
                             reviewIncluded: ([IncludedGameDuplicate]) -> IncludedGameImportChoice = { _ in .keepCopies }) throws -> URL {
        guard consoleType == config.lastConsoleType, !isInspectingLegacy, !isLoading else {
            throw LegacyInspectionError.busy
        }
        return try withReviewedROMImport(urls: urls, consoleType: consoleType, replacing: true, reviewIncluded: reviewIncluded) { candidates, choice, skippedLocal, gamesDir in
        let previousGames = games, previousProfile = currentProfile, previousError = selectionError
        let previous = games.filter { $0.source == .local }
        let wasRestoring = restoringSelection
        restoringSelection = true
        defer { restoringSelection = wasRestoring; persistSelections() }
        let archived = try archiveLocalLibrary()
        do {
            _ = try commitROMImport(candidates, choice: choice, skippedLocal: skippedLocal, gamesDir: gamesDir, consoleType: consoleType)
            if preservingEdits {
                for old in previous {
                    guard var replacement = games.first(where: { $0.code == old.code && $0.source == .local }) else { continue }
                    replacement.name = old.name; replacement.sortName = old.sortName
                    replacement.publisher = old.publisher; replacement.copyright = old.copyright
                    replacement.genre = old.genre; replacement.releaseDate = old.releaseDate
                    replacement.players = old.players; replacement.simultaneous = old.simultaneous
                    replacement.description = old.description
                    if let path = old.coverArtPath {
                        let source = archived.appendingPathComponent(old.code).appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                        if FileManager.default.fileExists(atPath: source.path) {
                            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
                            let destination = config.gamesDirectory.appendingPathComponent(old.code).appendingPathComponent(old.code + ".png")
                            try FileManager.default.copyItem(at: source, to: destination)
                            replacement.coverArtPath = destination.path
                            replacement.invalidateCoverCache()
                        }
                    }
                    guard saveGame(replacement) else { throw CocoaError(.fileWriteUnknown) }
                }
            }
            return archived
        } catch {
            // Keep even a partial replacement recoverable, then restore the old library.
            _ = try archiveLocalLibrary()
            try FileManager.default.removeItem(at: config.gamesDirectory) // newly created empty directory
            try FileManager.default.moveItem(at: archived, to: config.gamesDirectory)
            currentProfile = previousProfile; selectionError = previousError; games = previousGames
            throw error
        }
        }
    }

    // MARK: - Delete Games

    /// Delete a local game from the library (removes files from disk)
    func deleteGame(_ game: Game) {
        guard game.source == .local else { return }

        let gameDir = config.gamesDirectory.appendingPathComponent(game.code)
        try? FileManager.default.removeItem(at: gameDir)
        games.removeAll { $0.id == game.id }
        logger.info("Deleted game: \(game.code) (\(game.name))")
    }

    /// Delete multiple local games
    func deleteGames(_ gamesToDelete: [Game]) {
        for game in gamesToDelete {
            deleteGame(game)
        }
    }

    // MARK: - Purge Cover Art

    /// Removes imports from the current console library while keeping a recoverable
    /// Mac copy, including edited metadata and artwork. Original ROM folders are untouched.
    @discardableResult func archiveLocalLibrary() throws -> URL {
        guard !isInspectingLegacy, !isLoading else { throw LegacyInspectionError.busy }
        let source = config.gamesDirectory
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              source.resolvingSymlinksInPath().path == source.path else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let removed = config.workspace.library.appendingPathComponent("Removed Libraries", isDirectory: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        let destination = removed.appendingPathComponent(config.lastConsoleType.syncCode + "-" + UUID().uuidString,
                                                        isDirectory: true)
        try FileManager.default.moveItem(at: source, to: destination)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        games.removeAll { $0.source == .local }
        return destination
    }

    /// Delete all cached cover art and cover PNGs inside local game directories,
    /// then re-trigger downloads from the game database.
    func purgeCoverArt() {
        let fm = FileManager.default

        // 1. Delete covers cache directory (stock/console game covers)
        let cacheDir = AppConfig.configDirectory
            .appendingPathComponent("covers", isDirectory: true)
        if fm.fileExists(atPath: cacheDir.path) {
            try? fm.removeItem(at: cacheDir)
            logger.info("Purged covers cache directory")
        }

        // 2. Delete cover PNGs inside each local game directory
        let gamesDir = config.gamesDirectory
        for game in games where game.source == .local {
            let coverPath = gamesDir
                .appendingPathComponent(game.code)
                .appendingPathComponent("\(game.code).png")
            if fm.fileExists(atPath: coverPath.path) {
                try? fm.removeItem(at: coverPath)
            }
        }

        // 3. Clear all cached images from memory
        ImageCache.shared.purgeAll()

        // 4. Clear coverArtPath on all games so the UI shows placeholders
        for i in games.indices {
            games[i].coverArtPath = nil
        }

        logger.info("Cleared local covers; use Fill Missing Covers or Choose Artwork")

        // 5. Re-trigger downloads
        // Refilling is an explicit Fill Missing Covers action.
    }

    // MARK: - Purge All Local Data

    /// Delete all imported games, cached covers, and downloaded data.
    /// Stock/console games from the device are kept in memory but their cached covers are cleared.
    func purgeAllLocalData() {
        let fm = FileManager.default

        // 1. Delete entire games directory (all imported ROMs + .desktop files + covers)
        let gamesDir = config.gamesDirectory
        if fm.fileExists(atPath: gamesDir.path) {
            try? fm.removeItem(at: gamesDir)
            logger.info("Purged games directory")
        }

        // 2. Delete covers cache directory
        let cacheDir = AppConfig.configDirectory
            .appendingPathComponent("covers", isDirectory: true)
        if fm.fileExists(atPath: cacheDir.path) {
            try? fm.removeItem(at: cacheDir)
            logger.info("Purged covers cache directory")
        }

        // 3. Delete data cache directory
        let dataDir = config.dataDirectory
        if fm.fileExists(atPath: dataDir.path) {
            try? fm.removeItem(at: dataDir)
            logger.info("Purged data directory")
        }

        // 4. Clear image cache
        ImageCache.shared.purgeAll()

        // 5. Remove local games from the list, keep stock/console games
        games.removeAll { $0.source == .local }
        for i in games.indices {
            games[i].coverArtPath = nil
        }

        // 6. Clear cached installed codes since local games are gone
        config.installedGameCodes = []
        config.save()

        logger.info("Purged all local data")
    }

    /// Save a game's .desktop file back to disk
    @discardableResult
    func saveGame(_ game: Game) -> Bool {
        guard game.source == .local else { return false } // only save local games

        let gamesDir = config.gamesDirectory
        let gameDir = gamesDir.appendingPathComponent(game.code)
        let desktopPath = gameDir
            .appendingPathComponent(game.code)
            .appendingPathExtension("desktop")

        let desktop = DesktopFile()
        desktop.code = game.code
        desktop.name = game.name
        desktop.addedAt = game.addedAt
        desktop.modifiedAt = Date()
        desktop.defaultName = game.defaultName
        desktop.sortName = game.sortName
        desktop.publisher = game.publisher
        desktop.displayPublisher = game.publisher
        desktop.copyright = game.copyright
        desktop.genre = game.genre
        desktop.releaseDate = game.releaseDate
        desktop.players = game.players
        desktop.simultaneous = game.simultaneous
        desktop.description = game.description
        desktop.exec = game.commandLine
        desktop.saveCount = game.saveCount
        desktop.testId = game.testId
        desktop.snesExtraFields = game.consoleType.isSNES
        desktop.profilePath = "/var/saves"
        desktop.iconPath = "/var/games"
        desktop.iconFilename = "\(game.code).png"

        do {
            try desktop.toData().write(to: desktopPath, options: .atomic)
            if let index = games.firstIndex(where: { $0.code == game.code }) {
                games[index] = game
                games[index].modifiedAt = desktop.modifiedAt
            }
            return true
        } catch {
            logger.error("Could not save metadata: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Title Cleanup

    /// Clean a ROM filename into a presentable game title
    private nonisolated static func cleanTitle(_ filename: String) -> String {
        var title = filename

        // 1. Remove bracketed/parenthesized tags: [USA], [!], (Rev A), (U), etc.
        title = title.replacingOccurrences(
            of: #"\s*[\[\(][^\]\)]*[\]\)]"#,
            with: "",
            options: .regularExpression
        )

        // 2. Replace _ and - with spaces
        title = title.replacingOccurrences(of: "_", with: " ")
        title = title.replacingOccurrences(of: "-", with: " ")

        // 3. Collapse multiple spaces and trim
        title = title.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        // 4. Title-case with special handling
        let romanNumerals: Set<String> = ["II", "III", "IV", "VI", "VII", "VIII", "IX", "XI", "XII"]
        let smallWords: Set<String> = ["a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "is", "by"]

        let words = title.components(separatedBy: " ")
        let titleCased = words.enumerated().map { index, word -> String in
            let upper = word.uppercased()
            if romanNumerals.contains(upper) {
                return upper
            }
            if index > 0 && smallWords.contains(word.lowercased()) {
                return word.lowercased()
            }
            if word.isEmpty { return word }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }

        return titleCased.joined(separator: " ")
    }

    // MARK: - Helpers

    /// Generate a deterministic CLV code from a CRC32, matching Hakchi2-CE's algorithm.
    /// Falls back to random if no CRC is available.
    private nonisolated static func generateCode(for consoleType: ConsoleType, crc32: UInt32? = nil) -> String {
        let prefixChar: Character
        switch consoleType {
        case .nes, .famicom: prefixChar = "H"
        case .snesUsa, .snesEur, .superFamicom, .superFamicomShonenJump: prefixChar = "U"
        default: prefixChar = "P"
        }

        let suffix: String
        if let crc = crc32 {
            // Deterministic: derive 5 letters from CRC32 bits (matches Hakchi2-CE)
            let c0 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + (crc % 26))!)
            let c1 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + ((crc >> 5) % 26))!)
            let c2 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + ((crc >> 10) % 26))!)
            let c3 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + ((crc >> 15) % 26))!)
            let c4 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + ((crc >> 20) % 26))!)
            suffix = String([c0, c1, c2, c3, c4])
        } else {
            // Fallback: random
            let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            suffix = (0..<5).map { _ in String(chars.randomElement()!) }.joined()
        }

        return "CLV-\(prefixChar)-\(suffix)"
    }

    private nonisolated static func defaultExec(for consoleType: ConsoleType, rom: String, code: String) -> String {
        let path = LaunchCommand.shellQuote("/var/games/\(code)/\(rom)")
        switch consoleType {
        case .nes, .famicom:
            return "/bin/clover-kachikachi-wr \(path) --volume 75 --rollback-snapshot-period 720"
        case .snesUsa, .snesEur, .superFamicom, .superFamicomShonenJump:
            return "/bin/clover-canoe-shvc-wr -rom \(path) --volume 75 --rollback-snapshot-period 720"
        case .megaDrive:
            return "/bin/m2engage \(path)"
        default:
            return "/bin/\(rom)"
        }
    }

    /// Online text lookup is explicit and has no mutation or image-download side effects.
    func searchMetadata(name: String, apiKey: String, platform: Int?) async throws -> [ScraperService.SearchResult] {
        try await metadataProvider.searchGames(name: name, apiKey: apiKey, platform: platform)
    }
}

// MARK: - Image Resizing

/// Resize image data to the given dimensions, outputting PNG.
/// Handles both PNG and JPEG input. Returns original data if resize fails.
func resizeCoverArt(data: Data, width: Int, height: Int) -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return data
    }

    // Skip if already at or below target size
    if cgImage.width <= width && cgImage.height <= height {
        // Still re-encode as PNG if input might be JPEG
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            output as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return data }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return data }
        return output as Data
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return data
    }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let resized = context.makeImage() else { return data }

    let output = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        output as CFMutableData, "public.png" as CFString, 1, nil
    ) else { return data }
    CGImageDestinationAddImage(dest, resized, nil)
    guard CGImageDestinationFinalize(dest) else { return data }
    return output as Data
}

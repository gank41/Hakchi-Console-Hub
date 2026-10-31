import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameDatabase")

/// Bundled game database for CRC32-based ROM identification.
/// Parses Hakchi2-CE's data files:
/// - snescarts.xml: SNES metadata + cover art URLs
/// - nescarts.xml: NES metadata (BootGod NesCartDB)
/// - romfiles.xml: CRC32 → TheGamesDB ID mapping (cover art for all platforms)
final class GameDatabase {
    static let shared = GameDatabase()

    struct Entry {
        let name: String
        let publisher: String?
        let releaseDate: String?
        let players: Int?
        let coverUrl: String?
        var region: String? = nil
        var regions: [String] = []
    }

    /// CRC32 hex string (uppercased) -> game metadata
    private var entries: [String: Entry] = [:]
    private var platformEntries: [String: [String: Entry]] = [:]
    private var metadataCandidates: Set<MetadataCandidate> = []

    /// CRC32 hex string (uppercased) -> TheGamesDB ID (from romfiles.xml)
    private var tgdbIds: [String: String] = [:]

    /// Normalized game name -> cover URL
    private var coverByName: [String: String] = [:]

    private static let tgdbCoverBase = "https://cdn.thegamesdb.net/images/original/boxart/front/"

    private init() {
        loadRomFilesDatabase()
        loadSNESDatabase()
        loadNESDatabase()
        loadGenesisDatabase()
        enrichEntriesWithCovers()
        buildNameIndex()
    }

    // MARK: - ROM Files Database (romfiles.xml — CRC32 → TGDB ID)

    private func loadRomFilesDatabase() {
        guard let url = Bundle.appBundle.url(forResource: "romfiles", withExtension: "xml"),
              let data = try? Data(contentsOf: url) else {
            logger.warning("romfiles.xml not found in bundle")
            return
        }

        let delegate = RomFilesParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.parse()

        tgdbIds = delegate.entries
        logger.info("Loaded romfiles.xml with \(self.tgdbIds.count) CRC32→TGDB mappings")
    }

    // MARK: - SNES Database (snescarts.xml)

    private func loadSNESDatabase() {
        guard let url = Bundle.appBundle.url(forResource: "snescarts", withExtension: "xml"),
              let data = try? Data(contentsOf: url) else {
            logger.warning("snescarts.xml not found in bundle")
            return
        }

        let delegate = SNESCartsParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.parse()

        for game in delegate.games {
            metadataCandidates.insert(MetadataCandidate(title: game.name, region: game.region, releaseDate: game.date,
                players: game.players.flatMap(Int.init), publisher: game.publisher, genre: nil, overview: nil, platform: "snes"))
            let key = game.crc.uppercased()
            entries[key] = Entry(
                name: game.name,
                publisher: game.publisher,
                releaseDate: game.date,
                players: game.players.flatMap { Int($0) },
                coverUrl: game.cover
            )
            platformEntries["snes", default: [:]][key] = entries[key]
        }
        logger.info("Loaded SNES database with \(delegate.games.count) entries")
    }

    // MARK: - NES Database (nescarts.xml - BootGod NesCartDB format)

    private func loadNESDatabase() {
        guard let url = Bundle.appBundle.url(forResource: "nescarts", withExtension: "xml"),
              let data = try? Data(contentsOf: url) else {
            logger.warning("nescarts.xml not found in bundle")
            return
        }

        let delegate = NESCartsParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.parse()

        for cart in delegate.cartridges where !cart.gameName.isEmpty {
            metadataCandidates.insert(MetadataCandidate(title: cart.gameName, region: cart.region, releaseDate: cart.date,
                players: cart.players.flatMap(Int.init), publisher: cart.publisher, genre: nil, overview: nil, platform: "nes"))
        }
        let groups = Dictionary(grouping: delegate.cartridges, by: { $0.crc.uppercased() })
        for (crc, carts) in groups {
            let names = Set(carts.map(\.gameName))
            let regions = Set(carts.compactMap(\.region)).sorted()
            let publishers = Set(carts.map { $0.publisher ?? "" })
            let dates = Set(carts.map { $0.date ?? "" })
            let players = Set(carts.map { $0.players ?? "" })
            entries[crc] = Entry(
                name: names.count == 1 ? names.first! : "",
                publisher: publishers.count == 1 ? publishers.first.flatMap { $0.isEmpty ? nil : $0 } : nil,
                releaseDate: dates.count == 1 ? dates.first.flatMap { $0.isEmpty ? nil : $0 } : nil,
                players: players.count == 1 ? players.first.flatMap(Int.init) : nil,
                coverUrl: nil, region: regions.count == 1 ? regions.first : nil, regions: regions)
            platformEntries["nes", default: [:]][crc] = entries[crc]
        }
        logger.info("Loaded NES database with \(groups.count) distinct cartridge CRCs; ambiguous fields retained as unknown")
    }

    // MARK: - Enrich entries with cover URLs from romfiles.xml

    /// For any entry without a cover URL, look up its TGDB ID in romfiles.xml
    /// and construct the CDN cover art URL.
    private func enrichEntriesWithCovers() {
        var enriched = 0
        var updatedEntries: [String: Entry] = [:]

        for (crc, entry) in entries {
            if entry.coverUrl == nil, let tgdbId = tgdbIds[crc] {
                updatedEntries[crc] = Entry(
                    name: entry.name,
                    publisher: entry.publisher,
                    releaseDate: entry.releaseDate,
                    players: entry.players,
                    coverUrl: "\(Self.tgdbCoverBase)\(tgdbId)-1.jpg", region: entry.region, regions: entry.regions
                )
                enriched += 1
            }
        }

        for (crc, entry) in updatedEntries {
            entries[crc] = entry
        }
        logger.info("Enriched \(enriched) entries with cover URLs from romfiles.xml")
    }

    // MARK: - Name -> Cover Index

    /// Build a name -> coverUrl index from all entries that have cover URLs.
    /// Stores all name variants (article repositioning) for flexible matching.
    private func buildNameIndex() {
        for entry in entries.values {
            if let url = entry.coverUrl {
                for variant in Self.nameVariants(entry.name) {
                    if coverByName[variant] == nil {
                        coverByName[variant] = url
                    }
                }
            }
        }
        logger.info("Built name index with \(self.coverByName.count) entries")
    }

    /// Normalize a name for fuzzy matching (lowercase, strip punctuation).
    /// Handles apostrophes between letters by replacing with space (e.g., "Ghosts'n" → "ghosts n").
    private static func normalize(_ name: String) -> String {
        var s = name.lowercased()
        // Replace apostrophes between letters with space (Ghosts'n → ghosts n)
        s = s.replacingOccurrences(of: #"(?<=\w)'(?=\w)"#, with: " ", options: .regularExpression)
        // Strip remaining non-word, non-space characters
        s = s.replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
        // Collapse whitespace
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Generate alternate name forms for matching (article repositioning).
    /// "The Legend of Zelda" → ["the legend of zelda", "legend of zelda the"]
    /// "Legend of Zelda, The" → ["legend of zelda the", "the legend of zelda"]
    private static func nameVariants(_ name: String) -> [String] {
        let base = normalize(name)
        var variants = [base]

        // Move leading article to end: "the foo bar" → "foo bar the"
        for article in ["the ", "a "] {
            if base.hasPrefix(article) {
                let rest = String(base.dropFirst(article.count))
                variants.append("\(rest) \(article.trimmingCharacters(in: .whitespaces))")
            }
        }

        // Move trailing article to front: "foo bar the" → "the foo bar"
        for article in [" the", " a"] {
            if base.hasSuffix(article) {
                let rest = String(base.dropLast(article.count))
                variants.append("\(article.trimmingCharacters(in: .whitespaces)) \(rest)")
            }
        }

        return variants
    }

    /// Punctuation-insensitive, platform-scoped candidate search, entirely offline.
    func search(name: String, consoleType: ConsoleType) -> [MetadataCandidate] {
        func key(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        let query = key(name)
        guard !query.isEmpty, let family = ArtworkPlatform(console: consoleType) else { return [] }
        let platform = family.rawValue
        return metadataCandidates.filter { $0.platform == platform && key($0.title).contains(query) }.sorted {
            let left = [$0.title, $0.region ?? "", $0.releaseDate ?? "", $0.id]
            let right = [$1.title, $1.region ?? "", $1.releaseDate ?? "", $1.id]
            return left.lexicographicallyPrecedes(right)
        }
    }

    /// Platform-scoped identification keeps a Genesis CRC from selecting Nintendo metadata.
    func lookup(romURL: URL, consoleType: ConsoleType) -> Entry? {
        guard let family = ArtworkPlatform(console: consoleType),
              let crc = CRC32.romChecksum(file: romURL) else { return nil }
        return platformEntries[family.rawValue]?[String(format: "%08X", crc)]
    }

    private struct GenesisCatalog: Decodable {
        struct Record: Decodable {
            let crc32: String, title: String
            let region: String?, releaseDate: String?, publisher: String?, players: Int?
        }
        let version: Int, platform: String, records: [Record]
    }
    private func loadGenesisDatabase() {
        guard let url = Bundle.appBundle.url(forResource: "genesis-metadata-v1", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024,
              let catalog = try? JSONDecoder().decode(GenesisCatalog.self, from: data),
              catalog.version == 1, catalog.platform == "genesis", catalog.records.count <= 10000,
              catalog.records.allSatisfy({ !$0.title.isEmpty && $0.title.utf8.count <= 512 &&
                  $0.crc32.range(of: #"^[0-9A-F]{8}$"#, options: .regularExpression) != nil }) else {
            logger.warning("Genesis metadata catalog could not be loaded")
            return
        }
        for record in catalog.records {
            metadataCandidates.insert(.init(title: record.title, region: record.region,
                releaseDate: record.releaseDate, players: record.players, publisher: record.publisher,
                genre: nil, overview: nil, platform: "genesis"))
        }
        for (crc, records) in Dictionary(grouping: catalog.records, by: \.crc32) {
            func unique<T: Hashable>(_ values: [T]) -> T? { let set = Set(values); return set.count == 1 ? set.first : nil }
            let regions = Set(records.compactMap(\.region).flatMap { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }).subtracting(["Unknown"]).sorted()
            platformEntries["genesis", default: [:]][crc] = Entry(name: unique(records.map(\.title)) ?? "",
                publisher: unique(records.map { $0.publisher ?? "" }).flatMap { $0.isEmpty ? nil : $0 },
                releaseDate: unique(records.map { $0.releaseDate ?? "" }).flatMap { $0.isEmpty ? nil : $0 },
                players: unique(records.map { $0.players ?? 0 }).flatMap { $0 == 0 ? nil : $0 }, coverUrl: nil,
                region: regions.count == 1 ? regions.first : nil, regions: regions)
        }
    }

    // MARK: - TGDB ID Lookups

    /// Look up a TheGamesDB ID by CRC32 hex string
    func tgdbId(forCRC32 crc32: String) -> Int? {
        guard let idStr = tgdbIds[crc32.uppercased()] else { return nil }
        return Int(idStr)
    }

    /// Look up a TheGamesDB ID by computing a ROM file's CRC32
    func tgdbId(forROM url: URL) -> Int? {
        guard let crc = CRC32.romChecksum(file: url) else { return nil }
        return tgdbId(forCRC32: String(format: "%08X", crc))
    }

    // MARK: - Lookups

    /// Look up a ROM by its CRC32 checksum
    func lookup(crc32: String) -> Entry? {
        let key = crc32.uppercased()
        if let entry = entries[key] { return entry }

        // Not in NES/SNES metadata DBs — check romfiles.xml for TGDB ID only
        if let tgdbId = tgdbIds[key] {
            return Entry(
                name: "",
                publisher: nil,
                releaseDate: nil,
                players: nil,
                coverUrl: "\(Self.tgdbCoverBase)\(tgdbId)-1.jpg"
            )
        }
        return nil
    }

    /// Look up a ROM file by computing its CRC32 (with header stripping for NES/SNES)
    func lookup(romURL: URL) -> Entry? {
        guard let crc = CRC32.romChecksum(file: romURL) else { return nil }
        let hex = String(format: "%08X", crc)
        return lookup(crc32: hex)
    }

    /// Look up a cover art URL by game name (fuzzy match).
    /// Tries exact normalized match, article variants, and progressive word trimming
    /// (e.g., "Punch-Out!! Featuring Mr. Dream" → "punchout" after trimming).
    func coverURL(forName name: String) -> String? {
        // Try all variants of the input name
        for variant in Self.nameVariants(name) {
            if let url = coverByName[variant] { return url }
        }

        // Progressive word trimming: try removing words from the end
        // Handles subtitle mismatches (e.g., "Punch-Out!! Featuring Mr. Dream" → "Punch-Out!!")
        let words = Self.normalize(name).split(separator: " ")
        if words.count > 1 {
            for length in stride(from: words.count - 1, through: 1, by: -1) {
                let partial = words.prefix(length).joined(separator: " ")
                if let url = coverByName[partial] { return url }
            }
        }

        return nil
    }
}

// MARK: - ROM Files XML Parser

/// Parses romfiles.xml: <romfiles><file crc32="..."><tgdb>ID</tgdb></file>...</romfiles>
private class RomFilesParserDelegate: NSObject, XMLParserDelegate {
    /// CRC32 (uppercased) -> first TGDB ID
    var entries: [String: String] = [:]
    private var currentCrc: String?
    private var currentText: String = ""
    private var hasId = false  // only take first <tgdb> per file

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "file" {
            currentCrc = attributes["crc32"]?.uppercased()
            hasId = false
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == "tgdb", !hasId, let crc = currentCrc {
            let id = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty {
                entries[crc] = id
                hasId = true
            }
        }
    }
}

// MARK: - SNES XML Parser

/// Parses snescarts.xml format:
/// <Data><Game><name/><crc/><cover/><publisher/><date/><players/></Game>...</Data>
private class SNESCartsParserDelegate: NSObject, XMLParserDelegate {
    struct GameEntry {
        var name: String = ""
        var crc: String = ""
        var publisher: String?
        var date: String?
        var players: String?
        var cover: String?
        var region: String?
    }

    var games: [GameEntry] = []
    private var currentGame: GameEntry?
    private var currentText: String = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "Game" {
            currentGame = GameEntry()
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        guard currentGame != nil else { return }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "name": currentGame?.name = text
        case "crc": currentGame?.crc = text
        case "publisher": currentGame?.publisher = text.isEmpty ? nil : text
        case "date": currentGame?.date = text.isEmpty ? nil : text
        case "players": currentGame?.players = text.isEmpty ? nil : text
        case "region": currentGame?.region = text.isEmpty ? nil : text
        case "cover": currentGame?.cover = text.isEmpty ? nil : text
        case "Game":
            if let game = currentGame, !game.crc.isEmpty, !game.name.isEmpty {
                games.append(game)
            }
            currentGame = nil
        default: break
        }
    }
}

// MARK: - NES XML Parser

/// Parses nescarts.xml (BootGod NesCartDB format):
/// <database><game name="..." publisher="..." players="..." date="...">
///   <cartridge crc="..." system="NES-NTSC"/>
/// </game></database>
private class NESCartsParserDelegate: NSObject, XMLParserDelegate {
    struct CartridgeEntry {
        let gameName: String
        let publisher: String?
        let date: String?
        let players: String?
        let crc: String
        let region: String?
    }

    var cartridges: [CartridgeEntry] = []
    private var currentGameName: String = ""
    private var currentPublisher: String?
    private var currentDate: String?
    private var currentPlayers: String?
    private var currentRegion: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "game" {
            currentGameName = attributes["name"] ?? ""
            currentPublisher = attributes["publisher"]
            currentDate = attributes["date"]
            currentPlayers = attributes["players"]
            currentRegion = attributes["region"]
        } else if elementName == "cartridge" {
            if let crc = attributes["crc"], !crc.isEmpty {
                cartridges.append(CartridgeEntry(
                    gameName: currentGameName,
                    publisher: currentPublisher,
                    date: currentDate,
                    players: currentPlayers,
                    crc: crc, region: currentRegion
                ))
            }
        }
    }
}

import Foundation

struct GameGenieCatalog: Codable, Sendable {
    let version: Int
    let system: String
    let workbookSHA256: String
    let workbookName: String
    let rows: [Row]
    struct Row: Codable, Identifiable, Hashable, Sendable {
        let row: Int
        let game: String
        let number: String?
        let rawCodes: String
        let effect: String?
        let source: String?
        var id: Int { row }
        var validCodes: [String]? {
            guard let effect, !effect.isEmpty else { return nil }
            let codes = rawCodes.uppercased().components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !codes.isEmpty, codes.count <= 32, codes.allSatisfy({ GameGenieNES.decode($0) != nil }) else { return nil }
            return codes
        }
    }
    enum CatalogError: LocalizedError {
        case invalid, reviewRequired
        var errorDescription: String? {
            switch self {
            case .invalid: return "This is not a supported NES catalog. Import the JSON produced by convert-game-genie-workbook.py."
            case .reviewRequired: return "This row contains alternatives or an unrecognized code. Review its original codes and notes; do not enable every alternative together."
            }
        }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024 else { throw CatalogError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.system == "nes", value.workbookSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !value.workbookName.isEmpty, value.workbookName.count <= 256, value.rows.count <= 20_000,
              Set(value.rows.map(\.row)).count == value.rows.count else { throw CatalogError.invalid }
        for row in value.rows {
            guard row.row >= 4, row.row <= 100_000, !row.game.isEmpty, row.game.count <= 256,
                  row.rawCodes.count <= 8192, (row.effect?.count ?? 0) <= 512,
                  (row.source?.count ?? 0) <= 8192, (row.number?.count ?? 0) <= 64 else { throw CatalogError.invalid }
        }
        return value
    }
    func searchGames(_ text: String) -> [String] {
        func key(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        let query = key(text)
        return Set(rows.map(\.game)).filter { query.isEmpty || key($0).contains(query) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func entries(game: String) -> [Row] { rows.filter { $0.game == game && !($0.effect ?? "").isEmpty }.sorted { $0.row < $1.row } }
    func notes(game: String) -> [String] { rows.filter { $0.game == game && ($0.effect ?? "").isEmpty && !$0.rawCodes.isEmpty }.map(\.rawCodes) }
    func effect(from row: Row) throws -> GameGenieEffect {
        guard rows.contains(row), let codes = row.validCodes, let name = row.effect else { throw CatalogError.reviewRequired }
        return GameGenieEffect(name: name, codes: codes, enabled: false,
            source: "\(workbookName) · SHA256 \(workbookSHA256) · NES row\(row.row) · code \(row.number ?? "?") · \(row.source ?? "Source unspecified")",
            notes: notes(game: row.game))
    }
}

/// The catalog is local user data, never a game payload or bundled public resource.
enum GameGenieCatalogStore {
    static func location(workspace: URL, create: Bool) throws -> URL? {
        var current = workspace
        for component in ["", "Library", "Cheats"] {
            if !component.isEmpty { current.appendPathComponent(component, isDirectory: true) }
            let values = try? current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { throw GameGenieError.unsafeDestination }
            if !FileManager.default.fileExists(atPath: current.path) {
                guard create else { return nil }
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            let checked = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard checked.isDirectory == true, checked.isSymbolicLink != true else { throw GameGenieError.unsafeDestination }
        }
        return current.appendingPathComponent("catalog-nes.json")
    }
    static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw GameGenieCatalog.CatalogError.invalid }
        return try Data(contentsOf: url)
    }
    static func load(workspace: URL) throws -> GameGenieCatalog? {
        guard let url = try location(workspace: workspace, create: false), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try GameGenieCatalog.decode(read(url))
    }
    static func install(data: Data, workspace: URL) throws -> GameGenieCatalog {
        let catalog = try GameGenieCatalog.decode(data)
        guard let url = try location(workspace: workspace, create: true) else { throw GameGenieError.unsafeDestination }
        if FileManager.default.fileExists(atPath: url.path) { _ = try read(url) }
        try data.write(to: url, options: .atomic)
        return catalog
    }
}

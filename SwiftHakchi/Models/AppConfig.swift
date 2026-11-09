import Foundation
import SwiftHakchiCore

/// User settings, persisted as JSON in Application Support
final class AppConfig: ObservableObject, Codable {
    static let shared = AppConfig.load()
    static var defaultWorkspace: URL {
        if let override = ProcessInfo.processInfo.environment["SWIFTHAKCHI_WORKSPACE"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Development/NES", isDirectory: true)
    }
    @Published var appIconID: String = "pow-block"
    @Published var workspacePath: String = AppConfig.defaultWorkspace.path
    @Published var backupDirectoryPath: String?
    @Published var previousBackupDirectoryPaths: [String] = []
    @Published var automaticallyCreateMissingBackup: Bool = true
    @Published var showBackupExplanation: Bool = true

    var workspace: WorkspacePaths {
        WorkspacePaths(root: URL(fileURLWithPath: workspacePath, isDirectory: true),
            activeBackups: backupDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
            previousBackups: previousBackupDirectoryPaths.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    func setWorkspace(_ selected: URL) {
        let oldBackups = workspace.backups.path
        workspacePath = selected.standardizedFileURL.path
        if backupDirectoryPath == nil, oldBackups != workspace.backups.path,
           !previousBackupDirectoryPaths.contains(oldBackups) {
            previousBackupDirectoryPaths.append(oldBackups)
        }
    }

    func setBackupDirectory(_ selected: URL) throws {
        guard selected.isFileURL else { throw CocoaError(.fileReadInvalidFileName) }
        let normalized = selected.standardizedFileURL
        let values = try normalized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              normalized.resolvingSymlinksInPath() == normalized,
              FileManager.default.isWritableFile(atPath: normalized.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let old = workspace.backups
        if old.path != normalized.path {
            if !previousBackupDirectoryPaths.contains(old.path) {
                previousBackupDirectoryPaths.append(old.path)
            }
            previousBackupDirectoryPaths.removeAll { $0 == normalized.path }
        }
        backupDirectoryPath = normalized.path
    }


    @Published var consoleMenuLimit: ConsoleMenuLimit = .thirty
    @Published private(set) var structureByConsole: [String: ConsoleStructure] = [:]
    @Published private(set) var structureLoadIssue: String?
    @Published var libraryOrder: LibraryOrder = .nameAscending
    @Published var lastConsoleType: ConsoleType = .nes
    @Published var lastDeviceId: String = ""
    @Published var installedGameCodes: [String] = []
    @Published var separateGameStorage: Bool = false
    @Published var forceNetwork: Bool = false
    @Published var uploadCompressed: Bool = true
    @Published var exportLinked: Bool = false
    @Published var maxGameSize: Int = 300  // MB
    @Published var theGamesDbApiKey: String = ""
    @Published var modRepositoryURLs: [String] = ["https://hakchi.net/KMFDManic/NESC-SNESC-Modifications/.repo/"]

    enum CodingKeys: String, CodingKey {
        case libraryOrder, consoleMenuLimit, structureByConsole
        case workspacePath, backupDirectoryPath, previousBackupDirectoryPaths
        case automaticallyCreateMissingBackup, showBackupExplanation, appIconID
        case lastConsoleType, lastDeviceId, installedGameCodes, separateGameStorage, forceNetwork
        case uploadCompressed, exportLinked, maxGameSize
        case theGamesDbApiKey, modRepositoryURLs
    }

    init() {
        structureByConsole = Self.defaultStructures(limit: .thirty)
    }

    private static func defaultStructures(limit: ConsoleMenuLimit) -> [String: ConsoleStructure] {
        Dictionary(uniqueKeysWithValues: ConsoleType.allCases.filter { $0 != .unknown }.map {
            ($0.syncCode, ConsoleStructure(maximumGamesPerPage: limit))
        })
    }

    func structure(for console: ConsoleType) -> ConsoleStructure {
        structureByConsole[console.syncCode] ?? ConsoleStructure(maximumGamesPerPage: consoleMenuLimit)
    }

    func setStructure(_ structure: ConsoleStructure, for console: ConsoleType) throws {
        guard console != .unknown else {
            throw ConsoleStructureError.invalidSetting("Choose a supported console first.")
        }
        try structure.validate()
        structureByConsole[console.syncCode] = structure
        structureLoadIssue = nil
        if console == .nes { consoleMenuLimit = structure.maximumGamesPerPage }
    }

    func updateLegacyMenuLimit(_ limit: ConsoleMenuLimit) throws {
        guard structureLoadIssue == nil else {
            throw ConsoleStructureError.invalidSetting("Open Console Structure and review the recovered layout first.")
        }
        var structure = structure(for: .nes)
        structure.maximumGamesPerPage = limit
        try setStructure(structure, for: .nes)
    }

    func copyStructure(from source: ConsoleType, to destinations: [ConsoleType]) throws {
        guard source != .unknown, destinations.allSatisfy({ $0 != .unknown }) else {
            throw ConsoleStructureError.invalidSetting("Choose supported consoles first.")
        }
        let value = structure(for: source)
        try value.validate()
        for destination in destinations { try setStructure(value, for: destination) }
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        consoleMenuLimit = ConsoleMenuLimit(rawValue: (try? container.decode(Int.self, forKey: .consoleMenuLimit)) ?? 30) ?? .thirty
        structureByConsole = try container.decodeIfPresent([String: ConsoleStructure].self, forKey: .structureByConsole)
            ?? Self.defaultStructures(limit: consoleMenuLimit)
        guard structureByConsole.keys.allSatisfy({ key in ConsoleType.allCases.contains(where: { $0 != .unknown && $0.syncCode == key }) }) else {
            throw ConsoleStructureError.invalidSetting("An unknown console has saved structure settings.")
        }
        libraryOrder = try container.decodeIfPresent(LibraryOrder.self, forKey: .libraryOrder) ?? .nameAscending
        appIconID = AppIconCatalog.canonicalID(try? container.decode(String.self, forKey: .appIconID))
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath) ?? Self.defaultWorkspace.path
        backupDirectoryPath = try container.decodeIfPresent(String.self, forKey: .backupDirectoryPath)
        previousBackupDirectoryPaths = try container.decodeIfPresent([String].self, forKey: .previousBackupDirectoryPaths) ?? []
        automaticallyCreateMissingBackup = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCreateMissingBackup) ?? true
        showBackupExplanation = try container.decodeIfPresent(Bool.self, forKey: .showBackupExplanation) ?? true
        lastConsoleType = try container.decodeIfPresent(ConsoleType.self, forKey: .lastConsoleType) ?? .nes
        lastDeviceId = try container.decodeIfPresent(String.self, forKey: .lastDeviceId) ?? ""
        installedGameCodes = try container.decodeIfPresent([String].self, forKey: .installedGameCodes) ?? []
        separateGameStorage = try container.decodeIfPresent(Bool.self, forKey: .separateGameStorage) ?? false
        forceNetwork = try container.decodeIfPresent(Bool.self, forKey: .forceNetwork) ?? false
        uploadCompressed = try container.decodeIfPresent(Bool.self, forKey: .uploadCompressed) ?? true
        exportLinked = try container.decodeIfPresent(Bool.self, forKey: .exportLinked) ?? false
        maxGameSize = try container.decodeIfPresent(Int.self, forKey: .maxGameSize) ?? 300
        theGamesDbApiKey = try container.decodeIfPresent(String.self, forKey: .theGamesDbApiKey) ?? ""
        modRepositoryURLs = try container.decodeIfPresent([String].self, forKey: .modRepositoryURLs)
            ?? ["https://hakchi.net/KMFDManic/NESC-SNESC-Modifications/.repo/"]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(consoleMenuLimit, forKey: .consoleMenuLimit)
        try container.encode(structureByConsole, forKey: .structureByConsole)
        try container.encode(libraryOrder, forKey: .libraryOrder)
        try container.encode(AppIconCatalog.canonicalID(appIconID), forKey: .appIconID)
        try container.encode(workspacePath, forKey: .workspacePath)
        try container.encodeIfPresent(backupDirectoryPath, forKey: .backupDirectoryPath)
        try container.encode(previousBackupDirectoryPaths, forKey: .previousBackupDirectoryPaths)
        try container.encode(automaticallyCreateMissingBackup, forKey: .automaticallyCreateMissingBackup)
        try container.encode(showBackupExplanation, forKey: .showBackupExplanation)
        try container.encode(lastConsoleType, forKey: .lastConsoleType)
        try container.encode(lastDeviceId, forKey: .lastDeviceId)
        try container.encode(installedGameCodes, forKey: .installedGameCodes)
        try container.encode(separateGameStorage, forKey: .separateGameStorage)
        try container.encode(forceNetwork, forKey: .forceNetwork)
        try container.encode(uploadCompressed, forKey: .uploadCompressed)
        try container.encode(exportLinked, forKey: .exportLinked)
        try container.encode(maxGameSize, forKey: .maxGameSize)
        try container.encode(theGamesDbApiKey, forKey: .theGamesDbApiKey)
        try container.encode(modRepositoryURLs, forKey: .modRepositoryURLs)
    }

    // MARK: - Persistence

    static var configDirectory: URL {
        defaultWorkspace.appendingPathComponent("Library", isDirectory: true)
    }

    static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        load(from: configFile)
    }

    static func load(from file: URL) -> AppConfig {
        guard FileManager.default.fileExists(atPath: file.path) else { return AppConfig() }
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // Retain other preferences when only a newer Structure payload is unreadable.
            let recovered: AppConfig? = {
                guard let data = try? Data(contentsOf: file),
                      var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      fields.removeValue(forKey: "structureByConsole") != nil,
                      let remainder = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
                return try? JSONDecoder().decode(AppConfig.self, from: remainder)
            }()
            let config = recovered ?? AppConfig()
            config.structureLoadIssue = "Saved app settings could not be fully read. Review and save Console Structure before syncing. The existing settings file is preserved until then."
            return config
        }
    }

    func save() { save(to: Self.configFile) }

    func save(to file: URL) {
        guard structureLoadIssue == nil else { return }
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Base path for game data on disk
    var gamesDirectory: URL {
        workspace.gamesDirectory(systemCode: lastConsoleType == .unknown ? "nes-usa" : lastConsoleType.syncCode)
    }

    /// Path for downloaded data files
    var dataDirectory: URL {
        workspace.library.appendingPathComponent("Cache", isDirectory: true)
    }

    /// Path for kernel/dump backups
    var dumpDirectory: URL {
        workspace.backups
    }
}

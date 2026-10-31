import Foundation
import SwiftHakchiCore

enum ConsoleStructureError: Error, LocalizedError {
    case unsupportedVersion, invalidSetting(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "This console structure was saved by an unsupported app version. Review it before syncing."
        case .invalidSetting(let detail):
            return "The console structure needs review: " + detail
        }
    }
}

/// Saved organization choice. The planner validates the chosen game set separately.
struct ConsoleStructure: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case flat, custom, automatic, stockRootAutomatic
        case pagesEqual, stockRootPagesEqual
        case foldersEqual, stockRootFoldersEqual
        case foldersAlphabetical, stockRootFoldersAlphabetical
    }

    enum BackPosition: String, Codable, CaseIterable, Sendable { case top, bottom }
    enum FolderArt: String, Codable, CaseIterable, Sendable { case classic, letterTiles, custom }

    struct CustomFolderTree: Codable, Equatable, Sendable {
        struct Folder: Codable, Equatable, Sendable {
            var id: String
            var title: String
            var parentID: String?
            var gameCodes: [String]
            var artKey: String?
        }

        var rootGameCodes: [String]
        var folders: [Folder]
    }

    static let currentVersion = 1
    let version: Int
    var mode: Mode
    var maximumGamesPerPage: ConsoleMenuLimit
    var backPosition: BackPosition
    var folderArt: FolderArt
    var custom: CustomFolderTree?

    init(mode: Mode = .pagesEqual, maximumGamesPerPage: ConsoleMenuLimit = .thirty,
         backPosition: BackPosition = .bottom, folderArt: FolderArt = .classic,
         custom: CustomFolderTree? = nil) {
        self.version = Self.currentVersion
        self.mode = mode
        self.maximumGamesPerPage = maximumGamesPerPage
        self.backPosition = backPosition
        self.folderArt = folderArt
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey {
        case version, mode, maximumGamesPerPage, backPosition, folderArt, custom
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw ConsoleStructureError.unsupportedVersion }
        self.version = version
        mode = try values.decode(Mode.self, forKey: .mode)
        maximumGamesPerPage = try values.decode(ConsoleMenuLimit.self, forKey: .maximumGamesPerPage)
        backPosition = try values.decode(BackPosition.self, forKey: .backPosition)
        folderArt = try values.decode(FolderArt.self, forKey: .folderArt)
        custom = try values.decodeIfPresent(CustomFolderTree.self, forKey: .custom)
        try validate()
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw ConsoleStructureError.unsupportedVersion }
        guard (mode == .custom) == (custom != nil) else {
            throw ConsoleStructureError.invalidSetting("Custom folders must have a custom layout, and other modes must not carry one.")
        }
        if folderArt == .custom && custom == nil {
            throw ConsoleStructureError.invalidSetting("Choose custom folders before using custom folder artwork.")
        }
        guard let custom else { return }
        let ids = custom.folders.map(\.id)
        guard Set(ids).count == ids.count else {
            throw ConsoleStructureError.invalidSetting("Folder IDs must be unique.")
        }
        for folder in custom.folders {
            guard folder.id.range(of: #"^[A-Za-z0-9_-]{1,20}$"#, options: .regularExpression) != nil,
                  !folder.title.isEmpty, folder.title.utf8.count <= 64,
                  !folder.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  folder.parentID != folder.id,
                  folder.parentID == nil || ids.contains(folder.parentID!),
                  folder.artKey == nil || Self.safeArtKey(folder.artKey!) else {
                throw ConsoleStructureError.invalidSetting("A custom folder has an unsafe name, ID, parent, or image reference.")
            }
        }
        let codes = custom.rootGameCodes + custom.folders.flatMap(\.gameCodes)
        guard codes.allSatisfy(SyncPlanner.validCode), Set(codes).count == codes.count else {
            throw ConsoleStructureError.invalidSetting("A custom layout contains an invalid or repeated game.")
        }
    }

    private static func safeArtKey(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}\.png$"#, options: .regularExpression) != nil
            && !value.contains("..")
    }
}

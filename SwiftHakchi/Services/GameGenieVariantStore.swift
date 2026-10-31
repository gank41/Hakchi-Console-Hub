import Foundation
import CryptoKit
import Darwin
import SwiftHakchiCore

/// Called only by the explicit Create/Update action; profile editing never calls this store.
@MainActor enum GameGenieVariantStore {
    struct Binding: Codable {
        let version: Int
        let sourceCode: String
        let sourceSHA256: String
        let outputSHA256: String
        let profile: GameGenieProfile
    }
    static let bindingFilename = "game-genie.json"

    static func artwork(system: GameGenieSystem = .nes) throws -> Data {
        let console: String
        switch system {
        case .nes: console = "NES"
        case .snes: console = "SNES"
        case .genesis: console = "Genesis"
        }
        let name = "CheatCode-" + console
        guard let url = Bundle.module.url(forResource: name,
                                          withExtension: "png", subdirectory: "CheatCodes") else {
            throw SyncPlanError.missingFile("Cheat Codes artwork")
        }
        let bytes = try Data(contentsOf: url)
        _ = try GameArtworkStore.png(from: bytes)
        return bytes
    }
    private static let legacyTitleSuffixes = [" [Game Genie]", " [Cheat Codes]"]
    /// Presentation only: old managed-copy metadata stays untouched until an explicit update.
    static func hasLegacyTitle(_ desktop: DesktopFile) -> Bool {
        [desktop.name, desktop.defaultName, desktop.sortName].compactMap { $0 }.contains { value in legacyTitleSuffixes.contains(where: value.hasSuffix) }
    }
    static func relabelLegacyTitle(_ desktop: DesktopFile) {
        func title(_ value: String) -> String {
            guard let old = legacyTitleSuffixes.first(where: value.hasSuffix) else { return value }
            return String(value.dropLast(old.count)) + " [Cheat Code]"
        }
        desktop.name = title(desktop.name)
        desktop.defaultName = desktop.defaultName.map(title)
        desktop.sortName = title(desktop.sortName)
    }
    static func code(for session: GameGenieSession) -> String {
        code(sourceCode: session.target.code, sha256: session.sha256)
    }
    private static func code(sourceCode: String, sha256: String) -> String {
        let seed = Data(("SwiftHakchi.GameGenie.v1:" + sourceCode + ":" + sha256).utf8)
        let hash = Array(SHA256.hash(data: seed))
        let prefix=sourceCode.hasPrefix("CLV-U-") ? "CLV-U-":sourceCode.hasPrefix("CLV-P-") ? "CLV-P-":"CLV-H-"
        return prefix + String(hash.prefix(5).map { Character(UnicodeScalar(65 + Int($0) % 26)!) })
    }
    static func binding(for game: Game, manager: GameManagerService) throws -> Binding? {
        let target = try GameArtworkTarget(game: game, gamesDirectory: AppConfig.shared.gamesDirectory)
        try manager.validateArtworkTarget(target)
        return try readBinding(game: game, target: target)
    }
    /// Intentional managed variants remain distinct in sync review, including an all-effects-off copy.
    static func isManagedCopy(_ game: Game) throws -> Bool {
        let folder = URL(fileURLWithPath: game.romPath, isDirectory: true)
        let sidecar = folder.appendingPathComponent(bindingFilename)
        let attributes = try? sidecar.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard FileManager.default.fileExists(atPath: sidecar.path) || attributes?.isSymbolicLink == true else { return false }
        let target = try GameArtworkTarget(game: game, gamesDirectory: folder.deletingLastPathComponent())
        return try readBinding(game: game, target: target) != nil
    }
    private static func readBinding(game: Game, target: GameArtworkTarget) throws -> Binding? {
        let url = target.folder.appendingPathComponent(bindingFilename)
        let attributes = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard FileManager.default.fileExists(atPath: url.path) || attributes?.isSymbolicLink == true else { return nil }
        let bytes = try ordinaryFile(url, maximum: GameGenieProfile.maximumStoredBytes + 4096)
        let binding = try JSONDecoder().decode(Binding.self, from: bytes)
        guard binding.version == 1, SyncPlanner.validCode(binding.sourceCode), binding.sourceCode != game.code,
              binding.sourceSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              code(sourceCode: binding.sourceCode, sha256: binding.sourceSHA256) == game.code else { throw GameGenieError.changedROM }
        try binding.profile.validate(sha256: binding.sourceSHA256)
        let allowed=ROMImportPolicy.extensions(for:game.consoleType)
        let roms=try FileManager.default.contentsOfDirectory(at:target.folder,includingPropertiesForKeys:nil).filter{allowed.contains($0.pathExtension.lowercased())}
        guard roms.count==1,let file=roms.first,file.deletingPathExtension().lastPathComponent==game.code,GameGenieSystem(console:game.consoleType)==binding.profile.codeSystem else {throw GameGenieError.changedROM}
        let rom = try ordinaryFile(file, maximum: 8 * 1024 * 1024)
        guard GameGenieWorkflow.digest(rom) == binding.outputSHA256 else { throw GameGenieError.changedROM }
        return binding
    }
    static func existing(session: GameGenieSession, manager: GameManagerService) throws -> Game? {
        _ = try session.source(manager: manager)
        let candidate = code(for: session)
        let folder = session.target.gamesDirectory.appendingPathComponent(candidate)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        guard let game = manager.games.first(where: { $0.code == candidate }),
              let binding = try binding(for: game, manager: manager), binding.sourceCode == session.target.code,
              binding.sourceSHA256 == session.sha256 else { throw GameGenieError.changedROM }
        return game
    }
    @discardableResult static func save(session: GameGenieSession, profile: GameGenieProfile,
                                       manager: GameManagerService) throws -> Game {
        let originalBytes = try session.source(manager: manager)
        try profile.validate(sha256: session.sha256)
        guard profile.codeSystem==session.system else {throw GameGenieError.invalidProfile}
        _ = try profile.encodedForStorage()
        let previous = try existing(session: session, manager: manager)
        let selections = Dictionary(uniqueKeysWithValues: manager.games.map { ($0.code, $0.isSelected) })
        guard previous != nil || !profile.enabledCodes.isEmpty else { throw GameGenieError.noCodes }
        guard let original = manager.games.first(where: { $0.code == session.target.code }) else { throw GameGenieError.changedROM }
        let output = profile.enabledCodes.isEmpty ? originalBytes : try GameGenieROMPatcher.patch(data:originalBytes,system:session.system,extension:session.romURL.pathExtension,codes:profile.enabledCodes).data
        let variantCode = code(for: session)
        let romName=variantCode+"."+session.romURL.pathExtension.lowercased()
        guard variantCode != original.code else { throw GameGenieError.unsafeDestination }
        let games = session.target.gamesDirectory
        try requireDirectory(games)
        let workspace = session.workspace.standardizedFileURL
        guard workspace == workspace.resolvingSymlinksInPath() else { throw GameGenieError.unsafeDestination }
        // Both locations stay outside Games so partial/old revisions never become extra library entries.
        let library = workspace.appendingPathComponent("Library")
        try requireDirectory(library)
        let revisions = library.appendingPathComponent("Game Genie Revisions")
        if !FileManager.default.fileExists(atPath: revisions.path) {
            try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: false)
        }
        try requireDirectory(revisions)
        let stage = revisions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var promoted = false
        defer { if !promoted { try? FileManager.default.removeItem(at: stage) } }

        let desktop: DesktopFile
        if let previous {
            desktop = DesktopFile(data: try ordinaryFile(URL(fileURLWithPath: previous.romPath).appendingPathComponent(variantCode + ".desktop"), maximum: 1024 * 1024))
        } else {
            desktop = SyncPlanAdapter.desktopFile(for: original)
            desktop.displayPublisher = original.publisher
            desktop.name = original.name + " [Cheat Code]"
            desktop.defaultName = desktop.name
            desktop.sortName = desktop.name
            desktop.addedAt = Date()
            let originalPath = try LaunchCommand.romPath(in: original.commandLine, filename: session.romURL.lastPathComponent)
            guard originalPath == "/var/games/\(original.code)/\(session.romURL.lastPathComponent)" else { throw SyncPlanError.unsafeCommand }
            desktop.exec = try LaunchCommand.replacingROM(in: original.commandLine, oldPath: originalPath,
                newPath: "/var/games/\(variantCode)/\(romName)")
        }
        relabelLegacyTitle(desktop)
        desktop.code = variantCode; desktop.modifiedAt = Date()
        guard try LaunchCommand.romPath(in: desktop.exec, filename: romName) == "/var/games/\(variantCode)/\(romName)" else { throw SyncPlanError.unsafeCommand }
        desktop.iconFilename = variantCode + ".png"; desktop.iconPath = "/var/games"; desktop.profilePath = "/var/saves"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = Binding(version: 1, sourceCode: original.code, sourceSHA256: session.sha256,
            outputSHA256: GameGenieWorkflow.digest(output), profile: profile)
        let bindingData = try encoder.encode(manifest)
        guard bindingData.count <= GameGenieProfile.maximumStoredBytes + 4096 else { throw GameGenieError.profileTooLarge }
        let files = [romName: output, variantCode + ".desktop": desktop.toData(),
                     variantCode + ".png": try artwork(system: session.system),
                     bindingFilename: bindingData]
        for (name, data) in files {
            let url = stage.appendingPathComponent(name)
            try data.write(to: url, options: .withoutOverwriting)
            guard try ordinaryFile(url, maximum: 8 * 1024 * 1024) == data else { throw GameGenieError.changedROM }
        }
        // Revalidate all owned inputs immediately before atomic publication.
        _ = try session.source(manager: manager)
        let fresh = try existing(session: session, manager: manager)
        guard fresh?.code == previous?.code else { throw GameGenieError.changedROM }
        try requireDirectory(games); try requireDirectory(revisions)
        try session.saveProfile(profile, manager: manager)
        let destination = games.appendingPathComponent(variantCode)
        let flags = previous == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw SyncPlanError.invalidInput("The Cheat Codes copy could not be saved. The previous library entry is preserved.")
        }
        promoted = true // On update the old directory is now stage, retained as a Mac revision.
        manager.loadGames()
        var refreshed = manager.games
        for index in refreshed.indices {
            if let selected = selections[refreshed[index].code] { refreshed[index].isSelected = selected }
            if refreshed[index].code == variantCode { refreshed[index].isSelected = previous?.isSelected ?? true }
        }
        manager.games = refreshed
        guard let result = manager.games.first(where: { $0.code == variantCode }) else { throw GameGenieError.changedROM }
        result.invalidateCoverCache()
        return result
    }
    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.standardizedFileURL == url.resolvingSymlinksInPath() else { throw GameGenieError.unsafeDestination }
    }
    private static func ordinaryFile(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= maximum else { throw GameGenieError.unsafeDestination }
        return try Data(contentsOf: url)
    }
}

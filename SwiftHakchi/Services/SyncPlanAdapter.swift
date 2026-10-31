import Foundation
import SwiftHakchiCore

@MainActor
enum SyncPlanAdapter {
    static func inputs(games: [Game]) throws -> [SyncGameInput] {
        try games.map { game in
            let directory = game.source == .local ? URL(fileURLWithPath: game.romPath, isDirectory: true) : nil
            var filename: String?
            var bytes: Int64 = 0
            if game.isSelected && !game.isStock {
                guard let directory else { throw SyncPlanError.missingFile("Import \(game.name) from the console before including it in a sync.") }
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
                let candidates = files.filter { ["nes", "fds", "sfrom", "sfc", "smc", "zip", "7z"].contains($0.pathExtension.lowercased()) }
                guard candidates.count == 1, let rom = candidates.first else { throw SyncPlanError.missingFile("\(game.name): expected one ROM file") }
                filename = rom.lastPathComponent
                _ = try LaunchCommand.romPath(in: game.commandLine, filename: rom.lastPathComponent)
                if ["zip", "7z", "sfc", "smc", "sfrom"].contains(rom.pathExtension.lowercased()), !game.commandLine.contains("retroarch") {
                    throw SyncPlanError.invalidInput("\(game.name) needs ROM conversion or an explicitly selected compatible emulator before syncing.")
                }
                guard let scan = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw SyncPlanError.missingFile(directory.path) }
                for case let url as URL in scan {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw SyncPlanError.invalidInput("Import linked files as ordinary local copies first.") }
                    if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
                }
            }
            if game.isSelected && game.isStock {
                let prefix = game.consoleType.originalGamesPath + "/" + game.code + "/"
                let candidates = try LaunchCommand.arguments(in: game.commandLine).dropFirst().filter { $0.hasPrefix(prefix) }
                guard candidates.count == 1, let path = candidates.first else { throw SyncPlanError.unsafeCommand }
                _ = try LaunchCommand.replacingROM(in: game.commandLine, oldPath: path, newPath: "/var/squashfs" + path)
            }
            let desktop = desktopFile(for: game)
            return SyncGameInput(code: game.code, name: game.name, isStock: game.isStock,
                localDirectory: directory, romFilename: filename, desktopData: desktop.toData(), selected: game.isSelected, byteCount: bytes, sortName: game.sortName)
        }
    }

    static func desktopFile(for game: Game) -> DesktopFile {
        let desktop = DesktopFile()
        desktop.code = game.code; desktop.name = game.name; desktop.sortName = game.sortName
        desktop.publisher = game.publisher; desktop.copyright = game.copyright; desktop.genre = game.genre
        desktop.releaseDate = game.releaseDate; desktop.players = game.players; desktop.simultaneous = game.simultaneous
        desktop.description = game.description; desktop.exec = game.commandLine; desktop.saveCount = game.saveCount
        desktop.testId = game.testId; desktop.snesExtraFields = game.consoleType.isSNES
        desktop.profilePath = "/var/saves"; desktop.iconPath = "/var/games"; desktop.iconFilename = game.code + ".png"
        return desktop
    }
}

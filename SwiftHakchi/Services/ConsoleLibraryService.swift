import Foundation
import SwiftHakchiCore

enum ConsoleLibraryService {
    static func read(inventory: DeviceInventory, shell: any ConsoleShell) async throws -> [Game] {
        guard let base = inventory.syncBase, inventory.consoleType != .unknown else { throw SyncPlanError.unsupportedConsole }
        var games: [Game] = []
        let stock = "/var/squashfs" + inventory.originalGamesPath
        let stockList = try await shell.executeChecked("ls -1 \(LaunchCommand.shellQuote(stock))")
        for code in stockList.output.split(whereSeparator: \.isNewline).map(String.init)
            where SyncPlanner.validCode(code) && !code.hasPrefix("CLV-S-") {
            let content = try await shell.executeChecked("cat \(LaunchCommand.shellQuote(stock + "/" + code + "/" + code + ".desktop"))").stdout
            games.append(try game(code: code, content: content, type: inventory.consoleType, source: .stock))
        }
        for code in inventory.installedCodes.sorted() {
            let direct = base + "/.storage/" + code + "/" + code + ".desktop"
            let result = try await shell.execute("cat \(LaunchCommand.shellQuote(direct))", timeout: 30_000)
            let content: String
            if result.succeeded, !result.stdout.isEmpty { content = result.stdout }
            else {
                let found = try await shell.executeChecked("find \(LaunchCommand.shellQuote(base)) -type f -name \(LaunchCommand.shellQuote(code + ".desktop"))")
                guard let path = found.output.split(whereSeparator: \.isNewline).first.map(String.init),
                      path.hasPrefix(base + "/"), !(path as NSString).pathComponents.contains(".."),
                      (path as NSString).lastPathComponent == code + ".desktop" else {
                    throw SyncPlanError.invalidInput("Installed game metadata is missing: \(code)")
                }
                content = try await shell.executeChecked("cat \(LaunchCommand.shellQuote(path))").stdout
            }
            games.append(try game(code: code, content: content, type: inventory.consoleType, source: .console))
        }
        for i in games.indices {
            games[i].isOnConsole = inventory.visibleCodes.contains(games[i].code)
        }
        return games
    }
    private static func game(code: String, content: String, type: ConsoleType, source: GameSource) throws -> Game {
        let metadata = DesktopFile(string: content)
        guard !metadata.exec.isEmpty, metadata.code.isEmpty || metadata.code == code else {
            throw SyncPlanError.invalidInput("Console game metadata could not be validated: \(code)")
        }
        return Game(code: code, desktopContent: content, consoleType: type, source: source)
    }
}

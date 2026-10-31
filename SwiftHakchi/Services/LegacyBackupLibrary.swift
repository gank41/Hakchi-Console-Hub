import Foundation
import SWCompression
import SwiftHakchiCore

/// Reads only metadata from an independently verified legacy backup for an offline preview.
enum LegacyBackupLibrary {
    static func stockROMHashes(_ directory: URL) throws -> [String: String] {
        let stockCodes = try read(directory).report.stockCodes
        let entries = try TarContainer.open(container: Data(contentsOf: directory.appendingPathComponent("console.tar")))
        let prefix = String(LegacyConsoleReport.factoryRoot.dropFirst()) + "/"
        var hashes: [String: String] = [:]
        for entry in entries where entry.info.type == .regular && entry.info.name.hasPrefix(prefix) {
            let path = String(entry.info.name.dropFirst(prefix.count)).split(separator: "/").map(String.init)
            guard path.count == 2, stockCodes.contains(path[0]), path[1] == path[0] + ".nes" else { continue }
            guard let bytes = entry.data, !bytes.isEmpty, bytes.count <= 4 * 1024 * 1024,
                  hashes.updateValue(BackupManifest.digest(bytes), forKey: path[0]) == nil else {
                throw LegacyInspectionError.invalidBackup
            }
        }
        guard Set(hashes.keys) == stockCodes else { throw LegacyInspectionError.invalidBackup }
        return hashes
    }

    static func read(_ directory: URL) throws -> (report: LegacyConsoleReport, games: [Game]) {
        try LegacyGameChangeService.verifyBackup(directory)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard manifest.count <= 131_072,
              let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let reportObject = object["observedReport"],
              JSONSerialization.isValidJSONObject(reportObject) else {
            throw LegacyInspectionError.invalidBackup
        }
        let report = try JSONDecoder().decode(LegacyConsoleReport.self,
                                              from: JSONSerialization.data(withJSONObject: reportObject))
        let entries = try TarContainer.open(container: Data(contentsOf: directory.appendingPathComponent("console.tar")))
        let factory = String(LegacyConsoleReport.factoryRoot.dropFirst()) + "/"
        let menu = String(LegacyConsoleReport.gameRoot.dropFirst()) + "/"
        var stock: [String: Game] = [:]
        var pageStock: [String: Game] = [:]
        var custom: [String: Game] = [:]
        for entry in entries where entry.info.type == .regular && entry.info.name.hasSuffix(".desktop") {
            let path = entry.info.name
            guard let data = entry.data, data.count <= 64 * 1024,
                  let content = String(data: data, encoding: .utf8) else { throw LegacyInspectionError.invalidMetadata }
            let components = path.split(separator: "/").map(String.init)
            guard let code = components.dropLast().last, SyncPlanner.validCode(code),
                  components.last == code + ".desktop" else { continue }
            let source: GameSource
            if path == factory + code + "/" + code + ".desktop", report.stockCodes.contains(code) {
                source = .stock
            } else if path.hasPrefix(menu) {
                let rest = String(path.dropFirst(menu.count)).split(separator: "/").map(String.init)
                guard rest.count == 3, rest[0].range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil,
                      rest[1] == code, rest[2] == code + ".desktop" else { throw LegacyInspectionError.invalidMetadata }
                if report.stockCodes.contains(code) { source = .stock }
                else if code.hasPrefix("CLV-H-") { source = .console }
                else { continue }
            } else { continue }
            let game = Game(code: code, desktopContent: content, consoleType: .nes, source: source)
            guard game.code == code, !game.commandLine.isEmpty else { throw LegacyInspectionError.invalidMetadata }
            if source == .stock {
                if path.hasPrefix(menu) {
                    guard pageStock.updateValue(game, forKey: code) == nil else { throw LegacyInspectionError.invalidMetadata }
                } else {
                    guard stock.updateValue(game, forKey: code) == nil else { throw LegacyInspectionError.invalidMetadata }
                }
            } else {
                guard custom.updateValue(game, forKey: code) == nil else { throw LegacyInspectionError.invalidMetadata }
            }
        }
        guard Set(stock.keys) == report.stockCodes,
              Set(pageStock.keys).isSubset(of: report.stockCodes),
              report.visibleCodes.subtracting(report.stockCodes).isSubset(of: Set(custom.keys)) else {
            throw LegacyInspectionError.invalidMetadata
        }
        let displayedStock = Set(pageStock.keys) == report.stockCodes ? pageStock : stock
        return (report, Array(displayedStock.values) + Array(custom.values))
    }
}

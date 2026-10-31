import CryptoKit
import Foundation
import SwiftHakchiCore

/// An immutable review of source bytes and menu choices. Nothing in this type opens USB.
struct LegacySyncPlan: Sendable {
    static func stagedROMFilename(for code: String) -> String { code + ".nes" }

    static func legacyNESCommand(for code: String) -> String {
        "/bin/clover-kachikachi-wr /var/games/\(code)/\(stagedROMFilename(for: code)) --guest-overscan-dimensions 0,0,9,3 --initial-fadein-durations 10,2 --volume 75 --enable-armet"
    }

    struct SourceFile: Sendable {
        let url: URL
        let byteCount: Int64
        let sha256: String

        static func capture(_ url: URL) throws -> Self {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size >= 0 else { throw SyncPlanError.missingFile(url.path) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            var received: Int64 = 0
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                received += Int64(chunk.count)
                guard received <= Int64(size) else { throw SyncPlanError.invalidInput("A selected source changed during review.") }
                hash.update(data: chunk)
            }
            guard received == Int64(size) else { throw SyncPlanError.invalidInput("A selected source changed during review.") }
            return Self(url: url.standardizedFileURL, byteCount: received,
                        sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }

        func verify() throws {
            let current = try Self.capture(url)
            guard current.byteCount == byteCount, current.sha256 == sha256 else {
                throw SyncPlanError.invalidInput("A selected source changed after review: \(url.lastPathComponent)")
            }
        }
    }

    struct PlannedGame: Sendable {
        let game: Game
        let desktopData: Data
        let desktopSource: SourceFile?
        let rom: SourceFile?
        let cover: SourceFile?
        var coverURL: URL? { cover?.url }
    }

    let selectedGames: [PlannedGame]
    let pages: [MenuPage]
    let structure: ConsoleStructure
    let menuGraph: ConsoleMenuGraph
    let folderArtworkSources: [String: SourceFile]
    let addedCodes: Set<String>
    let keptCodes: Set<String>
    let removedCodes: Set<String>
    let requiredStagingBytes: Int64
    let stageBytes: Int64
    let freeBytesAtReview: Int64
    let maximumGamesPerPage: Int
    let trialCode: String?
    let consoleOrder: ConsoleMenuOrder
    let reviewedLocalCodes: [String]
    let report: LegacyConsoleReport
    let reviewSHA256: String

    @MainActor static func make(localGames: [Game], remoteGames: [Game], report: LegacyConsoleReport,
                     selectedCodes: Set<String>, maximumGamesPerPage: Int,
                     trialCode: String?, consoleOrder: ConsoleMenuOrder = .title,
                     reviewedLocalCodes: [String] = [], structure: ConsoleStructure? = nil,
                     folderArtworkDirectory: URL? = nil) throws -> Self {
        guard let menuLimit = ConsoleMenuLimit(rawValue: maximumGamesPerPage) else {
            throw SyncPlanError.invalidInput("Choose a supported maximum games per page/folder value.")
        }
        let chosenStructure = structure ?? ConsoleStructure(maximumGamesPerPage: menuLimit)
        guard chosenStructure.maximumGamesPerPage == menuLimit else {
            throw SyncPlanError.invalidInput("The Structure setting and page limit do not match.")
        }
        try chosenStructure.validate()
        guard report.bootVersion == "1.0.1", report.kernelVersion == "3.4.112.madmonkey",
              report.scriptVersion == "[master]v1.0.3-110(7f31082)",
              report.activePage == LegacyConsoleReport.gameRoot + "/000",
              report.savesPath == "/var/lib/clover/profiles/0", report.freeBytes >= 0,
              report.stockCodes.count == 30 else { throw SyncPlanError.unsupportedConsole }
        guard Set(localGames.map(\.code)).count == localGames.count,
              Set(remoteGames.map(\.code)).count == remoteGames.count,
              localGames.allSatisfy({ SyncPlanner.validCode($0.code) && $0.consoleType == .nes }),
              remoteGames.allSatisfy({ SyncPlanner.validCode($0.code) && $0.consoleType == .nes }),
              Set(remoteGames.filter(\.isStock).map(\.code)) == report.stockCodes else {
            throw SyncPlanError.invalidInput("The local or console inventory has duplicate, invalid, or incomplete game entries.")
        }
        guard reviewedLocalCodes == Array(Set(reviewedLocalCodes)).sorted(),
              Set(reviewedLocalCodes).isSubset(of: Set(localGames.map(\.code))) else {
            throw SyncPlanError.invalidInput("The reviewed local game list changed.")
        }
        let localByCode = Dictionary(uniqueKeysWithValues: localGames.map { ($0.code, $0) })
        let remoteByCode = Dictionary(uniqueKeysWithValues: remoteGames.map { ($0.code, $0) })
        guard !selectedCodes.isEmpty,
              selectedCodes.isSubset(of: Set(localByCode.keys).union(report.stockCodes)),
              selectedCodes.allSatisfy({ report.stockCodes.contains($0) || localByCode[$0]?.source == .local }) else {
            throw SyncPlanError.invalidInput("Select imported local games or built-in games before reviewing a legacy sync.")
        }
        let chosen: Set<String>
        if let trialCode {
            guard selectedCodes.contains(trialCode), !report.stockCodes.contains(trialCode),
                  localByCode[trialCode]?.source == .local else {
                throw SyncPlanError.invalidInput("Choose one selected, imported NES game for the trial.")
            }
            chosen = report.stockCodes.union([trialCode])
        } else {
            chosen = selectedCodes
        }
        let preparedGames = try chosen.map { code -> PlannedGame in
            guard let game = localByCode[code] ?? remoteByCode[code] else {
                throw SyncPlanError.missingFile(code)
            }
            if report.stockCodes.contains(code) {
                guard game.isStock || remoteByCode[code]?.isStock == true else {
                    throw SyncPlanError.invalidInput("A built-in game code conflicts with a local import.")
                }
                var stock = remoteByCode[code]!
                let factoryROM = LegacyConsoleReport.factoryRoot + "/" + code + "/" + code + ".nes"
                let originalROM = String(factoryROM.dropFirst("/var/squashfs".count))
                let launchROM = try LaunchCommand.romPath(in: stock.commandLine, filename: code + ".nes")
                if launchROM == originalROM {
                    stock.commandLine = try LaunchCommand.replacingROM(in: stock.commandLine,
                                                                        oldPath: originalROM, newPath: factoryROM)
                } else if launchROM != factoryROM {
                    throw SyncPlanError.unsafeCommand
                }
                return PlannedGame(game: stock, desktopData: SyncPlanAdapter.desktopFile(for: stock).toData(),
                                   desktopSource: nil, rom: nil, cover: nil)
            }
            guard game.source == .local, game.code.hasPrefix("CLV-H-") else {
                throw SyncPlanError.invalidInput("Selected custom games must have a local NES ROM.")
            }
            let folder = URL(fileURLWithPath: game.romPath, isDirectory: true).standardizedFileURL
            let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
                  folder.lastPathComponent == code else { throw SyncPlanError.missingFile(game.name) }
            let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let roms = entries.filter { $0.pathExtension.lowercased() == "nes" }
            guard roms.count == 1, entries.filter({ ["fds", "zip", "7z", "sfc", "smc", "sfrom"].contains($0.pathExtension.lowercased()) }).isEmpty else {
                throw SyncPlanError.invalidInput("\(game.name) must have exactly one raw .nes ROM for this legacy trial.")
            }
            let rom = try SourceFile.capture(roms[0])
            let coverURL = folder.appendingPathComponent(code + ".png")
            guard game.coverArtPath.map({ URL(fileURLWithPath: $0).standardizedFileURL }) == coverURL else {
                throw SyncPlanError.missingFile("\(game.name) cover art")
            }
            let cover = try SourceFile.capture(coverURL)
            let desktop = try SourceFile.capture(folder.appendingPathComponent(code + ".desktop"))
            let launchROM = try LaunchCommand.romPath(in: game.commandLine, filename: roms[0].lastPathComponent)
            guard launchROM == "/var/games/\(code)/\(roms[0].lastPathComponent)" else { throw SyncPlanError.unsafeCommand }
            guard game.commandLine.hasPrefix("/bin/clover-kachikachi-wr ") else { throw SyncPlanError.unsafeCommand }
            var stagedGame = game
            stagedGame.commandLine = legacyNESCommand(for: code)
            return PlannedGame(game: game, desktopData: SyncPlanAdapter.desktopFile(for: stagedGame).toData(),
                               desktopSource: desktop, rom: rom, cover: cover)
        }
        let ordered = try consoleOrder.ordered(preparedGames.map(\.game))
        let plannedByCode = Dictionary(uniqueKeysWithValues: preparedGames.map { ($0.game.code, $0) })
        let orderedGames = ordered.compactMap { plannedByCode[$0.code] }
        let graph = try ConsoleStructurePlanner.make(games: orderedGames.map(\.game),
            stockCodes: report.stockCodes.intersection(chosen), order: consoleOrder,
            structure: chosenStructure)
        var artSources: [String: SourceFile] = [:]
        for key in Set(graph.screens.flatMap(\.links).compactMap(\.artKey)) {
            guard let folderArtworkDirectory else {
                throw SyncPlanError.invalidInput("Choose a folder artwork location before reviewing custom images.")
            }
            artSources[key] = try SourceFile.capture(folderArtworkDirectory.appendingPathComponent(key))
        }
        let pages = try MenuPaginator.pages(codes: orderedGames.map { $0.game.code },
                                            maximumGamesPerPage: maximumGamesPerPage)
        let games: [PlannedGame] = orderedGames.enumerated().map { position, item in
            guard trialCode == nil else { return item }
            // The console sorts entries inside a page by SortRawTitle. Freeze a
            // rank in each staged desktop so the reviewed order survives there.
            let desktop = DesktopFile(data: item.desktopData)
            desktop.sortName = String(format: "A%05d", position)
            return PlannedGame(game: item.game, desktopData: desktop.toData(),
                               desktopSource: item.desktopSource, rom: item.rom, cover: item.cover)
        }
        var stageBytes: Int64 = 4096
        for entry in games {
            for file in [entry.desktopSource, entry.rom, entry.cover].compactMap({ $0 }) {
                let (sum, overflow) = stageBytes.addingReportingOverflow(file.byteCount)
                guard !overflow else { throw SyncPlanError.invalidInput("The selected library is too large.") }
                stageBytes = sum
            }
            let (sum, overflow) = stageBytes.addingReportingOverflow(64 * 1024)
            guard !overflow else { throw SyncPlanError.invalidInput("The selected library is too large.") }
            stageBytes = sum
        }
        for source in artSources.values {
            let (twice, multiplyOverflow) = source.byteCount.multipliedReportingOverflow(by: 2)
            let (reserved, reserveOverflow) = twice.addingReportingOverflow(4096)
            let (sum, overflow) = stageBytes.addingReportingOverflow(reserved)
            guard !multiplyOverflow, !reserveOverflow, !overflow else {
                throw SyncPlanError.invalidInput("The folder artwork is too large.")
            }
            stageBytes = sum
        }
        // The uploaded tar and extracted inactive tree coexist with the live tree.
        let (twoCopies, copyOverflow) = stageBytes.multipliedReportingOverflow(by: 2)
        let (required, reserveOverflow) = twoCopies.addingReportingOverflow(64 * 1024 * 1024)
        guard !copyOverflow, !reserveOverflow, required <= report.freeBytes else {
            throw SyncPlanError.insufficientSpace(required: copyOverflow || reserveOverflow ? Int64.max : required,
                                                  available: report.freeBytes)
        }
        let installedCustom = Set(remoteGames.filter { $0.source == .console }.map(\.code))
        let selectedCustom = chosen.subtracting(report.stockCodes)
        let identityBase = games.map { item in
            [item.game.code, BackupManifest.digest(item.desktopData), item.desktopSource?.sha256 ?? "",
             item.rom?.sha256 ?? "", item.cover?.sha256 ?? ""].joined(separator: ":")
        }.joined(separator: "\n") + "\n" + [
            "trial=\(trialCode ?? "full")", "pageLimit=\(maximumGamesPerPage)",
            "freeBytes=\(report.freeBytes)", "requiredBytes=\(required)", "active=\(report.activePage)",
            "stock=\(report.stockCodes.sorted().joined(separator: ","))",
            "remote=\(remoteGames.map(\.code).sorted().joined(separator: ","))"
        ].joined(separator: "\n")
        let orderIdentity = consoleOrder == .title ? identityBase : identityBase + "\nconsoleOrder=" + consoleOrder.reviewKey
        var identity = trialCode == nil ? orderIdentity + "\nreviewedLocal=" + reviewedLocalCodes.joined(separator: ",") : orderIdentity
        let legacyStructure = ConsoleStructure(maximumGamesPerPage: menuLimit)
        if chosenStructure != legacyStructure {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            identity += "\nstructure=" + BackupManifest.digest(try encoder.encode(chosenStructure))
            identity += "\ngraph=" + BackupManifest.digest(try encoder.encode(graph))
            identity += "\nfolderArt=" + artSources.keys.sorted().map { $0 + ":" + artSources[$0]!.sha256 }.joined(separator: ",")
        }
        return Self(selectedGames: games, pages: pages, structure: chosenStructure,
                    menuGraph: graph, folderArtworkSources: artSources,
                    addedCodes: selectedCustom.subtracting(installedCustom),
                    keptCodes: selectedCustom.intersection(installedCustom),
                    removedCodes: installedCustom.subtracting(selectedCustom),
                    requiredStagingBytes: required, stageBytes: stageBytes,
                    freeBytesAtReview: report.freeBytes, maximumGamesPerPage: maximumGamesPerPage,
                    trialCode: trialCode, consoleOrder: consoleOrder,
                    reviewedLocalCodes: reviewedLocalCodes, report: report,
                    reviewSHA256: BackupManifest.digest(Data(identity.utf8)))
    }

    func verifyLocalSources() throws {
        for game in selectedGames {
            try game.desktopSource?.verify()
            try game.rom?.verify()
            try game.cover?.verify()
        }
        for source in folderArtworkSources.values { try source.verify() }
    }
}

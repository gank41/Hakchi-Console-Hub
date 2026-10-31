import Foundation
import SWCompression
import SwiftHakchiCore

/// Builds the old direct-page menu on the Mac. No USB or console mutation occurs here.
enum LegacyMenuStage {
    private struct FactoryAssets {
        let byCode: [String: Set<String>]
        let moreIcon: Data
        let moreSmall: Data
        let backIcon: Data
        let backSmall: Data

        static func load(from backup: URL, stockCodes: Set<String>) throws -> Self {
            try LegacyGameChangeService.verifyBackup(backup)
            let archive = try Data(contentsOf: backup.appendingPathComponent("console.tar"))
            let entries = try TarContainer.open(container: archive)
            let factoryPrefix = String(LegacyConsoleReport.factoryRoot.dropFirst()) + "/"
            let menuPrefix = String(LegacyConsoleReport.gameRoot.dropFirst()) + "/"
            var assets: [String: Set<String>] = [:]
            var icons: [String: Data] = [:]
            let iconPaths = [
                "000/CLV-S-00001/CLV-S-00001.png",
                "000/CLV-S-00001/CLV-S-00001_small.png",
                "001/CLV-S-00000/CLV-S-00000.png",
                "001/CLV-S-00000/CLV-S-00000_small.png"
            ]
            for entry in entries {
                let name = entry.info.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if name.hasPrefix(factoryPrefix) {
                    let rest = String(name.dropFirst(factoryPrefix.count)).split(separator: "/").map(String.init)
                    guard rest.count >= 2, stockCodes.contains(rest[0]) else { continue }
                    let asset = rest[1]
                    guard asset.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
                          asset != ".", asset != ".." else {
                        throw SyncPlanError.invalidInput("The preserved factory inventory has an unsafe asset name.")
                    }
                    if rest.count == 2 {
                        guard entry.info.type == .regular || entry.info.type == .directory else {
                            throw SyncPlanError.invalidInput("A factory asset has an unsupported file type.")
                        }
                        assets[rest[0], default: []].insert(asset)
                    }
                } else if name.hasPrefix(menuPrefix) {
                    let relative = String(name.dropFirst(menuPrefix.count))
                    if iconPaths.contains(relative) {
                        guard entry.info.type == .regular, let data = entry.data,
                              data.count > 8, data.count <= 1024 * 1024,
                              icons.updateValue(data, forKey: relative) == nil else {
                            throw SyncPlanError.invalidInput("The preserved menu folder artwork is invalid.")
                        }
                    }
                }
            }
            for code in stockCodes {
                let required = Set([code + ".desktop", code + ".nes", code + ".png", code + "_small.png"])
                guard required.isSubset(of: assets[code] ?? []) else {
                    throw SyncPlanError.invalidInput("The preserved factory inventory is missing a built-in game asset.")
                }
            }
            guard let more = icons[iconPaths[0]], let moreSmall = icons[iconPaths[1]],
                  let back = icons[iconPaths[2]], let backSmall = icons[iconPaths[3]] else {
                throw SyncPlanError.invalidInput("The preserved legacy folder icons are incomplete.")
            }
            return Self(byCode: assets, moreIcon: more, moreSmall: moreSmall,
                        backIcon: back, backSmall: backSmall)
        }
    }

    static func build(plan: LegacySyncPlan, in parent: URL, verifiedBackup: URL) throws -> LegacyMenuStageManifest {
        try plan.verifyLocalSources()
        let factory = try FactoryAssets.load(from: verifiedBackup, stockCodes: plan.report.stockCodes)
        let root = parent.appendingPathComponent("LegacyMenuStage-" + UUID().uuidString, isDirectory: true)
        let menu = root.appendingPathComponent("menu", isDirectory: true)
        try FileManager.default.createDirectory(at: menu, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: root) } }
        var records: [LegacyMenuStageManifest.Entry] = []
        let byCode = Dictionary(uniqueKeysWithValues: plan.selectedGames.map { ($0.game.code, $0) })

        func safe(_ relative: String) throws -> URL {
            guard relative.utf8.count <= 100, !relative.hasPrefix("/"), !relative.contains("\\"),
                  !relative.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  relative.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw SyncPlanError.invalidInput("A staged game path cannot be represented safely.")
            }
            return menu.appendingPathComponent(relative)
        }
        func directory(_ relative: String) throws {
            let url = try safe(relative)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            records.append(.init(relativePath: relative, kind: .directory, byteCount: 0,
                                 sha256: nil, linkTarget: nil))
        }
        func file(_ relative: String, data: Data) throws {
            let url = try safe(relative)
            try data.write(to: url, options: .atomic)
            records.append(.init(relativePath: relative, kind: .regular, byteCount: Int64(data.count),
                                 sha256: BackupManifest.digest(data), linkTarget: nil))
        }
        func link(_ relative: String, target: String) throws {
            let url = try safe(relative)
            guard target.hasPrefix(LegacyConsoleReport.factoryRoot + "/"), !target.contains(".."),
                  target.utf8.count <= 100 else { throw SyncPlanError.invalidInput("A factory link target is unsafe.") }
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            records.append(.init(relativePath: relative, kind: .symbolicLink, byteCount: 0,
                                 sha256: nil, linkTarget: target))
        }
        let legacyNavigation = plan.structure.mode == .pagesEqual &&
            plan.structure.backPosition == .bottom && plan.structure.folderArt == .classic
        func navigation(_ page: ConsoleMenuGraph.Screen, link: ConsoleMenuGraph.Link) throws {
            let pageName = String(format: "%03d", page.number)
            let code = link.consoleCode
            let base = pageName + "/" + code
            try directory(base)
            let desktop = DesktopFile()
            desktop.code = code
            desktop.name = link.title
            desktop.exec = "/bin/chmenu " + String(format: "%03d", link.target)
            desktop.profilePath = "/var/lib/clover/profiles/0/FOLDER"
            desktop.omitProfilePathCode = true
            desktop.iconPath = "/var/games"
            desktop.iconFilename = code + ".png"
            if legacyNavigation {
                desktop.sortName = (link.role == .back ? "Я" : "Ю") + desktop.name
            } else if link.role == .back {
                desktop.sortName = (page.backPosition == .top ? "00000" : "ZZZZZ") + link.title
            } else {
                desktop.sortName = String(format: "Y%05d", link.target) + link.title
            }
            desktop.publisher = "ZZZZZZZZZZ"
            desktop.testId = 777
            try file(base + "/" + code + ".desktop", data: desktop.toData())
            let classicLarge = link.role == .back ? factory.backIcon : factory.moreIcon
            let classicSmall = link.role == .back ? factory.backSmall : factory.moreSmall
            let art = try ConsoleFolderArtwork.images(for: link, style: plan.structure.folderArt,
                classicLarge: classicLarge, classicSmall: classicSmall, sources: plan.folderArtworkSources)
            try file(base + "/" + code + ".png", data: art.large)
            try file(base + "/" + code + "_small.png", data: art.small)
        }

        try plan.menuGraph.validate(selectedCodes: Set(plan.selectedGames.map { $0.game.code }))
        for page in plan.menuGraph.screens {
            let number = String(format: "%03d", page.number)
            try directory(number)
            for code in page.gameCodes {
                guard let item = byCode[code] else { throw SyncPlanError.invalidInput("A reviewed game is missing from its menu page.") }
                let base = number + "/" + code
                try directory(base)
                if item.game.isStock {
                    let launch = try LaunchCommand.arguments(in: item.game.commandLine)
                    guard launch.count >= 2, launch[0] == "/bin/clover-kachikachi-wr",
                          launch[1] == LegacyConsoleReport.factoryRoot + "/" + code + "/" + code + ".nes" else {
                        throw SyncPlanError.unsafeCommand
                    }
                    for asset in (factory.byCode[code] ?? []).sorted() where asset != code + ".desktop" {
                        try link(base + "/" + asset, target: LegacyConsoleReport.factoryRoot + "/" + code + "/" + asset)
                    }
                } else {
                    guard let rom = item.rom, let cover = item.cover else { throw SyncPlanError.missingFile(code) }
                    let source = try Data(contentsOf: rom.url)
                    guard Int64(source.count) == rom.byteCount, BackupManifest.digest(source) == rom.sha256 else {
                        throw SyncPlanError.invalidInput("A selected ROM changed during stage construction.")
                    }
                    try file(base + "/" + LegacySyncPlan.stagedROMFilename(for: code), data: source)
                    let coverData = try Data(contentsOf: cover.url)
                    guard Int64(coverData.count) == cover.byteCount, BackupManifest.digest(coverData) == cover.sha256 else {
                        throw SyncPlanError.invalidInput("Selected box art changed during stage construction.")
                    }
                    let normalized = try GameArtworkStore.png(from: coverData)
                    try file(base + "/" + code + ".png", data: resizeCoverArt(data: normalized, width: 204, height: 204))
                    try file(base + "/" + code + "_small.png", data: resizeCoverArt(data: normalized, width: 40, height: 40))
                }
                try file(base + "/" + code + ".desktop", data: item.desktopData)
            }
            for link in page.links { try navigation(page, link: link) }
        }
        let sorted = records.sorted { $0.relativePath < $1.relativePath }
        let treeDescription = sorted.map { entry in
            [entry.relativePath, entry.kind.rawValue, String(entry.byteCount), entry.sha256 ?? "", entry.linkTarget ?? ""].joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
        let treeSHA = BackupManifest.digest(Data(treeDescription.utf8))
        let tar = root.appendingPathComponent("menu.tar")
        FileManager.default.createFile(atPath: tar.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tar)
        defer { try? handle.close() }
        var writer = SWCompression.TarWriter(fileHandle: handle, force: .ustar)
        for record in sorted {
            var info = TarEntryInfo(name: record.relativePath, type: record.kind == .directory ? .directory : record.kind == .regular ? .regular : .symbolicLink)
            info.permissions = Permissions(rawValue: record.kind == .directory ? 0o755 : record.kind == .regular ? 0o644 : 0o777)
            info.ownerID = 0; info.groupID = 0; info.modificationTime = Date(timeIntervalSince1970: 0)
            info.linkName = record.linkTarget ?? ""
            let contents = record.kind == .regular ? try Data(contentsOf: menu.appendingPathComponent(record.relativePath)) : nil
            if let contents, BackupManifest.digest(contents) != record.sha256 { throw SyncPlanError.invalidInput("The stage changed while its archive was built.") }
            try writer.append(TarEntry(info: info, data: contents))
        }
        try writer.finalize(); try handle.close()
        let archive = try LegacySyncPlan.SourceFile.capture(tar)
        guard archive.byteCount <= plan.stageBytes + Int64(sorted.count * 1024 + 2048) else {
            throw SyncPlanError.invalidInput("The stage exceeds the reviewed storage budget.")
        }
        let manifest = LegacyMenuStageManifest(reviewSHA256: plan.reviewSHA256, menuDirectory: menu,
                                               archiveURL: tar, entries: sorted, treeSHA256: treeSHA,
                                               archiveSHA256: archive.sha256, archiveBytes: archive.byteCount,
                                               reviewReport: plan.report)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        complete = true
        return manifest
    }
}

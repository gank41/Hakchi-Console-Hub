import Foundation
import SWCompression
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized) @MainActor
struct LegacyMenuStageTests {
    let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO/aF5kAAAAASUVORK5CYII=")!

    func report(_ stock: Set<String>) -> LegacyConsoleReport {
        LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
                            scriptVersion: "[master]v1.0.3-110(7f31082)",
                            activePage: LegacyConsoleReport.gameRoot + "/000", freeBytes: 512 * 1024 * 1024,
                            savesPath: "/var/lib/clover/profiles/0", stockCodes: stock,
                            visibleCodes: stock)
    }

    func stockGame(_ code: String) -> Game {
        let factory = "/usr/share/games/nes/kachikachi/" + code + "/" + code + ".nes"
        return Game(code: code, desktopContent: "[Desktop Entry]\nCode=\(code)\nName=\(code)\nExec=/bin/clover-kachikachi-wr \(factory)",
                    consoleType: .nes, source: .stock)
    }

    func localGame(_ code: String, root: URL) throws -> Game {
        let folder = root.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x4E, 0x45, 0x53, 0x1A] + Array(repeating: 0, count: 64)).write(to: folder.appendingPathComponent("Trial.nes"))
        try pixel.write(to: folder.appendingPathComponent(code + ".png"))
        let desktop = "[Desktop Entry]\nCode=\(code)\nName=Edited Trial\nExec=/bin/clover-kachikachi-wr /var/games/\(code)/Trial.nes\nIcon=/var/games/\(code)/\(code).png\n"
        try Data(desktop.utf8).write(to: folder.appendingPathComponent(code + ".desktop"))
        return Game(desktopFile: DesktopFile(string: desktop), consoleType: .nes, basePath: root.path)
    }

    func backup(_ root: URL, stock: Set<String>) throws -> URL {
        let directory = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("console.tar")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        var writer = SWCompression.TarWriter(fileHandle: handle, force: .ustar)
        func add(_ name: String, _ data: Data) throws {
            var info = TarEntryInfo(name: name, type: .regular)
            info.permissions = Permissions(rawValue: 0o644); info.ownerID = 0; info.groupID = 0
            info.modificationTime = Date(timeIntervalSince1970: 0)
            try writer.append(TarEntry(info: info, data: data))
        }
        let prefix = String(LegacyConsoleReport.factoryRoot.dropFirst()) + "/"
        for code in stock.sorted() {
            for name in [code + ".desktop", code + ".nes", code + ".png", code + "_small.png"] {
                let bytes = name.hasSuffix(".desktop")
                    ? Data("[Desktop Entry]\nCode=\(code)\nName=\(code)\nExec=/usr/bin/clover-kachikachi /usr/share/games/nes/kachikachi/\(code)/\(code).nes\n".utf8)
                    : Data([1])
                try add(prefix + code + "/" + name, bytes)
            }
            let pageDesktop = "[Desktop Entry]\nCode=\(code)\nName=\(code)\nExec=/bin/clover-kachikachi-wr \(LegacyConsoleReport.factoryRoot)/\(code)/\(code).nes\n"
            try add(String(LegacyConsoleReport.gameRoot.dropFirst()) + "/000/" + code + "/" + code + ".desktop", Data(pageDesktop.utf8))
        }
        let menu = String(LegacyConsoleReport.gameRoot.dropFirst())
        for (page, code) in [("000", "CLV-S-00001"), ("001", "CLV-S-00000")] {
            for name in [code + ".png", code + "_small.png"] {
                try add(menu + "/" + page + "/" + code + "/" + name, pixel)
            }
        }
        try writer.finalize(); try handle.close()
        let bytes = try Data(contentsOf: archive)
        let observed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report(stock)))
        let manifest: [String: Any] = ["sha256": BackupManifest.digest(bytes), "byteCount": bytes.count,
                                       "observedReport": observed]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }

    @Test func stageUsesOldDirectPageLayoutAndDeterministicArchive() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let code = "CLV-H-AAAAA"
        let local = try localGame(code, root: root)
        let plan = try LegacySyncPlan.make(localGames: [local], remoteGames: stock.map(stockGame),
                    report: report(stock), selectedCodes: [code], maximumGamesPerPage: 25, trialCode: code)
        let preserved = try backup(root, stock: stock)
        let savedLibrary = try LegacyBackupLibrary.read(preserved)
        #expect(savedLibrary.games.filter(\.isStock).count == 30)
        let factoryHashes = try LegacyBackupLibrary.stockROMHashes(preserved)
        #expect(Set(factoryHashes.keys) == stock)
        #expect(Set(factoryHashes.values) == [BackupManifest.digest(Data([1]))])
        #expect(savedLibrary.games.allSatisfy { !$0.isStock || $0.commandLine.hasPrefix("/bin/clover-kachikachi-wr ") })
        let first = try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: preserved)
        #expect(first.reviewReport == plan.report)
        let reloaded = try JSONDecoder().decode(LegacyMenuStageManifest.self,
            from: Data(contentsOf: first.menuDirectory.deletingLastPathComponent().appendingPathComponent("manifest.json")))
        #expect(reloaded.reviewReport == plan.report)
        let second = try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: preserved)
        #expect(first.archiveSHA256 == second.archiveSHA256)
        #expect(first.entries.filter { $0.kind == .regular && $0.relativePath.hasSuffix("/" + code + ".nes") }.count == 1)
        #expect(first.entries.contains { $0.relativePath.hasSuffix("CLV-H-AAAAA_small.png") })
        let link = try #require(first.entries.first { $0.kind == .symbolicLink && $0.relativePath.hasSuffix("CLV-P-00000.nes") })
        #expect(link.linkTarget == LegacyConsoleReport.factoryRoot + "/CLV-P-00000/CLV-P-00000.nes")
        let back = try #require(first.entries.first { $0.relativePath.hasSuffix("001/CLV-S-00000/CLV-S-00000.desktop") })
        let backText = try String(contentsOf: first.menuDirectory.appendingPathComponent(back.relativePath), encoding: .utf8)
        #expect(backText.contains("Exec=/bin/chmenu 000"))
        #expect(!backText.contains("/var/games\n"))
        #expect(!first.entries.contains { $0.relativePath.contains(".storage") })
    }

    @Test func legacyTrialStagesSpaceNamedROMWithKnownWorkingNESLauncher() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let code = "CLV-H-AAAAA"
        let folder = root.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x4E, 0x45, 0x53, 0x1A] + Array(repeating: 0, count: 64))
            .write(to: folder.appendingPathComponent("Zelda 2.NES"))
        try pixel.write(to: folder.appendingPathComponent(code + ".png"))
        let sourceDesktop = "[Desktop Entry]\nCode=\(code)\nName=Edited Zelda 2\nExec=/bin/clover-kachikachi-wr '/var/games/\(code)/Zelda 2.NES' --volume 75 --rollback-snapshot-period 720\nIcon=/var/games/\(code)/\(code).png\n"
        try Data(sourceDesktop.utf8).write(to: folder.appendingPathComponent(code + ".desktop"))
        let game = Game(desktopFile: DesktopFile(string: sourceDesktop), consoleType: .nes, basePath: root.path)
        let plan = try LegacySyncPlan.make(localGames: [game], remoteGames: stock.map(stockGame),
                                           report: report(stock), selectedCodes: [code],
                                           maximumGamesPerPage: 25, trialCode: code)
        let stage = try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: backup(root, stock: stock))
        let stagedDesktopEntry = try #require(stage.entries.first { $0.relativePath.hasSuffix("/" + code + "/" + code + ".desktop") })
        let gameFolder = stage.menuDirectory.appendingPathComponent(stagedDesktopEntry.relativePath).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent(code + ".nes").path))
        #expect(!FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent("Zelda 2.NES").path))
        let stagedDesktop = try String(contentsOf: gameFolder.appendingPathComponent(code + ".desktop"), encoding: .utf8)
        #expect(stagedDesktop.contains("Name=Edited Zelda 2"))
        #expect(stagedDesktop.contains("Exec=/bin/clover-kachikachi-wr /var/games/\(code)/\(code).nes --guest-overscan-dimensions 0,0,9,3 --initial-fadein-durations 10,2 --volume 75 --enable-armet"))
        #expect(!stagedDesktop.contains("--rollback-snapshot-period"))
        #expect(!stagedDesktop.contains("'"))
    }

    @Test func fullStageWritesRankedDesktopKeysForConsoleOrder() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let local = try localGame("CLV-H-AAAAA", root: root)
        let selected = stock.union([local.code])
        let sequence = [local.code] + Array(stock.sorted().reversed())
        let plan = try LegacySyncPlan.make(localGames: [local], remoteGames: stock.map(stockGame),
            report: report(stock), selectedCodes: selected, maximumGamesPerPage: 25,
            trialCode: nil, consoleOrder: .manual(sequence), reviewedLocalCodes: [local.code])
        let staged = try LegacyMenuStage.build(plan: plan, in: root,
                                                verifiedBackup: backup(root, stock: stock))
        #expect(plan.pages.flatMap(\.gameCodes) == sequence)
        for (index, code) in sequence.enumerated() {
            let page = try #require(plan.pages.first { $0.gameCodes.contains(code) })
            let actual = staged.menuDirectory.appendingPathComponent(String(format: "%03d", page.number))
                .appendingPathComponent(code).appendingPathComponent(code + ".desktop")
            let desktop = DesktopFile(data: try Data(contentsOf: actual))
            #expect(desktop.sortName == String(format: "A%05d", index))
        }
    }

    @Test func alteredROMOrUnsafeFactoryArchiveRefusesStage() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let code = "CLV-H-AAAAA"
        let local = try localGame(code, root: root)
        let plan = try LegacySyncPlan.make(localGames: [local], remoteGames: stock.map(stockGame),
                    report: report(stock), selectedCodes: [code], maximumGamesPerPage: 25, trialCode: code)
        let preserved = try backup(root, stock: stock)
        try Data([3, 4]).write(to: root.appendingPathComponent(code).appendingPathComponent("Trial.nes"))
        #expect(throws: SyncPlanError.self) {
            try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: preserved)
        }
        try Data([0x4E, 0x45, 0x53, 0x1A] + Array(repeating: 0, count: 64)).write(to: root.appendingPathComponent(code).appendingPathComponent("Trial.nes"))
        try Data([9]).write(to: preserved.appendingPathComponent("console.tar"))
        #expect(throws: (any Error).self) {
            try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: preserved)
        }
    }
}

import AppKit
import Foundation
import ImageIO
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized) @MainActor
struct LegacyStructureStageTests {
    private let fixture = LegacyMenuStageTests()

    private func prepared(_ root: URL, structure: ConsoleStructure,
                          artworkDirectory: URL? = nil) throws -> (LegacySyncPlan, URL) {
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let local = try fixture.localGame("CLV-H-AAAAA", root: root)
        let plan = try LegacySyncPlan.make(localGames: [local], remoteGames: stock.map(fixture.stockGame),
            report: fixture.report(stock), selectedCodes: stock.union([local.code]),
            maximumGamesPerPage: 30, trialCode: nil, reviewedLocalCodes: [local.code],
            structure: structure, folderArtworkDirectory: artworkDirectory)
        return (plan, try fixture.backup(root, stock: stock))
    }

    @Test func defaultStageStillRendersOriginalPageAndNavigationBytes() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, backup) = try prepared(root, structure: .init())
        #expect(plan.menuGraph.screens.map(\.gameCodes) == plan.pages.map(\.gameCodes))
        let stage = try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: backup)
        let back = "001/CLV-S-00000/CLV-S-00000.desktop"
        let desktop = try Data(contentsOf: stage.menuDirectory.appendingPathComponent(back))
        #expect(DesktopFile(data: desktop).exec == "/bin/chmenu 000")
        let expected = DesktopFile()
        expected.code = "CLV-S-00000"
        expected.name = "Previous games"
        expected.exec = "/bin/chmenu 000"
        expected.profilePath = "/var/lib/clover/profiles/0/FOLDER"
        expected.omitProfilePathCode = true
        expected.iconPath = "/var/games"
        expected.iconFilename = "CLV-S-00000.png"
        expected.sortName = "ЯPrevious games"
        expected.publisher = "ZZZZZZZZZZ"
        expected.testId = 777
        #expect(desktop == expected.toData())
        #expect(stage.entries.contains { $0.relativePath == "000/CLV-S-00001/CLV-S-00001.png" })
        #expect(stage.entries.contains { $0.relativePath == "001/CLV-S-00000/CLV-S-00000.png" })
        #expect(stage.entries.first { $0.relativePath == "001/CLV-S-00000/CLV-S-00000.png" }?.sha256
                == BackupManifest.digest(fixture.pixel))
    }

    @Test func stockRootFoldersRenderRootHubChildAndBack() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, backup) = try prepared(root, structure: .init(mode: .stockRootFoldersEqual))
        let stage = try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: backup)
        let paths = Set(stage.entries.map(\.relativePath))
        #expect(plan.menuGraph.warnings.contains(.stockRootHas31Entries))
        #expect(paths.contains("000/CLV-S-00001/CLV-S-00001.desktop"))
        #expect(paths.contains("001/CLV-S-00000/CLV-S-00000.desktop"))
        #expect(paths.contains("001/CLV-S-00002/CLV-S-00002.desktop"))
        #expect(paths.contains("002/CLV-H-AAAAA/CLV-H-AAAAA.desktop"))
        #expect(paths.contains("002/CLV-S-00001/CLV-S-00001.desktop"))
        let childBack = DesktopFile(data: try Data(contentsOf: stage.menuDirectory
            .appendingPathComponent("002/CLV-S-00001/CLV-S-00001.desktop")))
        #expect(childBack.exec == "/bin/chmenu 001")
    }

    @Test func letterTileArtworkHasConsoleDimensions() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, backup) = try prepared(root, structure: .init(mode: .foldersAlphabetical, folderArt: .letterTiles))
        let stage = try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: backup)
        let art = try #require(stage.entries.first { $0.relativePath.hasSuffix("CLV-S-00001.png") })
        let source = try #require(CGImageSourceCreateWithURL(stage.menuDirectory.appendingPathComponent(art.relativePath) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 204 && image.height == 204)
    }

    @Test func customFolderArtworkIsFrozenAndResized() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let artwork = root.appendingPathComponent("folder-art")
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        try fixture.pixel.write(to: artwork.appendingPathComponent("selected.png"))
        let stock = (0..<30).map { String(format: "CLV-P-%05d", $0) }
        let tree = ConsoleStructure.CustomFolderTree(rootGameCodes: stock, folders: [
            .init(id: "imported", title: "Imported", parentID: nil,
                  gameCodes: ["CLV-H-AAAAA"], artKey: "selected.png")
        ])
        let (plan, backup) = try prepared(root, structure: .init(mode: .custom,
            folderArt: .custom, custom: tree), artworkDirectory: artwork)
        let stage = try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: backup)
        for (name, size) in [("CLV-S-00001.png", 204), ("CLV-S-00001_small.png", 40)] {
            let imageURL = stage.menuDirectory.appendingPathComponent("000/CLV-S-00001/" + name)
            let source = try #require(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == size && image.height == size)
        }
        try Data([1, 2, 3]).write(to: artwork.appendingPathComponent("selected.png"))
        #expect(throws: (any Error).self) {
            try LegacyMenuStage.build(plan: plan, in: root, verifiedBackup: backup)
        }
    }

    @Test func customPreviewOrderMatchesRenderedDesktopOrderAfterReassignment() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let first = try fixture.localGame("CLV-H-AAAAA", root: root)
        let second = try fixture.localGame("CLV-H-BBBBB", root: root)
        let tree = ConsoleStructure.CustomFolderTree(rootGameCodes: Array(stock).sorted(), folders: [
            .init(id: "added", title: "Added games", parentID: nil,
                  gameCodes: [second.code, first.code], artKey: nil)
        ])
        let structure = ConsoleStructure(mode: .custom, custom: tree)
        let plan = try LegacySyncPlan.make(localGames: [first, second],
            remoteGames: stock.map(fixture.stockGame), report: fixture.report(stock),
            selectedCodes: stock.union([first.code, second.code]), maximumGamesPerPage: 30,
            trialCode: nil, reviewedLocalCodes: [first.code, second.code], structure: structure)
        let stage = try LegacyMenuStage.build(plan: plan, in: root,
                                              verifiedBackup: fixture.backup(root, stock: stock))
        let screen = try #require(plan.menuGraph.screens.first { $0.title == "Added games" })
        let rendered = try screen.gameCodes.map { code in
            let path = String(format: "%03d/%@/%@.desktop", screen.number, code, code)
            return (code, DesktopFile(data: try Data(contentsOf: stage.menuDirectory.appendingPathComponent(path))).sortName)
        }
        #expect(rendered.map(\.0) == rendered.sorted { $0.1 < $1.1 }.map(\.0))
    }

    @Test func folderArtPreviewUsesTheStageArtworkRenderer() throws {
        let link = ConsoleMenuGraph.Link(target: 1, title: "Games 1", role: .folder, artKey: nil)
        let preview = try ConsoleFolderArtwork.previewData(for: link, style: .letterTiles,
                                                            artworkDirectory: nil)
        let image = try #require(NSImage(data: preview))
        #expect(image.size.width == 204 && image.size.height == 204)
    }
}

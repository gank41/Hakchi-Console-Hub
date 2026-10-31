import Foundation
import Testing
@testable import SwiftHakchi
@MainActor struct GameGenieCatalogModelTests {
    @Test func browsingAndSwitchingAreOfflineAndOnlyReviewAcceptanceInstalls() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let model=GameGenieCatalogModel(workspace:root,system:.nes,gameName:"Contra")
        #expect(model.query=="Contra" && model.catalog==nil && !model.isDownloading)
        model.selectSystem(.snes)
        #expect(model.system == .snes && model.catalog==nil)
        let value=GameGenieOfflineCatalog(system:.snes,effects:[.init(game:"Example",codes:["22BB-AD01"],title:"Lives")])
        try model.review(value)
        let saved=try GameGenieCatalogLibrary(workspace:root).load(.snes)
        #expect(model.pending != nil && saved==nil)
        try model.acceptReview()
        #expect(model.pending==nil && model.catalog?.effects.count==1)
    }
    @Test func staleDownloadCannotReplaceAnotherSystem() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let fake=GameGenieDownloadFake(),model=GameGenieCatalogModel(workspace:root,system:.nes,gameName:"")
        let task=Task {await model.download(using:GameGenieCatalogDownload(fetch:{try await fake.fetch($0)},wait:{_ in try await Task.sleep(for:.milliseconds(10))}))}
        await Task.yield();model.selectSystem(.snes)
        await task.value
        #expect(model.system == .snes && model.pending==nil && model.catalog==nil)
    }
}

extension GameGenieCatalogModelTests {
    @Test func exactGameOpensEvenWhenOtherTitlesContainItsName() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        try GameGenieCatalogLibrary(workspace:root).install(.init(system:.nes,effects:[.init(game:"Contra",codes:["SXIOPO"],title:"Example"),.init(game:"Contra Force",codes:["SXIOPO"],title:"Example")]))
        let model=GameGenieCatalogModel(workspace:root,system:.nes,gameName:"Contra")
        #expect(model.preferredGame=="Contra")
    }
}

extension GameGenieCatalogModelTests {
    @Test func failedSystemReloadClearsPreviousCatalogAndMergedReviewCountIncludesRetainedRows() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let library=GameGenieCatalogLibrary(workspace:root)
        try library.install(.init(system:.nes,effects:[.init(game:"Contra",codes:[],title:"Needs review",reviewReasons:["Unknown source"])]))
        let model=GameGenieCatalogModel(workspace:root,system:.nes,gameName:"")
        var incoming=GameGenieOfflineCatalog(system:.nes,effects:[.init(game:"Other",codes:["SXIOPO"],title:"Example")])
        incoming.coverage = .init(discovered:1,fetched:1)
        try model.review(incoming)
        #expect(model.pending?.coverage.reviewEntries==1 && model.notice?.contains("1 entries to review")==true)
        try GameGenieCatalogLibrary.write(Data("bad json".utf8),to:library.folder(create:true).appendingPathComponent("catalog-snes-v2.json"))
        model.selectSystem(.snes)
        #expect(model.catalog==nil && model.error != nil)
    }
}

extension GameGenieCatalogModelTests {
    @Test func alienVersusPredatorFindsSavedSNESCatalogWithoutDownloadOrInstalledROM() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let value=GameGenieOfflineCatalog(system:.snes,effects:[.init(game:"Aliens vs. Predator",codes:["C2C9-4E2C"],title:"Synthetic effect")])
        try GameGenieCatalogLibrary(workspace:root).install(value)
        let model=GameGenieCatalogModel(workspace:root,system:.snes,gameName:"Alien vs. Predator")
        #expect(model.catalog?.searchGames(model.query)==["Aliens vs. Predator"])
        #expect(model.preferredGame=="Aliens vs. Predator")
        #expect(model.catalog?.searchGames("Aliens")==["Aliens vs. Predator"])
        let emptyLibraryBrowser=GameGenieCatalogModel(workspace:root,system:.snes,gameName:"")
        #expect(emptyLibraryBrowser.catalog?.searchGames("")==["Aliens vs. Predator"])
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Library/Games").path))
        let genesis=GameGenieOfflineCatalog(system:.genesis,effects:value.effects)
        #expect(genesis.searchGames("Alien vs. Predator").isEmpty)
    }
}

extension GameGenieCatalogModelTests {
    @Test func gameContextLocksCodesToItsConsoleWhileStandaloneBrowserCanSwitch() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let library=GameGenieCatalogLibrary(workspace:root)
        try library.install(.init(system:.snes,effects:[.init(game:"Example",codes:["C2C9-4E2C"],title:"SNES effect")]))
        try library.install(.init(system:.nes,effects:[.init(game:"Example",codes:["SXIOPO"],title:"NES effect")]))
        let targeted=GameGenieCatalogModel(workspace:root,system:.snes,gameName:"Example",lockedSystem:.snes)
        targeted.selectSystem(.nes)
        #expect(targeted.system == .snes && targeted.catalog?.effects.first?.title=="SNES effect")
        #expect(throws:(any Error).self){try targeted.review(.init(system:.nes,effects:[]))}
        let standalone=GameGenieCatalogModel(workspace:root,system:.snes,gameName:"")
        standalone.selectSystem(.nes)
        #expect(standalone.system == .nes && standalone.catalog?.effects.first?.title=="NES effect")
    }
}

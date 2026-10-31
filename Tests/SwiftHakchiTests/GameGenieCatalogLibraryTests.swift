import Foundation
import Testing
@testable import SwiftHakchi
struct GameGenieCatalogLibraryTests {
    @Test func reviewedInstallRetainsPreviousCatalogAndNeverTouchesGames() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let library=GameGenieCatalogLibrary(workspace:root)
        #expect(try library.load(.nes)==nil)
        let first=GameGenieOfflineCatalog(system:.nes,effects:[.init(game:"Test",codes:["SXIOPO"],title:"First")])
        try library.install(first)
        let second=try first.merged(with:.init(system:.nes,effects:[.init(game:"Test",codes:["GZUXNGEI"],title:"Second")]))
        let folder=try library.folder(create:true)
        let before=try Data(contentsOf:folder.appendingPathComponent("catalog-nes-v2.json"))
        #expect(try library.load(.nes)?.effects.count==1)
        try library.install(second)
        #expect(try library.load(.nes)?.effects.count==2)
        let history=try FileManager.default.contentsOfDirectory(at:folder.appendingPathComponent("History"),includingPropertiesForKeys:nil)
        let saved=try Data(contentsOf:history[0])
        #expect(history.count==1 && saved==before)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Games").path))
    }
    @Test func unsafeStorageAndMalformedImportCannotReplaceCatalog() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let library=GameGenieCatalogLibrary(workspace:root),folder=try library.folder(create:true)
        let target=folder.appendingPathComponent("catalog-snes-v2.json")
        try FileManager.default.createSymbolicLink(at:target,withDestinationURL:root.appendingPathComponent("other"))
        #expect(throws:(any Error).self){try library.install(.init(system:.snes,effects:[]))}
        #expect(throws:(any Error).self){try library.decodeImport(Data("{}".utf8))}
    }
}
actor GameGenieDownloadFake {
    var requests:[URL]=[]
    let failPage:Bool
    init(failPage:Bool=false){self.failPage=failPage}
    func fetch(_ url:URL)throws->GameGenieHTTPResponse {
        requests.append(url)
        let text:String,status:Int
        if url.path=="/robots.txt" {text="User-agent: *\nAllow: /\n";status=200}
        else if url.host=="www.danworld.com" {text="Personal noncommercial use. Preserve notices.";status=200}
        else if url.lastPathComponent=="index.html" {text="<a href='test.html'>Test Game</a><a href='test.html'>Test Game</a>";status=200}
        else {text="<pre>SXIOPO Named effect</pre>";status=failPage ? 503:200}
        return .init(data:Data(text.utf8),status:status,url:url,retryAfter:nil)
    }
}
struct GameGenieCatalogDownloadTests {
    @Test func downloadsOnceThenResumesVerifiedCacheAndCountsFailures() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let fake=GameGenieDownloadFake()
        let downloader=GameGenieCatalogDownload(fetch:{try await fake.fetch($0)},wait:{_ in})
        let result=try await downloader.run(system:.nes,cache:root,progress:{_ in})
        #expect(result.coverage.discovered==1 && result.coverage.fetched==1 && result.effects.count==1)
        #expect(await fake.requests.filter{$0.lastPathComponent=="test.html"}.count==1)
        _=try await downloader.run(system:.nes,cache:root,progress:{_ in})
        #expect(await fake.requests.filter{$0.lastPathComponent=="test.html"}.count==1)
        let failed=GameGenieDownloadFake(failPage:true),other=try testDirectory();defer{try? FileManager.default.removeItem(at:other)}
        let partial=try await GameGenieCatalogDownload(fetch:{try await failed.fetch($0)},wait:{_ in}).run(system:.nes,cache:other,progress:{_ in})
        #expect(partial.coverage.failedURLs.count==1 && !partial.coverage.complete)
    }
    @Test func robotsRestrictionsAndCancellationPreventPageRequests() async throws {
        #expect(!GameGenieCatalogDownload.robotsAllows("User-agent: *\nDisallow: /cheats/\n",url:GameGenieSystem.nes.indexURL))
        #expect(GameGenieCatalogDownload.robotsAllows("User-agent: *\nDisallow: /\nAllow: /cheats/gamegenie/nes/\n",url:GameGenieSystem.nes.indexURL))
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let task=Task {withUnsafeCurrentTask{$0?.cancel()};return try await GameGenieCatalogDownload(fetch:{_ in Issue.record("Cancelled download fetched");throw CancellationError()},wait:{_ in}).run(system:.nes,cache:root,progress:{_ in})}
        await #expect(throws:CancellationError.self){_=try await task.value}
    }
}

extension GameGenieCatalogDownloadTests {
    @Test func rateLimitsStopFurtherRequestsAndExposeResume() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let fake=GameGenieDownloadFake()
        let downloader=GameGenieCatalogDownload(fetch:{url in
            if url.lastPathComponent=="test.html" {return .init(data:Data(),status:429,url:url,retryAfter:"Wed, 21 Oct 2026 23:00:00 GMT")}
            return try await fake.fetch(url)
        },wait:{_ in})
        await #expect(throws:(any Error).self){_=try await downloader.run(system:.nes,cache:root,progress:{_ in})}
    }
    @Test func robotsMatchesLiteralPathsAndGroupedUserAgents() {
        let url=GameGenieSystem.nes.indexURL
        #expect(!GameGenieCatalogDownload.robotsAllows("User-agent: SwiftHakchiBetaCatalog\nUser-agent: OtherBot\nDisallow: /cheats/\n",url:url))
        let other=URL(string:"https://gamegenie.com/cheats/gamegenie/nes/indexXhtml")!
        #expect(!GameGenieCatalogDownload.robotsAllows("User-agent: *\nDisallow: /\nAllow: /cheats/gamegenie/nes/index.html\n",url:other))
    }
}

struct GameGenieBundledCatalogTests {
    @Test func freshWorkspaceBrowsesEveryBundledSystemWithoutGamesOrDownloadsAndKeepsLocalAdditions() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let bundle=root.appendingPathComponent("Bundle"),workspace=root.appendingPathComponent("EmptyWorkspace")
        try FileManager.default.createDirectory(at:bundle,withIntermediateDirectories:false)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:false)
        for system in GameGenieSystem.allCases {
            let code=system == .nes ? "SXIOPO":system == .snes ? "C2C9-4E2C":"ATBT-AA32"
            let catalog=GameGenieOfflineCatalog(system:system,effects:[.init(game:"Bundled game",codes:[code],title:"Synthetic bundled effect")])
            try catalog.encoded().write(to:bundle.appendingPathComponent("catalog-\(system.rawValue)-v2.json"))
        }
        let library=GameGenieCatalogLibrary(workspace:workspace,bundledCatalogDirectory:bundle)
        for system in GameGenieSystem.allCases {
            let value=try library.load(system)
            #expect(value?.searchGames("")==["Bundled game"])
        }
        #expect(!FileManager.default.fileExists(atPath:workspace.appendingPathComponent("Library").path))
        try library.install(.init(system:.nes,effects:[.init(game:"My added effect",codes:["GZUXNGEI"],title:"Personal")]))
        let merged=try library.load(.nes)
        #expect(merged?.effects.count==2)
        #expect(merged?.searchGames("")==["Bundled game","My added effect"])
        #expect(!FileManager.default.fileExists(atPath:workspace.appendingPathComponent("Library/Games").path))
    }
    @Test func wrongSystemOrLinkedBundledCatalogIsRefused() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let bytes=try GameGenieOfflineCatalog(system:.nes,effects:[]).encoded()
        let file=root.appendingPathComponent("catalog-snes-v2.json");try bytes.write(to:file)
        let library=GameGenieCatalogLibrary(workspace:root,bundledCatalogDirectory:root)
        #expect(throws:(any Error).self){try library.load(.snes)}
        try FileManager.default.removeItem(at:file)
        let target=root.appendingPathComponent("target.json");try bytes.write(to:target)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
        #expect(throws:(any Error).self){try library.load(.snes)}
    }
}

extension GameGenieBundledCatalogTests {
    @Test func explicitlyRequestedAppArtifactHasOfflineCodesWithoutALocalLibrary() throws {
        guard let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_BUNDLED_CODE_ARTIFACT"] else{return}
        let workspace=try testDirectory();defer{try? FileManager.default.removeItem(at:workspace)}
        let included=URL(fileURLWithPath:path).appendingPathComponent("Contents/Resources/GameGenieCatalogs")
        let library=GameGenieCatalogLibrary(workspace:workspace,bundledCatalogDirectory:included)
        for system in GameGenieSystem.allCases {
            let saved=try library.load(system)
            let catalog=try #require(saved)
            #expect(!catalog.effects.isEmpty && !catalog.searchGames("").isEmpty)
            print("OFFLINE BUNDLE \(system.name) games=\(catalog.searchGames("").count) effects=\(catalog.effects.count)")
        }
        let saved=try library.load(.snes)
        let snes=try #require(saved)
        #expect(snes.searchGames("Alien vs. Predator")==["Aliens vs. Predator"])
        #expect(snes.entries(game:"Aliens vs. Predator").count==47)
        #expect(!FileManager.default.fileExists(atPath:workspace.appendingPathComponent("Library").path))
    }
}

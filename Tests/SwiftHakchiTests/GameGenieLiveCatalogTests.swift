import Foundation
import Testing
@testable import SwiftHakchi
struct GameGenieLiveCatalogTests {
    @Test func explicitlyRequestedPersonalDownload() async throws {
        guard let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_PERSONAL_CODE_DOWNLOAD"] else{return}
        let root=URL(fileURLWithPath:path),library=GameGenieCatalogLibrary(workspace:root),folder=try library.folder(create:true)
        let downloads=folder.appendingPathComponent("Downloads")
        if !FileManager.default.fileExists(atPath:downloads.path) {try FileManager.default.createDirectory(at:downloads,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        for system in GameGenieSystem.allCases {
            let cache=downloads.appendingPathComponent(system.rawValue)
            if !FileManager.default.fileExists(atPath:cache.path) {try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
            let result=try await GameGenieCatalogDownload().run(system:system,cache:cache,progress:{value in
                if value.completed%25==0 || value.completed==value.total {print("CATALOG \(system.name) \(value.completed)/\(value.total) \(value.game)")}
            })
            let file=folder.appendingPathComponent("download-review-\(system.rawValue).json")
            try GameGenieCatalogLibrary.write(result.encoded(),to:file)
            print("REVIEW \(system.name) titles=\(result.searchGames("").count) effects=\(result.effects.count) fetched=\(result.coverage.fetched)/\(result.coverage.discovered) failed=\(result.coverage.failedURLs.count) review=\(result.coverage.reviewEntries) file=\(file.path)")
        }
    }
}

extension GameGenieLiveCatalogTests {
    @Test func explicitlyRequestedReviewedPersonalInstall() throws {
        guard let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_INSTALL_REVIEWED_CODES"] else{return}
        let library=GameGenieCatalogLibrary(workspace:URL(fileURLWithPath:path)),folder=try library.folder(create:true)
        for system in GameGenieSystem.allCases {
            let file=folder.appendingPathComponent("download-review-\(system.rawValue).json")
            let incoming=try GameGenieOfflineCatalog.decode(GameGenieCatalogLibrary.read(file))
            #expect(incoming.system==system && incoming.coverage.failedURLs.isEmpty && incoming.coverage.fetched==incoming.coverage.discovered)
            guard incoming.system==system,incoming.coverage.failedURLs.isEmpty,incoming.coverage.fetched==incoming.coverage.discovered else {throw GameGenieCatalog.CatalogError.invalid}
            let previous=try library.load(system)
            let merged=try previous?.merged(with:incoming) ?? incoming
            let repeatMerge=try merged.merged(with:incoming)
            #expect(repeatMerge.effects==merged.effects)
            try library.install(merged)
            let saved=try library.load(system)
            let loaded=try #require(saved)
            #expect(loaded.effects==merged.effects)
            print("INSTALLED \(system.name) games=\(loaded.searchGames("").count) effects=\(loaded.effects.count) review=\(loaded.coverage.reviewEntries) combined=\((previous?.effects.count ?? 0)+incoming.effects.count-loaded.effects.count)")
        }
    }
}

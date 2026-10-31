import Foundation
import Testing
@testable import SwiftHakchi

struct MetadataSearchTests {
    @Test func bundledSearchFindsPunctuationVariantsWithoutAPIKey() throws {
        let results = GameDatabase.shared.search(name: "Burgertime", consoleType: .nes)
        #expect(!results.isEmpty)
        #expect(results.contains { $0.title == "BurgerTime" && $0.region == "USA" })
        #expect(results.allSatisfy { !$0.id.isEmpty })
        #expect(Set(results.map(\.id)).count == results.count)
        #expect(GameDatabase.shared.search(name: "   ", consoleType: .nes).isEmpty)
    }
    @Test func candidateRegionsAndDatesStayDistinctAndPlatformsCannotMix() {
        let results = GameDatabase.shared.search(name: "Castlevania", consoleType: .nes)
        #expect(results.contains { $0.title == "Castlevania" && $0.region == "USA" && $0.releaseDate == "1987-05" })
        #expect(results.contains { $0.title == "Castlevania" && $0.region != "USA" })
        let snes = GameDatabase.shared.search(name: "Super Castlevania", consoleType: .snesUsa)
        #expect(snes.contains { $0.title.contains("Super Castlevania") })
        #expect(!snes.contains { $0.title == "Castlevania" })
        #expect(GameDatabase.shared.search(name: "Burgertime", consoleType: .unknown).isEmpty)
    }
}

extension MetadataSearchTests {
    @Test func genesisBundledResultsHaveTheirOwnMetadataAndNeverNintendoGames() throws {
        let results = GameDatabase.shared.search(name: "Sonic The Hedgehog", consoleType: .megaDrive)
        let sonic = try #require(results.first { $0.title == "Sonic The Hedgehog" && $0.releaseDate == "1991" && $0.publisher == "SEGA" })
        #expect(sonic.players == 1)
        #expect(results.allSatisfy { $0.platform == "genesis" })
        // Some unlicensed Genesis games share Nintendo-franchise titles: scope by platform, not franchise.
        #expect(GameDatabase.shared.search(name: "Super Mario World", consoleType: .megaDrive).allSatisfy { $0.platform == "genesis" })
        #expect(GameDatabase.shared.search(name: "Sonic", consoleType: .nes).allSatisfy { $0.platform == "nes" })
    }
    @Test func onlineGenesisSearchRequestsItsPlatformAndRejectsForeignOrUnidentifiedResults() async throws {
        let response = Data(#"{"data":{"games":[{"id":1,"game_title":"Shadowrun","platform":18,"release_date":"1994-01-01","players":1},{"id":2,"game_title":"Shadowrun","platform":6},{"id":3,"game_title":"Shadowrun"}]}}"#.utf8)
        let request = MetadataRequestCapture()
        let service = ScraperService(searchFetch: { url in await request.record(url); return response })
        let found = try await service.searchGames(name: "Shadowrun", apiKey: "test-key", platform: ScraperService.platformId(for: .megaDrive))
        #expect(found.map(\.id) == [1])
        let url = try #require(await request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "filter[platform]" }?.value == "18")
        #expect(found.first?.platform == "genesis")
        await #expect(throws: (any Error).self) { try await service.searchGames(name: "Sonic", apiKey: "test-key", platform: nil) }
    }
}
private actor MetadataRequestCapture {
    var url: URL?
    func record(_ url: URL) { self.url = url }
}

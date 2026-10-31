import Foundation
import Testing
@testable import SwiftHakchi

struct GameGenieCatalogTests {
    func catalog() throws -> GameGenieCatalog {
        try GameGenieCatalog.decode(Data(#"{"version":1,"system":"nes","workbookSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","workbookName":"User.xlsx","rows":[{"row":4,"game":"Test Game","number":"1","rawCodes":"SXIOPO + GZUXNGEI","effect":"Named effect","source":"Book"},{"row":5,"game":"Test Game","number":"2","rawCodes":"SXIOPO / GZUXNGEI","effect":"Choose revision","source":"Book"},{"row":6,"game":"Test Game","rawCodes":"Code 1 only works after restarting.","source":"Book"}]}"#.utf8))
    }
    @Test func groupsAlternativesAndNotesKeepTheirMeaning() throws {
        let catalog = try catalog()
        #expect(catalog.searchGames("testgame") == ["Test Game"])
        let rows = catalog.entries(game: "Test Game")
        #expect(rows.count == 2)
        #expect(rows[0].validCodes == ["SXIOPO", "GZUXNGEI"])
        #expect(rows[1].validCodes == nil)
        #expect(catalog.notes(game: "Test Game") == ["Code 1 only works after restarting."])
        let effect = try catalog.effect(from: rows[0])
        #expect(!effect.enabled)
        #expect(effect.source?.contains("NES row4") == true)
        #expect(effect.notes == ["Code 1 only works after restarting."])
        #expect(throws: (any Error).self) { try catalog.effect(from: rows[1]) }
    }
    @Test func invalidSchemaAndDuplicateRowIdentityAreRejected() throws {
        let original = try JSONEncoder().encode(catalog())
        let text = String(decoding: original, as: UTF8.self)
        #expect(throws: (any Error).self) { try GameGenieCatalog.decode(Data(text.replacingOccurrences(of: "\"system\":\"nes\"", with: "\"system\":\"snes\"").utf8)) }
        let duplicate = text.replacingOccurrences(of: "\"row\":5", with: "\"row\":4")
        #expect(throws: (any Error).self) { try GameGenieCatalog.decode(Data(duplicate.utf8)) }
        let old = try JSONDecoder().decode(GameGenieProfile.self, from: Data(#"{"version":1,"romSHA256":"old","effects":[{"id":"00000000-0000-0000-0000-000000000001","name":"Manual","codes":["SXIOPO"],"enabled":false}]}"#.utf8))
        #expect(old.effects[0].source == nil)
        #expect(old.effects[0].notes == nil)
    }
}

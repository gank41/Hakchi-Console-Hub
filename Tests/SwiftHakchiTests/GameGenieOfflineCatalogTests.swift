import Foundation
import Testing
@testable import SwiftHakchi

struct GameGenieOfflineCatalogTests {
    @Test func contraRomanNumeralMatchesTheSameGameOnly() {
        let catalog = GameGenieOfflineCatalog(system: .snes, effects: [
            .init(game: "Contra 3: The Alien Wars", codes: ["22BB-AD01"], title: "Example"),
            .init(game: "Contra 4", codes: ["D568-C34D"], title: "Different game")
        ])
        #expect(GameGenieSuggestions.rows(gameNames: ["CONTRA III THE ALIEN WARS"], system: .snes, catalog: catalog, existing: []).map(\.game) == ["Contra 3: The Alien Wars"])
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_SNES_CATALOG"] != nil,
                   "Requires an explicitly supplied private code catalog"))
    func suppliedCatalogOffersCodesForMatchingGames() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_SNES_CATALOG"])
        let catalog = try GameGenieOfflineCatalog.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        for title in ["NBA Hang Time", "Tecmo Super Bowl", "Legend of Zelda, The - A Link to the Past", "CONTRA III THE ALIEN WARS"] {
            #expect(!GameGenieSuggestions.rows(gameNames: [title], system: .snes, catalog: catalog, existing: []).isEmpty)
        }
    }
    @Test func suggestionsRequireAnExactGameAndKeepMultiCodeGroupsTogether() throws {
        let first = GameGenieOfflineCatalog.Entry(game: "Example", codes: ["C2C9-4E2C"], title: "First")
        let grouped = GameGenieOfflineCatalog.Entry(game: "Example", codes: ["D568-C34D", "DF47-0915"], title: "Grouped")
        let other = GameGenieOfflineCatalog.Entry(game: "Example 2", codes: ["FFFF-FFFF"], title: "Other game")
        let review = GameGenieOfflineCatalog.Entry(game: "Example", codes: [], title: "Needs review", alternatives: [["FFFF-FFFF"]], reviewReasons: ["Choose a version"])
        let catalog = GameGenieOfflineCatalog(system: .snes, effects: [first, grouped, other, review])
        let existing = [GameGenieEffect(name: "Already added", codes: first.codes, enabled: false)]
        let suggestions = GameGenieSuggestions.rows(gameNames: ["Example"], system: .snes, catalog: catalog, existing: existing)
        #expect(suggestions.map(\.title) == ["Grouped"])
        #expect(suggestions.first?.codes == grouped.codes)
        #expect(try catalog.effect(from: #require(suggestions.first)).enabled == false)
        #expect(GameGenieSuggestions.needsReview(gameNames: ["Example"], system: .snes, catalog: catalog))
        #expect(GameGenieSuggestions.needsReview(gameNames: ["Example 2"], system: .snes, catalog: catalog) == false)
        #expect(GameGenieSuggestions.rows(gameNames: ["Example"], system: .nes, catalog: catalog, existing: []).isEmpty)
        #expect(GameGenieSuggestions.rows(gameNames: ["Exam"], system: .snes, catalog: catalog, existing: []).isEmpty)
    }
    @Test func knownSNESTitleAliasesDoNotConfuseDifferentGames() {
        let catalog = GameGenieOfflineCatalog(system: .snes, effects: [
            .init(game: "Legend Of Zelda", codes: ["AEEC-A586"], title: "Example"),
            .init(game: "Gradius 3", codes: ["C2C9-4E2C"], title: "Example"),
            .init(game: "Mortal Kombat 2", codes: ["D568-C34D"], title: "Example"),
            .init(game: "Robocop vs. The Terminator", codes: ["DFB3-CD0D"], title: "Example"),
            .init(game: "Donkey Kong Country 2", codes: ["C2C9-4E2C"], title: "Example"),
            .init(game: "Super Return Of The Jedi", codes: ["D568-C34D"], title: "Example"),
            .init(game: "Terminator 2: The Arcade Game", codes: ["DF47-0915"], title: "Example"),
            .init(game: "Mortal Kombat 3", codes: ["DF47-0915"], title: "Example")
        ])
        #expect(GameGenieSuggestions.rows(gameNames: ["Legend of Zelda, The - A Link to the Past"], system: .snes, catalog: catalog, existing: []).map(\.game) == ["Legend Of Zelda"])
        #expect(GameGenieSuggestions.rows(gameNames: ["Gradius III"], system: .snes, catalog: catalog, existing: []).map(\.game) == ["Gradius 3"])
        #expect(GameGenieSuggestions.rows(gameNames: ["Mortal Kombat II"], system: .snes, catalog: catalog, existing: []).map(\.game) == ["Mortal Kombat 2"])
        #expect(GameGenieSuggestions.rows(gameNames: ["RoboCop versus The Terminator"], system: .snes, catalog: catalog, existing: []).map(\.game) == ["Robocop vs. The Terminator"])
        #expect(GameGenieSuggestions.rows(gameNames: ["Donkey Kong Country 2 - Diddy's Kong Quest"], system: .snes, catalog: catalog, existing: []).map(\.game) == ["Donkey Kong Country 2"])
        #expect(GameGenieSuggestions.rows(gameNames: ["Super Star Wars - Return of the Jedi"], system: .snes, catalog: catalog, existing: []).map(\.game) == ["Super Return Of The Jedi"])
        #expect(GameGenieSuggestions.rows(gameNames: ["T2 - The Arcade Game"], system: .snes, catalog: catalog, existing: []).map(\.game) == ["Terminator 2: The Arcade Game"])
    }
    @Test func legacyMigrationMergesRepeatedCodesWithoutLosingNotes() throws {
        let old=try GameGenieCatalogTests().catalog()
        let catalog=try GameGenieOfflineCatalog.migrating(old)
        #expect(catalog.system == .nes)
        #expect(catalog.searchGames("testgame")==["Test Game"])
        #expect(catalog.entries(game:"Test Game").count==2)
        #expect(catalog.entries(game:"Test Game")[0].notes.contains("Code 1 only works after restarting."))
        let row=GameGenieOfflineCatalog.Entry(game:"Test Game",codes:["SXIOPO","GZUXNGEI"],title:"Alternate wording",notes:["Keep this condition"],sources:["https://gamegenie.com/cheats/gamegenie/nes/test.html"])
        let incoming=GameGenieOfflineCatalog(system:.nes,effects:[row])
        let merged=try catalog.merged(with:incoming)
        #expect(merged.effects.count==2)
        #expect(merged.effects.contains{$0.notes.contains("Keep this condition") && $0.notes.contains("Also described as: Alternate wording")})
        #expect(try merged.merged(with:incoming).effects==merged.effects)
        #expect(try GameGenieOfflineCatalog.decode(merged.encoded()).effects==merged.effects)
    }
    @Test func versionsSystemsAndGroupDependenciesRemainDistinct() throws {
        let a=GameGenieOfflineCatalog.Entry(game:"Example",codes:["SXIOPO"],title:"Effect")
        let b=GameGenieOfflineCatalog.Entry(game:"Example",codes:["SXIOPO"],title:"Effect",context:"Revision B")
        let c=GameGenieOfflineCatalog.Entry(game:"Example",codes:[],title:"Choose revision",alternatives:[["SXIOPO"],["GZUXNGEI"]],reviewReasons:["Choose the correct revision"])
        let value=try GameGenieOfflineCatalog(system:.nes,effects:[a,b,c]).validated()
        #expect(value.effects.count==3 && Set(value.effects.map(\.id)).count==3)
        #expect(throws:(any Error).self){try value.merged(with:GameGenieOfflineCatalog(system:.genesis,effects:[]))}
        #expect(c.selectableCodes(system:.nes)==nil)
        let genesis=GameGenieOfflineCatalog.Entry(game:"Test",codes:["AE3T-AACL"],title:"Lives",dependencies:["ATBT-AA32"])
        #expect(genesis.selectableCodes(system:.genesis)==["ATBT-AA32","AE3T-AACL"])
        #expect(GameGenieSystem.snes.accepts("22BB-AD01"))
        #expect(!GameGenieSystem.genesis.accepts("SLAIUZ"))
    }
}

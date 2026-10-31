import Foundation
import Testing
@testable import SwiftHakchi

struct GameGenieOfflineCatalogTests {
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

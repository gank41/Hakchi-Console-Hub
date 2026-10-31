import Foundation
import Testing
@testable import SwiftHakchiCore

struct ConsoleMenuLimitTests {
    @Test(arguments: [20,25,30,35,40,45,50,60,70,80,90,100])
    func eachScreenshotLimitPreservesGamesAndCapsGamesPerPage(limit: Int) throws {
        let codes = (0..<201).map { String(format: "CLV-H-%05d", $0) }
        let pages = try MenuPaginator.pages(codes: codes, maximumGamesPerPage: limit)
        #expect(pages.flatMap(\.gameCodes) == codes)
        #expect(pages.allSatisfy { $0.gameCodes.count <= limit && $0.entryCount <= limit + 2 })
        #expect(pages.first?.previousPage == nil)
        #expect(pages.last?.nextPage == nil)
    }
    @Test func gameLimitDoesNotCountNavigationAsGames() throws {
        let codes = (0..<50).map { String(format: "CLV-H-%05d", $0) }
        let pages = try MenuPaginator.pages(codes: codes, maximumGamesPerPage: 25)
        #expect(pages.map { $0.gameCodes.count } == [25,25])
        #expect(pages.map(\.entryCount) == [26,26])
    }
    @Test func unsupportedSavedOrProgrammaticLimitsCannotCreateAPlan() {
        for limit in [0,19,26,49,101,Int.max] {
            #expect(throws: SyncPlanError.self) { try MenuPaginator.pages(codes: [], maximumGamesPerPage: limit) }
        }
    }
    @Test func actualSyncPlanCarriesTheChosenLimitAndPages() throws {
        let inputs = (0..<70).map { index in
            SyncGameInput(code: String(format: "CLV-P-%05d",index), name: String(format: "Game %03d",index),
                isStock: true, localDirectory: nil, romFilename: nil, desktopData: Data(), selected: true, byteCount: 0)
        }
        let plan = try SyncPlanner.makePlan(inputs: inputs, installedCodes: [], profile: .init(deviceID: "TEST", systemCode: "nes-usa"),
            freeBytes: 20_000_000, reserveBytes: 0, maximumGamesPerPage: 35)
        #expect(plan.maximumGamesPerPage == 35)
        #expect(plan.pages.map { $0.gameCodes.count } == [35,35])
        #expect(plan.pages.flatMap(\.gameCodes) == inputs.map(\.code))
    }
}

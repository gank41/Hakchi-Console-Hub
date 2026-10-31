import Foundation
import Testing
@testable import SwiftHakchiCore

struct PlanningTests {
    @Test(arguments: [0, 1, 28, 29, 30, 31, 1000])
    func pagesFitAndEveryGameAppearsOnce(count: Int) throws {
        let codes = (0..<count).map { String(format: "CLV-H-%05d", $0) }
        let pages = try MenuPaginator.pages(codes: codes, maximumEntries: 30)
        #expect(pages.flatMap(\.gameCodes) == codes)
        #expect(pages.allSatisfy { $0.entryCount <= 30 })
        #expect(pages.first?.number == 0)
        #expect(pages.first?.previousPage == nil)
        #expect(pages.last?.nextPage == nil)
        if count > 30 { #expect(pages.count > 1) }
    }

    @Test func malformedMenuIsRejected() {
        #expect(throws: SyncPlanError.self) { try MenuPaginator.pages(codes: ["CLV-S-00001"], maximumEntries: 30) }
        #expect(throws: SyncPlanError.self) { try MenuPaginator.pages(codes: ["../games"], maximumEntries: 30) }
        #expect(throws: SyncPlanError.self) { try MenuPaginator.pages(codes: ["CLV-H-AAAAA", "CLV-H-AAAAA"], maximumEntries: 30) }
        #expect(throws: SyncPlanError.self) { try MenuPaginator.pages(codes: [], maximumEntries: 2) }
    }

    @Test func capacityDoesNotBorrowFromGamesToBeRemoved() throws {
        let profile = ConsoleProfile(deviceID: "nes-one", systemCode: "nes-usa")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repo.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(count: 100).write(to: directory.appendingPathComponent("a.nes"))
        let input = SyncGameInput(code: "CLV-H-AAAAA", name: "Game", isStock: false,
            localDirectory: directory, romFilename: "a.nes", desktopData: Data(), selected: true, byteCount: 100)
        #expect(throws: SyncPlanError.insufficientSpace(required: 69762, available: 120)) {
            try SyncPlanner.makePlan(inputs: [input], installedCodes: ["CLV-H-BBBBB"], profile: profile, freeBytes: 120, reserveBytes: 30)
        }
    }

    @Test func emptyCustomSelectionKeepsSelectedStockAndReportsRemovals() throws {
        let profile = ConsoleProfile(deviceID: "nes-one", systemCode: "nes-usa")
        let stock = SyncGameInput(code: "CLV-P-NAAAE", name: "Mario", isStock: true,
            localDirectory: nil, romFilename: nil, desktopData: Data(), selected: true, byteCount: 0)
        let plan = try SyncPlanner.makePlan(inputs: [stock], installedCodes: ["CLV-H-AAAAA"], profile: profile,
            freeBytes: 20_000_000, reserveBytes: 10_000_000)
        #expect(plan.removedCodes == ["CLV-H-AAAAA"])
        #expect(plan.selectedGames.map(\.code) == ["CLV-P-NAAAE"])
    }

    @Test func selectedLocalFilesMustExist() throws {
        let profile = ConsoleProfile(deviceID: "nes-one", systemCode: "nes-usa")
        let missing = SyncGameInput(code: "CLV-H-AAAAA", name: "Missing", isStock: false,
            localDirectory: URL(fileURLWithPath: "/does-not-exist"), romFilename: "a.nes", desktopData: Data(), selected: true, byteCount: 1)
        #expect(throws: SyncPlanError.self) {
            try SyncPlanner.makePlan(inputs: [missing], installedCodes: [], profile: profile, freeBytes: 100_000, reserveBytes: 0)
        }
    }

    @Test func unknownProfileCannotPlanWrites() {
        #expect(throws: SyncPlanError.self) {
            try SyncPlanner.makePlan(inputs: [], installedCodes: [], profile: .init(deviceID: "", systemCode: "unknown"), freeBytes: 100_000, reserveBytes: 0)
        }
    }

    @Test func profilesKeepSeparateSelectionsThroughEncoding() throws {
        let a = ConsoleProfile(deviceID: "nes-a", systemCode: "nes-usa", selectedCustomCodes: ["CLV-H-AAAAA"])
        let b = ConsoleProfile(deviceID: "nes-b", systemCode: "nes-usa")
        let restored = try JSONDecoder().decode([ConsoleProfile].self, from: JSONEncoder().encode([a, b]))
        #expect(restored[0].selectedCustomCodes == ["CLV-H-AAAAA"])
        #expect(restored[1].selectedCustomCodes.isEmpty)
        #expect(a.storageKey != b.storageKey)
    }
}

struct LaunchCommandTests {
    @Test(arguments: [
        ("/bin/clover-kachikachi-wr /old/a.nes --volume 42", "/old/a.nes", "/bin/clover-kachikachi-wr '/new/a.nes' --volume 42"),
        ("/bin/clover-canoe-shvc-wr -rom '/old/My Game.sfrom' -lowlatency", "/old/My Game.sfrom", "/bin/clover-canoe-shvc-wr -rom '/new/a.nes' -lowlatency"),
        (#"/bin/retroarch-clover "/old/a.nes" --core fceumm --flag"#, "/old/a.nes", "/bin/retroarch-clover '/new/a.nes' --core fceumm --flag")
    ])
    func onlyROMTokenChanges(sample: (String, String, String)) throws {
        #expect(try LaunchCommand.replacingROM(in: sample.0, oldPath: sample.1, newPath: "/new/a.nes") == sample.2)
    }
    @Test(arguments: ["/bin/play $(touch /tmp/x) /old/a.nes", "/bin/play /old/a.nes; reboot", "/bin/play /old/a.nes /old/a.nes", "/bin/play '/unterminated", "/bin/play /no-match"])
    func unsafeOrAmbiguousCommandsAreRejected(command: String) {
        #expect(throws: SyncPlanError.self) {
            try LaunchCommand.replacingROM(in: command, oldPath: "/old/a.nes", newPath: "/new/a.nes")
        }
    }
    @Test func literalApostropheAndMetacharactersAreQuoted() throws {
        #expect(try LaunchCommand.replacingROM(in: "/bin/play /old/a.nes", oldPath: "/old/a.nes", newPath: "/new/Bob's $game.nes") == "/bin/play '/new/Bob'\"'\"'s $game.nes'")
    }
}

extension PlanningTests {
    @Test func sortNameControlsMenuPlacementWithNameFallback() throws {
        let zelda = SyncGameInput(code: "CLV-P-AAAAA", name: "Zelda", isStock: true, localDirectory: nil, romFilename: nil, desktopData: Data(), selected: true, byteCount: 0, sortName: "A Zelda")
        let mario = SyncGameInput(code: "CLV-P-BBBBB", name: "Mario", isStock: true, localDirectory: nil, romFilename: nil, desktopData: Data(), selected: true, byteCount: 0)
        let plan = try SyncPlanner.makePlan(inputs: [mario, zelda], installedCodes: [], profile: .init(deviceID: "TEST", systemCode: "nes-usa"), freeBytes: 1_000_000, reserveBytes: 0)
        #expect(plan.pages.flatMap(\.gameCodes) == [zelda.code, mario.code])
    }
}

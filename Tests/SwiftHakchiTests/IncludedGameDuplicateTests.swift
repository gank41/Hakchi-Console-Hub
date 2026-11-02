import Foundation
import Testing
@testable import SwiftHakchi
import SwiftHakchiCore

@MainActor struct IncludedGameDuplicateTests {
    @Test(arguments: [(ConsoleType.nes, "Super Mario Bros.", "nes"), (.snesUsa, "Super Mario World", "sfc")])
    func firstImportWarnsAboutBuiltInGamesWithoutAConnectedConsole(_ sample: (ConsoleType, String, String)) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = sample.0
        let file = root.appendingPathComponent(sample.1 + " (USA)." + sample.2)
        try Data([78, 69, 83, 26] + Array(repeating: UInt8(7), count: 128)).write(to: file)
        let manager = GameManagerService(config: config)
        var reviewed = false
        try manager.importROMs(urls: [file], consoleType: sample.0) { matches in
            reviewed = true
            #expect(matches.first?.builtInTitle == sample.1)
            return .keepCopies
        }
        #expect(reviewed)
        #expect(manager.games.count == 1 && !manager.games[0].isSelected)
    }
    @Test func offlineHintsStayWithinTheCorrectConsoleAndKeepCheatCopiesDistinct() {
        #expect(IncludedGameDuplicates.titleHint(title: "Super Mario World", console: .snesUsa, stock: []) == "Super Mario World")
        #expect(IncludedGameDuplicates.titleHint(title: "Super Mario World", console: .nes, stock: []) == nil)
        #expect(IncludedGameDuplicates.titleHint(title: "Super Mario World", console: .snesEur, stock: []) == nil)
        #expect(IncludedGameDuplicates.titleHint(title: "Super Mario World [Cheat Code]", console: .snesUsa, stock: []) == nil)
        #expect(IncludedGameDuplicates.titleHint(title: "Super Mario World 2 - Yoshi's Island", console: .snesUsa, stock: []) == "Yoshi's Island")
    }
    private func stock(_ title: String, console: ConsoleType = .nes) -> Game {
        Game(code: "CLV-P-AAAAA", desktopContent: "Code=CLV-P-AAAAA\nName=\(title)", consoleType: console, source: .stock)
    }
    @Test func titleMatchesStayWithinTheActualConsoleAndExcludeCheatCopies() {
        let original = stock("Super Mario Bros.")
        #expect(IncludedGameDuplicates.match(title: "SUPER MARIO BROS", console: .nes, stock: [original])?.name == "Super Mario Bros.")
        #expect(IncludedGameDuplicates.match(title: "Zelda 2: The Adventure of Link", console: .nes,
            stock: [stock("Zelda II - The Adventure of Link")]) != nil)
        #expect(IncludedGameDuplicates.match(title: "Edited title", originalTitle: "Super Mario Bros.", console: .nes, stock: [original]) != nil)
        #expect(IncludedGameDuplicates.match(title: "Super Mario Bros. [Cheat Code]", originalTitle: "Super Mario Bros.", console: .nes, stock: [original]) == nil)
        #expect(IncludedGameDuplicates.match(title: "Super Mario Bros.", console: .snesUsa, stock: [original]) == nil)
        #expect(IncludedGameDuplicates.match(title: "Super Mario Bros. 2", console: .nes, stock: [original]) == nil)
        #expect(IncludedGameDuplicates.match(title: "Super Mario Bros.", console: .unknown, stock: [original]) == nil)
    }
    @Test func commaArticleTitlesMatchAndRenamedCheatCopiesStayDistinct() {
        let original=stock("The Legend of Zelda: A Link to the Past",console:.snesUsa)
        #expect(IncludedGameDuplicates.match(title:"Legend of Zelda, The - A Link to the Past",console:.snesUsa,stock:[original]) != nil)
        #expect(IncludedGameDuplicates.match(title:"The Legend of Zelda: A Link to the Past",originalTitle:"The Legend of Zelda: A Link to the Past [Cheat Code]",console:.snesUsa,stock:[original]) == nil)
    }
    @Test(arguments: [IncludedGameImportChoice.skipMatches, .keepCopies, .cancel])
    func importDecisionPrecedesManagedWritesAndKeptMatchesAreUnchecked(choice: IncludedGameImportChoice) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path
        let source = root.appendingPathComponent("Super Mario Bros. (USA).nes")
        let other = root.appendingPathComponent("A new adventure.nes")
        let data = Data([78,69,83,26] + Array(repeating: UInt8(0), count: 60))
        try data.write(to: source)
        try (data + Data([1])).write(to: other)
        let manager = GameManagerService(config: config); manager.games = [stock("Super Mario Bros.")]
        var reviews = 0
        do {
            let result = try manager.importROMs(urls: [source, other], consoleType: .nes) { matches in
                reviews += 1
                #expect(matches.count == 1)
                #expect(matches.first?.builtInTitle == "Super Mario Bros.")
                #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
                return choice
            }
            #expect(choice != .cancel)
            #expect(reviews == 1)
            let locals = manager.games.filter { $0.source == .local }
            #expect(locals.count == (choice == .keepCopies ? 2 : 1))
            #expect(locals.first(where: { $0.name == "A New Adventure" })?.isSelected == true)
            if choice == .keepCopies {
                let duplicate = try #require(locals.first { $0.name == "Super Mario Bros." })
                #expect(!duplicate.isSelected)
                #expect(result.keptIncluded == 1)
                manager.setSelection(true, codes: [duplicate.code])
                #expect(manager.games.first { $0.code == duplicate.code }?.isSelected == true)
            } else { #expect(result.skippedIncluded == 1) }
        } catch is CancellationError {
            #expect(choice == .cancel)
            #expect(reviews == 1)
            #expect(manager.games.count == 1)
            #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
        }
        #expect(try Data(contentsOf: source) == data)
    }
}

@MainActor struct ReplacementDuplicateReviewTests {
    private func prepared() throws -> (URL,AppConfig,GameManagerService,URL,String) {
        let root=try testDirectory(),config=AppConfig();config.workspacePath=root.path
        let old=root.appendingPathComponent("Old game.nes"),incoming=root.appendingPathComponent("Super Mario Bros. (USA).nes")
        let bytes=Data([78,69,83,26]+Array(repeating:UInt8(0),count:60))
        try (bytes+Data([1])).write(to:old);try bytes.write(to:incoming)
        let manager=GameManagerService(config:config);try manager.importROMs(urls:[old],consoleType:.nes)
        let code=try #require(manager.games.first?.code)
        manager.games.append(Game(code:"CLV-P-AAAAA",desktopContent:"Code=CLV-P-AAAAA\nName=Super Mario Bros.",consoleType:.nes,source:.stock))
        manager.configureSelection(deviceID:"REPLACE-TEST",consoleType:.nes)
        manager.setSelection(true,codes:[code])
        return (root,config,manager,incoming,code)
    }
    @Test func canceledReplacementDoesNotArchiveOrChangeExistingSelections() throws {
        let (root,config,manager,incoming,code)=try prepared();defer{try? FileManager.default.removeItem(at:root)}
        let original=config.gamesDirectory.appendingPathComponent(code)
        var reviewed=false
        #expect(throws:CancellationError.self) {
            try manager.replaceLocalLibrary(urls:[incoming],consoleType:.nes,preservingEdits:true) {matches in
                reviewed=true;#expect(matches.count==1)
                #expect(FileManager.default.fileExists(atPath:original.path))
                #expect(manager.games.first(where:{$0.code==code})?.isSelected==true)
                return .cancel
            }
        }
        #expect(reviewed)
        #expect(manager.games.first(where:{$0.code==code})?.isSelected==true)
        let saved=try ConsoleProfileStore(directory:config.workspace.profiles).load(deviceID:"REPLACE-TEST",systemCode:"nes-usa")
        #expect(saved?.selectedCustomCodes==[code])
        #expect(FileManager.default.fileExists(atPath:original.path))
        #expect(!FileManager.default.fileExists(atPath:config.workspace.library.appendingPathComponent("Removed Libraries").path))
    }
    @Test func appReplacementRetainsStockEvidenceUntilTheChoiceIsMade() throws {
        let (root,config,manager,incoming,code)=try prepared();defer{try? FileManager.default.removeItem(at:root)}
        let app=AppState(startDeviceMonitoring:false,deviceManager:DeviceManager(),gameManager:manager,config:config,saveConfiguration:{})
        var reviewed=false
        #expect(throws:CancellationError.self) {
            try app.replaceImportedLibrary(urls:[incoming],console:.nes) {matches in
                reviewed=true;#expect(matches.first?.builtInTitle=="Super Mario Bros.")
                return .cancel
            }
        }
        #expect(reviewed)
        #expect(manager.games.first(where:{$0.code==code})?.isSelected==true)
        #expect(manager.games.contains(where:{$0.isStock}))
    }
}

@MainActor struct NativeSNESDuplicateTests {
    @Test func nativeCatalogWarnsWithoutAddingStockRowsOrResettingSelections() throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let config=AppConfig();config.workspacePath=root.path;config.lastConsoleType = .snesUsa
        let manager=GameManagerService(config:config)
        let frame=try SNESOriginalGamesFrame(originalGamesFrameFixture(),binding:originalGamesBinding(),challenge:originalGamesChallenge)
        try manager.rememberSNESOriginalGames(frame)
        #expect(manager.games.isEmpty)
        #expect(manager.includedCatalog(for: .snesUsa).map(\.name).contains("Été"))
        #expect(manager.includedCatalog(for: .nes).isEmpty)
        let source=root.appendingPathComponent("Été.sfc");try Data(repeating:7,count:128).write(to:source)
        var count=0
        try manager.importROMs(urls:[source],consoleType:.snesUsa) { matches in
            count += 1;#expect(matches.first?.builtInTitle=="Été");return .keepCopies
        }
        #expect(count==1)
        #expect(manager.games.count==1)
        #expect(manager.games.first?.isSelected==false)
        #expect(IncludedGameDuplicates.match(title:"Été",console:.snesUsa,stock:manager.knownIncludedGames) != nil)
        #expect(IncludedGameDuplicates.match(title:"Été",console:.nes,stock:manager.knownIncludedGames)==nil)
    }
}

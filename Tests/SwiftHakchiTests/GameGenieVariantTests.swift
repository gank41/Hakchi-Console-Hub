import Foundation
import Testing
@testable import SwiftHakchi

extension GameGenieTests {
    @Test func managedCopyIsExplicitAndUpdatesTheSameGameFromOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared, oldPath = config.workspacePath, oldType = config.lastConsoleType, oldID = config.lastDeviceId
        config.workspacePath = root.path; config.lastConsoleType = .nes; config.lastDeviceId = ""
        defer { config.workspacePath = oldPath; config.lastConsoleType = oldType; config.lastDeviceId = oldID }
        let bytes = NESROMIdentityTests.rom(), source = root.appendingPathComponent("Example.nes")
        try bytes.write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        var original = try #require(manager.games.first)
        original.commandLine = original.commandLine.replacingOccurrences(of: "--volume 75", with: "--volume 22")
        original.name = "My Game"; original.publisher = "My Publisher"; original.releaseDate = "1988"
        #expect(manager.saveGame(original))
        let session = try GameGenieWorkflow.open(game: original, manager: manager)
        let otherSource = root.appendingPathComponent("Other.nes")
        var otherBytes = bytes; otherBytes[18] ^= 1; try otherBytes.write(to: otherSource)
        try manager.importROMs(urls: [otherSource], consoleType: .nes)
        let otherCode = try #require(manager.games.first(where: { $0.code != original.code })?.code)
        var profile = try session.loadProfile()
        profile.effects = [GameGenieEffect(name: "First", codes: ["SXIOPO"], enabled: true)]
        try session.saveProfile(profile, manager: manager)
        #expect(manager.games.count == 2) // Saving codes is NOT opt-in to an extra game.
        #expect(try GameGenieVariantStore.existing(session: session, manager: manager) == nil)
        let added = try GameGenieVariantStore.save(session: session, profile: profile, manager: manager)
        #expect(manager.games.count == 3)
        #expect(added.name == "My Game [Cheat Code]")
        #expect(added.publisher == "My Publisher" && added.releaseDate == "1988")
        #expect(added.code != original.code)
        #expect(added.commandLine.contains("--volume 22"))
        #expect(manager.games.first(where: { $0.code == original.code })?.isSelected == true)
        #expect(manager.games.first(where: { $0.code == otherCode })?.isSelected == true)
        let variantROM = URL(fileURLWithPath: added.romPath).appendingPathComponent(added.code + ".nes")
        #expect(try Data(contentsOf: variantROM)[16 + 0x11D9] == 0xAD)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: session.romURL) == bytes)
        var edited = added; edited.commandLine = edited.commandLine.replacingOccurrences(of: "--volume 22", with: "--volume 45"); edited.publisher = "Variant edit"; #expect(manager.saveGame(edited))
        let second = GameGenieNES.encode(address: 0x9200, value: 0x55)
        profile.effects = [GameGenieEffect(name: "Second", codes: [second], enabled: true)]
        let updated = try GameGenieVariantStore.save(session: session, profile: profile, manager: manager)
        #expect(updated.code == added.code && manager.games.count == 3)
        #expect(updated.publisher == "Variant edit")
        #expect(updated.commandLine.contains("--volume 45"))
        let updatedBytes = try Data(contentsOf: variantROM)
        #expect(updatedBytes[16 + 0x11D9] == bytes[16 + 0x11D9])
        #expect(updatedBytes[16 + 0x1200] == 0x55)
        let reopened = try GameGenieWorkflow.open(game: updated, manager: manager)
        #expect(reopened.target.code == original.code)
        #expect(try reopened.loadProfile().enabledCodes == [second])
        profile.effects[0].enabled = false
        let off = try GameGenieVariantStore.save(session: reopened, profile: profile, manager: manager)
        #expect(off.code == added.code && manager.games.count == 3)
        #expect(try Data(contentsOf: variantROM) == bytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(off.coverArtPath))) == GameGenieVariantStore.artwork())
        #expect(try Data(contentsOf: session.romURL) == bytes)
        let stock = Game(code: "CLV-P-AAAAA", desktopContent: "Name=My Game\n", consoleType: .nes, source: .stock)
        let duplicates = try LegacyStockDuplicateReview.make(local: [off], stock: [stock], factoryROMHashes: [stock.code: GameGenieWorkflow.digest(bytes)])
        #expect(duplicates.rows.first?.evidence == .distinct) // An intentional Off copy must not disappear as a built-in duplicate.
        let inputs = try SyncPlanAdapter.inputs(games: [off])
        #expect(inputs.first?.romFilename == off.code + ".nes")
        // Legacy managed copies get new presentation without rewriting saved bytes.
        let desktopURL = URL(fileURLWithPath: off.romPath).appendingPathComponent(off.code + ".desktop")
        let legacy = DesktopFile(data: try Data(contentsOf: desktopURL))
        legacy.name = "My Game [Game Genie]"; legacy.defaultName = legacy.name; legacy.sortName = legacy.name
        let legacyData = legacy.toData(); try legacyData.write(to: desktopURL)
        manager.loadGames()
        let presented = try #require(manager.games.first(where: { $0.code == off.code }))
        #expect(presented.name == "My Game [Cheat Code]")
        #expect(presented.defaultName == "My Game [Cheat Code]")
        #expect(try Data(contentsOf: desktopURL) == legacyData)
        let legacySession = try GameGenieWorkflow.open(game: presented, manager: manager)
        #expect(legacySession.target.code == original.code)
        #expect(try Data(contentsOf: variantROM) == bytes)
        // The interim plural suffix also reopens as the exact singular title.
        legacy.name = "My Game [Cheat Codes]"; legacy.defaultName = legacy.name; legacy.sortName = legacy.name
        let pluralData = legacy.toData(); try pluralData.write(to: desktopURL)
        manager.loadGames()
        let plural = try #require(manager.games.first(where: { $0.code == off.code }))
        #expect(plural.name == "My Game [Cheat Code]")
        #expect(try Data(contentsOf: desktopURL) == pluralData)
        let renamed = try GameGenieVariantStore.save(session: legacySession, profile: profile, manager: manager)
        #expect(renamed.name == "My Game [Cheat Code]" && renamed.code == off.code)
        #expect(manager.games.count == 3)
        #expect(try Data(contentsOf: variantROM) == bytes)

    }

    @Test func noInitialCopyWithoutEnabledEffectsAndTamperedCopiesAreNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared, oldPath = config.workspacePath, oldType = config.lastConsoleType
        config.workspacePath = root.path; config.lastConsoleType = .nes
        defer { config.workspacePath = oldPath; config.lastConsoleType = oldType }
        let source = root.appendingPathComponent("Example.nes"); try NESROMIdentityTests.rom().write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let session = try GameGenieWorkflow.open(game: #require(manager.games.first), manager: manager)
        var profile = try session.loadProfile()
        #expect(throws: (any Error).self) { try GameGenieVariantStore.save(session: session, profile: profile, manager: manager) }
        #expect(manager.games.count == 1)
        profile.effects = [GameGenieEffect(name: "First", codes: ["SXIOPO"], enabled: true)]
        let copy = try GameGenieVariantStore.save(session: session, profile: profile, manager: manager)
        let rom = URL(fileURLWithPath: copy.romPath).appendingPathComponent(copy.code + ".nes")
        let changed = Data([1, 2, 3]); try changed.write(to: rom)
        #expect(throws: (any Error).self) { try GameGenieVariantStore.save(session: session, profile: profile, manager: manager) }
        #expect(try Data(contentsOf: rom) == changed)
        #expect(manager.games.count == 2)
    }
    @Test func unownedDestinationAndChangedOriginalAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared, oldPath = config.workspacePath, oldType = config.lastConsoleType
        config.workspacePath = root.path; config.lastConsoleType = .nes
        defer { config.workspacePath = oldPath; config.lastConsoleType = oldType }
        let source = root.appendingPathComponent("Example.nes"); try NESROMIdentityTests.rom().write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let session = try GameGenieWorkflow.open(game: #require(manager.games.first), manager: manager)
        var profile = try session.loadProfile()
        profile.effects = [GameGenieEffect(name: "Test", codes: ["SXIOPO"], enabled: true)]
        let occupied = config.gamesDirectory.appendingPathComponent(GameGenieVariantStore.code(for: session))
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: occupied.appendingPathComponent("unowned"))
        #expect(throws: (any Error).self) { try GameGenieVariantStore.save(session: session, profile: profile, manager: manager) }
        #expect(try Data(contentsOf: occupied.appendingPathComponent("unowned")) == Data("keep".utf8))
        try FileManager.default.removeItem(at: occupied)
        let revisions = root.appendingPathComponent("Library/Game Genie Revisions")
        try FileManager.default.createSymbolicLink(at: revisions, withDestinationURL: config.gamesDirectory)
        #expect(throws: (any Error).self) { try GameGenieVariantStore.save(session: session, profile: profile, manager: manager) }
        try FileManager.default.removeItem(at: revisions)
        var changed = try Data(contentsOf: session.romURL); changed[17] ^= 1; try changed.write(to: session.romURL)
        #expect(throws: (any Error).self) { try GameGenieVariantStore.save(session: session, profile: profile, manager: manager) }
        #expect(manager.games.count == 1)
    }
}

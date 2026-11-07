import Foundation
import Testing
@testable import SwiftHakchi

@Suite(.serialized) @MainActor
struct GameGenieTests {
    @Test func importedGameCanBeIdentifiedEvenWhenCheatPatchingIsUnsupported() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let old = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = old }
        let source = root.appendingPathComponent("Console Game.sfc")
        let bytes = Data(repeating: 42, count: 65536); try bytes.write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .snesUsa)
        let game = try #require(manager.games.first)
        #expect(try GameGenieWorkflow.managedSourceDigest(game: game, manager: manager) == GameGenieWorkflow.digest(bytes))
        #expect(throws: (any Error).self) { try GameGenieWorkflow.open(game: game, manager: manager) }
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test func codecMatchesIndependentWindowsKnownAnswersAndRejectsWrongType() throws {
        let six = try #require(GameGenieNES.decode("SXIOPO"))
        #expect(six.address == 0x91D9); #expect(six.value == 0xAD); #expect(six.compare == nil)
        let eight = try #require(GameGenieNES.decode("GZUXNGEI"))
        #expect(eight.address == 0xAC3F); #expect(eight.value == 0x24); #expect(eight.compare == 0xD0)
        #expect(GameGenieNES.encode(address: 0xAC3F, value: 0x24, compare: 0xD0) == "GZUXNGEI")
        #expect(GameGenieNES.decode("APZLGITY") == nil) // eight letters with six-letter type bit
        #expect(GameGenieNES.decode("GZUXNG") == nil)
        #expect(GameGenieNES.decode("invalid!") == nil)
    }
    @Test func patchingTouchesOnlyPRGAndMatchesCompareBanks() throws {
        var rom = NESROMIdentityTests.rom(trainer: true, trailer: 127)
        let start = 16 + 512
        rom[start + 0x0C3F] = 0xD0
        let before = rom
        let result = try NESGameGeniePatcher.patch(data: rom, codes: ["GZUXNGEI"])
        #expect(result.offsets == [start + 0x0C3F])
        #expect(result.data[start + 0x0C3F] == 0x24)
        var expected = before; expected[start + 0x0C3F] = 0x24
        #expect(result.data == expected)
        #expect(rom == before)
        #expect(throws: GameGenieError.self) { try NESGameGeniePatcher.patch(data: before, codes: ["GZUXNGEI", "APZLGITY"]) }
        #expect(throws: GameGenieError.self) { try NESGameGeniePatcher.patch(data: NESROMIdentityTests.rom(), codes: ["GZUXNGEI"]) }
    }
    @Test func sixLetterPatchUsesSmallROMAddressAndRejectsConflicts() throws {
        let rom = NESROMIdentityTests.rom()
        let result = try NESGameGeniePatcher.patch(data: rom, codes: ["SXIOPO"])
        #expect(result.offsets == [16 + 0x11D9]) // 16 KiB PRG wraps CPU address
        #expect(result.data[16 + 0x11D9] == 0xAD)
        let conflict = GameGenieNES.encode(address: 0x91D9, value: 0xAE)
        #expect(throws: GameGenieError.self) { try NESGameGeniePatcher.patch(data: rom, codes: ["SXIOPO", conflict]) }
        var bad = rom; bad[7] = 8
        #expect(throws: (any Error).self) { try NESGameGeniePatcher.patch(data: bad, codes: ["SXIOPO"]) }
    }
    @Test func profilesAndExportsAreROMBoundAndPreserveManagedBytes() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let old = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = old }
        let source = root.appendingPathComponent("source.nes"); let bytes = NESROMIdentityTests.rom(); try bytes.write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let game = try #require(manager.games.first)
        let session = try GameGenieWorkflow.open(game: game, manager: manager)
        var profile = try session.loadProfile()
        profile.effects = [GameGenieEffect(name: "Test effect", codes: ["SXIOPO"], enabled: true)]
        try session.saveProfile(profile, manager: manager)
        #expect(try session.loadProfile().effects.first?.name == "Test effect")
        let destination = try session.export(profile, manager: manager)
        #expect(try Data(contentsOf: destination).count == bytes.count)
        #expect(try Data(contentsOf: destination)[16 + 0x11D9] == 0xAD)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: session.romURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: game.romPath).appendingPathComponent("game-genie.json").path))
        var changed = bytes; changed[17] ^= 1; try changed.write(to: session.romURL)
        #expect(throws: GameGenieError.self) { try session.export(profile, manager: manager) }
        #expect(try Data(contentsOf: destination)[16 + 0x11D9] == 0xAD)
    }
}

extension GameGenieTests {
    @Test func bankedPatchesScanEveryPRGBankAndRejectPartialEffects() throws {
        var data = Data([78,69,83,26,4,1,0,0] + Array(repeating: 0, count: 8))
        data.append(Data(repeating: 17, count: 65536)); data.append(Data(repeating: 29, count: 8192))
        data[16 + 0x0C3F] = 0xD0; data[16 + 0x4C3F] = 0xD0
        let result = try NESGameGeniePatcher.patch(data: data, codes: ["GZUXNGEI"])
        #expect(result.offsets == [16 + 0x0C3F, 16 + 0x4C3F])
        #expect(result.data[16 + 0x2C3F] == 17)
        #expect(result.data.suffix(8192) == Data(repeating: 29, count: 8192))
        let unprotected = try NESGameGeniePatcher.patch(data: data, codes: ["SXIOPO"])
        #expect(unprotected.offsets == [4585,12777,20969,29161,37353,45545,53737,61929])
        #expect(throws: GameGenieError.self) { try NESGameGeniePatcher.patch(data: data, codes: []) }
        var profile = GameGenieProfile(romSHA256: "first")
        profile.effects = [GameGenieEffect(name: "Multi code effect", codes: ["SXIOPO", "GZUXNGEI"], enabled: false)]
        #expect(profile.enabledCodes.isEmpty)
        profile.effects[0].enabled = true
        #expect(profile.enabledCodes == ["SXIOPO", "GZUXNGEI"])
        #expect(throws: GameGenieError.self) { try profile.validate(sha256: "different") }
        #expect(GameGenieEffect.codes(from: "sxioPO; GZUXNGEI\n") == ["SXIOPO", "GZUXNGEI"])
    }
}

extension GameGenieTests {
    @Test func correctedHeaderReimportStartsFreshAndKeepsPreviousRevisionProfile() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let old = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = old }
        let source = root.appendingPathComponent("original.nes"); let original = NESROMIdentityTests.rom(); try original.write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let first = try #require(manager.games.first)
        let firstSession = try GameGenieWorkflow.open(game: first, manager: manager)
        var firstProfile = try firstSession.loadProfile()
        firstProfile.effects = [GameGenieEffect(name: "Old revision", codes: ["SXIOPO"], enabled: true)]
        try firstSession.saveProfile(firstProfile, manager: manager)
        manager.deleteGame(first)
        var corrected = original; corrected[6] = 1; try corrected.write(to: source)
        try manager.importROMs(urls: [source], consoleType: .nes)
        let second = try #require(manager.games.first)
        #expect(second.code == first.code)
        let secondSession = try GameGenieWorkflow.open(game: second, manager: manager)
        #expect(try secondSession.loadProfile().effects.isEmpty)
        try secondSession.saveProfile(secondSession.loadProfile(), manager: manager)
        #expect(try firstSession.loadProfile().effects.first?.name == "Old revision")
        #expect(try Data(contentsOf: source) == corrected)
    }
    @Test func linkedOutputParentsCannotPutProfilesIntoGamesOrExportsOutsideWorkspace() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let old = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = old }
        let source = root.appendingPathComponent("original.nes"); try NESROMIdentityTests.rom().write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let game = try #require(manager.games.first), session = try GameGenieWorkflow.open(game: game, manager: manager)
        var profile = try session.loadProfile(); profile.effects = [GameGenieEffect(name: "Test", codes: ["SXIOPO"], enabled: true)]
        let cheats = root.appendingPathComponent("Library/Cheats")
        try FileManager.default.createDirectory(at: cheats, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cheats.appendingPathComponent(session.target.gamesDirectory.lastPathComponent), withDestinationURL: URL(fileURLWithPath: game.romPath))
        #expect(throws: GameGenieError.self) { try session.saveProfile(profile, manager: manager) }
        let exports = root.appendingPathComponent("Exports"); let redirected = root.appendingPathComponent("redirected")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: exports.appendingPathComponent("CheatCodes"), withDestinationURL: redirected)
        #expect(throws: GameGenieError.self) { try session.export(profile, manager: manager) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: game.romPath).appendingPathComponent(game.code + ".json").path))
    }
}

extension GameGenieTests {
    @Test func oversizedAnnotatedProfileCannotReplaceAReadableSavedProfile() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let old = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = old }
        let source = root.appendingPathComponent("test.nes"); try NESROMIdentityTests.rom().write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let game = try #require(manager.games.first), session = try GameGenieWorkflow.open(game: game, manager: manager)
        var safe = try session.loadProfile(); safe.effects = [GameGenieEffect(name: "Safe", codes: ["SXIOPO"], enabled: true)]
        safe.effects[0].notes = Array(repeating: String(repeating: "N", count: 8192), count: 32)
        try session.saveProfile(safe, manager: manager)
        #expect(try session.loadProfile() == safe)
        var large = safe
        // Escaped JSON size exceeds 1 MiB although raw string bytes do not.
        large.effects[0].notes = Array(repeating: String(repeating: "\u{0000}", count: 8192), count: 32)
        #expect(throws: GameGenieError.self) { try session.saveProfile(large, manager: manager) }
        #expect(try session.loadProfile() == safe)
        #expect(throws: GameGenieError.self) { try session.exportRetroArch(large, manager: manager) }
    }
}

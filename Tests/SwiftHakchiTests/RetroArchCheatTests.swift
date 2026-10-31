import Foundation
import Testing
@testable import SwiftHakchi

@Suite(.serialized) @MainActor
struct RetroArchCheatTests {
    @Test func exportsWholeNamedGroupsDisabledUsingCoreHandler() throws {
        var profile = GameGenieProfile(romSHA256: "test")
        profile.effects = [GameGenieEffect(name: "Named effect", codes: ["SXIOPO", "GZUXNGEI"], enabled: true)]
        let text = String(decoding: try RetroArchCheatFile.encode(profile: profile), as: UTF8.self)
        #expect(text.contains("cheats = 1\n"))
        #expect(text.contains("cheat0_desc = \"Named effect\"\n"))
        #expect(text.contains("cheat0_code = \"SXIOPO+GZUXNGEI\"\n"))
        #expect(text.contains("cheat0_handler = 0\n"))
        #expect(text.contains("cheat0_enable = false\n"))
        #expect(!text.contains("= true"))
    }
    @Test func labelsCannotInjectKeysAndSameAddressGroupsFailInsteadOfDroppingCodes() throws {
        var profile = GameGenieProfile(romSHA256: "test")
        profile.effects = [GameGenieEffect(name: "Lives\" #\ncheat99_enable = true\\\u{0000}\u{2028}", codes: ["SXIOPO"])]
        let text = String(decoding: try RetroArchCheatFile.encode(profile: profile), as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("cheat0_desc = \"Lives' # cheat99_enable = true/\""))
        #expect(!lines.contains("cheat99_enable = true"))
        let conflict = GameGenieNES.encode(address: 0x91D9, value: 0xAE)
        profile.effects[0].codes.append(conflict)
        #expect(throws: (any Error).self) { try RetroArchCheatFile.encode(profile: profile) }
    }
    @Test func runtimeExportContainsNoROMAndRejectsChangedSource() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let old = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = old }
        let source = root.appendingPathComponent("test.nes"); let bytes = NESROMIdentityTests.rom(); try bytes.write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let game = try #require(manager.games.first), session = try GameGenieWorkflow.open(game: game, manager: manager)
        var profile = try session.loadProfile(); profile.effects = [GameGenieEffect(name: "Named", codes: ["SXIOPO"])]
        let exported = try session.exportRetroArch(profile, manager: manager)
        #expect(exported.pathExtension == "cht")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: exported.deletingLastPathComponent().path)) == [game.code + ".cht", "manifest.json", "READ-ME.txt"])
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: session.romURL) == bytes)
        var changed = bytes; changed[17] ^= 1; try changed.write(to: session.romURL)
        #expect(throws: GameGenieError.self) { try session.exportRetroArch(profile, manager: manager) }
    }
}

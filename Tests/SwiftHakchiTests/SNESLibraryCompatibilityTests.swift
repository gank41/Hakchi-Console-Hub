import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCompatibilityTests {
    func fixture(_ root: URL, code: String = "CLV-U-ABCDE", title: String = "Other", rom: Data? = nil) throws -> Game {
        let directory = root.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (rom ?? oneGameSyntheticROM()).write(to: directory.appendingPathComponent(code + ".sfc"))
        var game = Game(code: code, desktopContent: "Name=\(title)\n", consoleType: .snesUsa, source: .local)
        game.romPath = directory.path
        return game
    }
    func originals() throws -> SNESOriginalGamesFrame {
        try .init(originalGamesFrameFixture(), binding: originalGamesBinding(), challenge: originalGamesChallenge)
    }
    @Test(arguments: ["PAL", "checksum", "adapter"])
    func reviewSeparatesMissingAppSupportFromFileChecks(_ kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var rom = oneGameSyntheticROM()
        if kind == "PAL" { rom[0x7fd9] = 2 }
        if kind == "adapter" {
            rom.replaceSubrange(0x7fc0..<0x7fd5, with: Data("Super GAMEBOY        ".utf8))
            rom[0x7fd6] = 0xe3
        }
        rom[0x7fdc] = 255; rom[0x7fdd] = 255; rom[0x7fde] = 0; rom[0x7fdf] = 0
        let checksum = rom.reduce(0) { $0 + Int($1) } & 65535
        rom[0x7fdc] = UInt8((checksum ^ 65535) & 255); rom[0x7fdd] = UInt8((checksum ^ 65535) >> 8)
        rom[0x7fde] = UInt8(checksum & 255); rom[0x7fdf] = UInt8(checksum >> 8)
        if kind == "checksum" { rom[0] ^= 1 }
        let game = try fixture(root, rom: rom)
        let row = try #require(SNESLibraryCompatibility.review(games: [game], originals: originals()).rows.first)
        #expect(row.prepared == nil && row.preparationError != nil)
        #expect(row.readiness == (kind == "PAL" ? .appSupportNeeded : kind == "adapter" ? .notStandalone : .fileCheck))
        #expect(game.isSelected)
    }
    @Test func exactDuplicateUsesPayloadIdentityRatherThanWholeContainerHash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = try fixture(root), payload = BackupManifest.digest(oneGameSyntheticROM())
        let review = try SNESLibraryCompatibility.review(games: [game], originals: originals(), stockPayloadSHA256: ["CLV-P-AAAAA": payload])
        let row = try #require(review.rows.first)
        #expect(row.evidence == .exact && row.matches == ["CLV-P-AAAAA"])
        #expect(row.prepared?.sourcePayloadSHA256 == payload)
        #expect(row.prepared?.data.count == oneGameSyntheticROM().count + 96)
        #expect(!row.needsDecision && row.issue == nil)
        #expect(try review.resolvedCodes(selected: [game.code], decisions: [:]) == review.stockCodes)
        let absent = try SNESLibraryCompatibility.review(games: [game], originals: originals())
        #expect(absent.rows.first?.evidence == .distinct) // No payload claim from container hash.
    }
    @Test func ambiguousTitleRequiresChoiceAndUnsupportedGameStaysSelected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let matching = try fixture(root, title: "ETE"), invalid = try fixture(root, code: "CLV-U-BCDEF", rom: Data([0, 1]))
        let review = try SNESLibraryCompatibility.review(games: [matching, invalid], originals: originals())
        let row = try #require(review.rows.first(where: { $0.game.code == matching.code }))
        #expect(row.evidence == .possible && row.matches.count == 2 && row.needsDecision)
        #expect(review.rows.first(where: { $0.game.code == invalid.code })?.issue != nil)
        #expect(matching.isSelected && invalid.isSelected && review.rows.count == 2)
        #expect(throws: (any Error).self) { try review.resolvedCodes(selected: [matching.code], decisions: [:]) }
        #expect(try review.resolvedCodes(selected: [matching.code], decisions: [matching.code: .keepBuiltIn]) == review.stockCodes)
        #expect(throws: (any Error).self) { try review.resolvedCodes(selected: [invalid.code], decisions: [:]) }
        #expect(throws: (any Error).self) { try review.resolvedCodes(selected: [matching.code], decisions: [matching.code: .keepImported]) }
    }
    @Test func reviewBindsTheSourceAndRejectsLinkedOrAmbiguousROMs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = try fixture(root), file = URL(fileURLWithPath: game.romPath).appendingPathComponent(game.code + ".sfc")
        let review = try SNESLibraryCompatibility.review(games: [game], originals: originals())
        let source = try #require(review.rows.first?.source)
        try source.verify()
        var changed = oneGameSyntheticROM(); changed[0] ^= 1; try changed.write(to: file)
        #expect(throws: (any Error).self) { try source.verify() }
        let target = root.appendingPathComponent("outside.sfc"); try oneGameSyntheticROM().write(to: target)
        try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let linked = try SNESLibraryCompatibility.review(games: [game], originals: originals())
        #expect(linked.rows.first?.prepared == nil && linked.rows.first?.issue != nil)
        try FileManager.default.removeItem(at: file); try FileManager.default.linkItem(at: target, to: file)
        #expect(try SNESLibraryCompatibility.review(games: [game], originals: originals()).rows.first?.issue != nil)
        try FileManager.default.removeItem(at: file); try oneGameSyntheticROM().write(to: file)
        try oneGameSyntheticROM().write(to: file.deletingPathExtension().appendingPathExtension("smc"))
        #expect(try SNESLibraryCompatibility.review(games: [game], originals: originals()).rows.first?.issue != nil)
    }
}

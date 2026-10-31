import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESCompatibilityLaunchRequestTests {
    @Test @MainActor func preparesSelectedCompatibilityGamesAsOneReviewedBatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func row(_ code: String, _ bytes: Data, matches: [String] = [], evidence: SNESLibraryCompatibility.Evidence = .distinct) throws -> SNESLibraryCompatibility.Row {
            let dir = root.appendingPathComponent(code, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: dir.appendingPathComponent("game.sfc"))
            var game = Game(code: code, desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local)
            game.romPath = dir.path
            let source = try SNESLibraryROMSource.capture(directory: dir, filename: "game.sfc").0
            return .init(game: game, source: source, prepared: nil, issue: "Compatibility support needed", matches: matches, evidence: evidence, preparationError: .unsupportedCartridge)
        }
        let first = try row("CLV-U-ABCDE", Data([1,2,3]))
        let second = try row("CLV-U-FGHIJ", Data([4,5,6]), matches: ["CLV-P-ABCDE"], evidence: .possible)
        let review = SNESLibraryCompatibility(rows: [first, second], stockCodes: ["CLV-P-ABCDE"])
        let a = Data([1] + Array(repeating: 0, count: 15)), b = Data([2] + Array(repeating: 0, count: 15))
        let chosen: Set<String> = [first.game.code, second.game.code]
        let sessions = [first.game.code: a, second.game.code: b]
        let batch = try review.prepareCompatibilityLaunches(selected: chosen, decisions: [second.game.code: .keepImported], sessions: sessions, epoch: 7)
        #expect(Set(batch.keys) == chosen)
        #expect(batch[first.game.code]?.frame != batch[second.game.code]?.frame)
        let kept = try review.prepareCompatibilityLaunches(selected: chosen, decisions: [second.game.code: .keepBuiltIn], sessions: [first.game.code: a], epoch: 7)
        #expect(Set(kept.keys) == [first.game.code])
        #expect(throws: (any Error).self) { try review.prepareCompatibilityLaunches(selected: chosen, decisions: [:], sessions: sessions, epoch: 7) }
        #expect(throws: (any Error).self) { try review.prepareCompatibilityLaunches(selected: chosen, decisions: [second.game.code: .keepImported], sessions: [first.game.code: a, second.game.code: a], epoch: 7) }
        #expect(throws: (any Error).self) { try review.prepareCompatibilityLaunches(selected: chosen, decisions: [second.game.code: .keepImported], sessions: [first.game.code: a], epoch: 7) }
        #expect(throws: (any Error).self) { try review.prepareCompatibilityLaunches(selected: chosen, decisions: [second.game.code: .keepBuiltIn], sessions: sessions, epoch: 7) }
        #expect(throws: (any Error).self) { try review.prepareCompatibilityLaunches(selected: chosen, decisions: [second.game.code: .keepImported], sessions: [first.game.code: Data(repeating: 0, count: 16), second.game.code: b], epoch: 7) }
        let third = try row("CLV-U-KLMNO", Data([7,8,9]), matches: ["CLV-P-ABCDE"], evidence: .possible)
        let conflict = SNESLibraryCompatibility(rows: [second, third], stockCodes: ["CLV-P-ABCDE"])
        #expect(throws: (any Error).self) {
            try conflict.prepareCompatibilityLaunches(selected: [second.game.code, third.game.code], decisions: [second.game.code: .keepImported, third.game.code: .keepBuiltIn], sessions: [second.game.code: a], epoch: 7)
        }
        try Data([9]).write(to: root.appendingPathComponent(second.game.code).appendingPathComponent("game.sfc"))
        #expect(throws: (any Error).self) { try review.prepareCompatibilityLaunches(selected: chosen, decisions: [second.game.code: .keepImported], sessions: sessions, epoch: 7) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_ACTUAL_PREFLIGHT_HELPER"] != nil))
    func actualSelectedGameAndARMHelperPrepareWithoutChangingTheSource() throws {
        let env = ProcessInfo.processInfo.environment
        let helperURL = URL(fileURLWithPath: try #require(env["HC_ACTUAL_PREFLIGHT_HELPER"]))
        let gameDirectory = URL(fileURLWithPath: try #require(env["HC_ACTUAL_GAME_DIRECTORY"]), isDirectory: true)
        let name = try #require(env["HC_ACTUAL_GAME_FILENAME"])
        let code = gameDirectory.lastPathComponent
        var game = Game(code: code, desktopContent: "Name=Selected Game\n", consoleType: .snesUsa, source: .local)
        game.romPath = gameDirectory.path
        let (source, original) = try SNESLibraryROMSource.capture(directory: gameDirectory, filename: name)
        let request = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source,
            session: Data([7] + Array(repeating: 0, count: 15)), epoch: 4)
        let helper = try Data(contentsOf: helperURL)
        let material = try SNESCompatibilityPreflightMaterial.prepare(request: request, helper: helper,
            expectedHelperSHA256: try #require(env["HC_ACTUAL_HELPER_SHA"]))
        #expect(material.rom == original && material.helper == helper)
        if let path = env["HC_ACTUAL_REVIEWED_FRAME"] { try request.frame.write(to: URL(fileURLWithPath: path)) }
        #expect(try Data(contentsOf: gameDirectory.appendingPathComponent(name)) == original)
    }
    @Test func bindsSelectedGameAndCurrentROMToCanonicalFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1,2,3,4]).write(to: dir.appendingPathComponent("game.sfc"))
        var game = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local)
        game.romPath = dir.path
        let source = try SNESLibraryROMSource.capture(directory: dir, filename: "game.sfc").0
        let token = Data([1] + Array(repeating: 0, count: 15))
        let result = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: token, epoch: 7)
        var expected = Data("HCLREQ1\0CLV-U-ABCDE\(source.sha256)".utf8)
        expected.append(token); expected.append(contentsOf: [7,0,0,0,0,0,0,0])
        #expect(result.frame == expected)
        #expect(result.frame.count == 107)
        var helper = Data(repeating: 0, count: 52)
        helper.replaceSubrange(0..<7, with: [0x7f, 0x45, 0x4c, 0x46, 1, 1, 1])
        helper[16] = 2; helper[18] = 40; helper[36] = 0; helper[37] = 4; helper[39] = 5
        let material = try SNESCompatibilityPreflightMaterial.prepare(request: result, helper: helper, expectedHelperSHA256: BackupManifest.digest(helper))
        #expect(material.rom == Data([1,2,3,4]))
        #expect(material.helper == helper && material.command.input == result.frame)
        #expect(material.remoteROMName == source.sha256 + ".sfc")
        #expect(throws: (any Error).self) { try SNESCompatibilityPreflightMaterial.prepare(request: result, helper: helper, expectedHelperSHA256: String(repeating: "a", count: 64)) }
        var wrongArchitecture = helper; wrongArchitecture[18] = 62
        #expect(throws: (any Error).self) { try SNESCompatibilityPreflightMaterial.prepare(request: result, helper: wrongArchitecture, expectedHelperSHA256: BackupManifest.digest(wrongArchitecture)) }
        let helperSHA = String(repeating: "a", count: 64)
        let preflight = try SNESCompatibilityPreflightCommand.prepare(request: result, helperSHA256: helperSHA)
        #expect(preflight.input == result.frame && preflight.command.contains("head -c 107"))
        let sliced = (Data([0]) + result.frame).dropFirst()
        #expect(sliced.startIndex != 0)
        let slicedRequest = SNESCompatibilityLaunchRequest(frame: sliced, source: result.source)
        #expect(slicedRequest.frame.startIndex == 0)
        #expect(slicedRequest.frame == result.frame)
        let observed = try SNESCompatibilityLaunchRequest.observeConsoleFrame(sliced, game: game, source: source)
        #expect(observed.frame == result.frame)
        var foreignFrame = result.frame
        foreignFrame[8] ^= 1
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.observeConsoleFrame(foreignFrame, game: game, source: source) }
        foreignFrame = result.frame
        foreignFrame[19] = foreignFrame[19] == 48 ? 49 : 48
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.observeConsoleFrame(foreignFrame, game: game, source: source) }
        foreignFrame = result.frame
        foreignFrame.replaceSubrange(83..<99, with: Data(repeating: 0, count: 16))
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.observeConsoleFrame(foreignFrame, game: game, source: source) }
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.observeConsoleFrame(result.frame.dropLast(), game: game, source: source) }
        #expect(!preflight.command.contains(dir.path) && preflight.command.utf8.count < 1020)
        #expect(try preflight.validateReceipt(preflight.expectedReceipt))
        #expect(throws: (any Error).self) { try preflight.validateReceipt(preflight.expectedReceipt + Data([10])) }
        #expect(throws: (any Error).self) { try SNESCompatibilityPreflightCommand.prepare(request: result, helperSHA256: "not-a-hash") }

        if let path = ProcessInfo.processInfo.environment["HC_LAUNCH_FRAME_FIXTURE"] { try result.frame.write(to: URL(fileURLWithPath: path)) }
        let row = SNESLibraryCompatibility.Row(game: game, source: source, prepared: nil, issue: "Compatibility support needed", matches: [], evidence: .distinct, preparationError: .unsupportedCartridge)
        let review = SNESLibraryCompatibility(rows: [row], stockCodes: ["CLV-P-ABCDE"])
        #expect(try review.prepareCompatibilityLaunch(code: game.code, selected: [game.code], decisions: [:], session: token, epoch: 7).frame == result.frame)
        #expect(throws: (any Error).self) { try review.prepareCompatibilityLaunch(code: game.code, selected: [], decisions: [:], session: token, epoch: 7) }
        let duplicate = SNESLibraryCompatibility.Row(game: game, source: source, prepared: nil, issue: "Compatibility support needed", matches: ["CLV-P-ABCDE"], evidence: .possible, preparationError: .unsupportedCartridge)
        let duplicateReview = SNESLibraryCompatibility(rows: [duplicate], stockCodes: ["CLV-P-ABCDE"])
        #expect(throws: (any Error).self) { try duplicateReview.prepareCompatibilityLaunch(code: game.code, selected: [game.code], decisions: [:], session: token, epoch: 7) }
        #expect(throws: (any Error).self) { try duplicateReview.prepareCompatibilityLaunch(code: game.code, selected: [game.code], decisions: [game.code: .keepBuiltIn], session: token, epoch: 7) }
        #expect(try duplicateReview.prepareCompatibilityLaunch(code: game.code, selected: [game.code], decisions: [game.code: .keepImported], session: token, epoch: 7).frame == result.frame)

        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: Data(repeating: 0, count: 16), epoch: 7) }
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: token, epoch: 0) }
        var other = Game(code: "CLV-U-ZZZZZ", desktopContent: "Name=Other\n", consoleType: .snesUsa, source: .local); other.romPath = dir.path
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.prepare(game: other, source: source, session: token, epoch: 7) }
        other = game; other.consoleType = .nes
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.prepare(game: other, source: source, session: token, epoch: 7) }
        try Data([9]).write(to: dir.appendingPathComponent("other.smc"))
        #expect(throws: (any Error).self) { try SNESCompatibilityPreflightCommand.prepare(request: result, helperSHA256: helperSHA) }
        #expect(throws: (any Error).self) { try SNESCompatibilityPreflightMaterial.prepare(request: result, helper: helper, expectedHelperSHA256: BackupManifest.digest(helper)) }
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: token, epoch: 7) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("other.smc"))
        try Data([4,3,2,1]).write(to: dir.appendingPathComponent("game.sfc"))
        #expect(throws: (any Error).self) { try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: token, epoch: 7) }
        if let path = ProcessInfo.processInfo.environment["HC_APP_SUPERVISOR_FRAME"] {
            try Data("abc".utf8).write(to: dir.appendingPathComponent("game.sfc"))
            let actual = try SNESLibraryROMSource.capture(directory: dir, filename: "game.sfc").0
            let frame = try SNESCompatibilityLaunchRequest.prepare(game: game, source: actual, session: Data([7] + Array(repeating: 0, count: 15)), epoch: 4)
            try frame.frame.write(to: URL(fileURLWithPath: path))
            if let commandPath = ProcessInfo.processInfo.environment["HC_PREFLIGHT_COMMAND"],
               let receiptPath = ProcessInfo.processInfo.environment["HC_PREFLIGHT_RECEIPT"],
               let helperSHA = ProcessInfo.processInfo.environment["HC_PREFLIGHT_HELPER_SHA"] {
                let command = try SNESCompatibilityPreflightCommand.prepare(request: frame, helperSHA256: helperSHA)
                try Data(command.command.utf8).write(to: URL(fileURLWithPath: commandPath))
                try command.expectedReceipt.write(to: URL(fileURLWithPath: receiptPath))
            }

        }
    }
}

import Foundation
import Testing
@testable import SwiftHakchi

private actor ImportProgressLog {
    private(set) var messages: [String] = []
    func record(_ text: String) { messages.append(text) }
}
private actor ImportCopyGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor struct ResponsiveROMImportTests {
    @Test func genesisLibraryIdentifiesExistingOptionalEmulatorCommandsForReview() {
        let old = Game(code: "CLV-P-AAAAA", desktopContent: "Code=CLV-P-AAAAA\nName=Older\nExec=/bin/retroarch-clover -L /bin/genesis_plus_gx_libretro.so /var/games/old.md\n", consoleType: .megaDrive, source: .local)
        let current = Game(code: "CLV-P-BBBBB", desktopContent: "Code=CLV-P-BBBBB\nName=Current\nExec=/bin/m2engage /var/games/new.md\n", consoleType: .megaDrive, source: .local)
        let nes = Game(code: "CLV-H-CCCCC", desktopContent: "Code=CLV-H-CCCCC\nName=NES\nExec=/bin/retroarch-clover /var/games/a.nes\n", consoleType: .nes, source: .local)
        #expect(GenesisLauncherReadiness.optionalEmulatorCount([old, current, nes]) == 1)
        #expect(old.commandLine.contains("retroarch-clover"))
    }
    @Test func newGenesisImportUsesTheStockEmulatorWithoutChangingItsROM() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .megaDrive
        let source = root.appendingPathComponent("Example Game.md")
        let bytes = Data(repeating: 7, count: 1024); try bytes.write(to: source)
        let manager = GameManagerService(config: config)
        _ = try await manager.importROMsResponsive(urls: [source], consoleType: .megaDrive,
            reviewIncluded: { _ in .keepCopies }, progress: { _, _ in })
        let game = try #require(manager.games.first)
        #expect(game.commandLine.hasPrefix("/bin/m2engage "))
        #expect(game.commandLine.contains("Example Game.md"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: game.romPath).appendingPathComponent(source.lastPathComponent)) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test func existingGenesisLauncherIsNotRewrittenWhenLibraryLoads() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .megaDrive
        let code = "CLV-P-ABCDE", folder = config.gamesDirectory.appendingPathComponent("CLV-P-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desktopURL = folder.appendingPathComponent(code + ".desktop")
        let bytes = Data("[Desktop Entry]\nCode=CLV-P-ABCDE\nName=Existing\nExec=/bin/retroarch-clover -L /bin/genesis_plus_gx_libretro.so /var/games/CLV-P-ABCDE/game.md\n".utf8)
        try bytes.write(to: desktopURL)
        let manager = GameManagerService(config: config); manager.loadGames()
        #expect(manager.games.first?.commandLine.contains("retroarch-clover") == true)
        #expect(try Data(contentsOf: desktopURL) == bytes)
    }
    @Test func importsInBackgroundAndKeepsBuiltInMatchesUnchecked() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .nes
        let source = root.appendingPathComponent("Super Mario Bros. (USA).nes")
        let bytes = Data([78, 69, 83, 26] + Array(repeating: UInt8(7), count: 128))
        try bytes.write(to: source)
        let manager = GameManagerService(config: config), log = ImportProgressLog()
        var reviewed = false
        let result = try await manager.importROMsResponsive(urls: [source], consoleType: .nes, reviewIncluded: { matches in
            reviewed = true
            #expect(matches.first?.builtInTitle == "Super Mario Bros.")
            #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
            return .keepCopies
        }, progress: { status, _ in await log.record(status) })
        #expect(reviewed && result.added == 1 && result.keptIncluded == 1)
        let game = try #require(manager.games.first)
        #expect(!game.isSelected && !manager.isLoading)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: game.romPath).appendingPathComponent(source.lastPathComponent)) == bytes)
        #expect(await log.messages.count >= 2)
    }

    @Test func cancellingDuplicateReviewMakesNoLibraryChanges() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .nes
        let source = root.appendingPathComponent("Super Mario Bros. (USA).nes")
        try Data([78, 69, 83, 26] + Array(repeating: UInt8(7), count: 128)).write(to: source)
        let manager = GameManagerService(config: config)
        await #expect(throws: CancellationError.self) {
            try await manager.importROMsResponsive(urls: [source], consoleType: .nes,
                reviewIncluded: { _ in .cancel }, progress: { _, _ in })
        }
        #expect(manager.games.isEmpty && !manager.isLoading)
        #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
    }

    @Test(.timeLimit(.minutes(1))) func cancelledBackgroundCopyKeepsTheMainActorResponsiveAndDoesNotCommit() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .nes
        let source = root.appendingPathComponent("Example adventure.nes")
        let bytes = Data([78, 69, 83, 26] + Array(repeating: UInt8(7), count: 128)); try bytes.write(to: source)
        let manager = GameManagerService(config: config), gate = ImportCopyGate()
        let operation = Task { try await manager.importROMsResponsive(urls: [source], consoleType: .nes,
            reviewIncluded: { _ in .keepCopies }, progress: { _, fraction in if fraction == 1 { await gate.pause() } }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !(await gate.entered) {
            guard ContinuousClock.now < deadline else { operation.cancel(); await gate.resume(); Issue.record("Copy did not reach the checkpoint"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.isLoading) // This main-actor check runs while the worker is paused.
        operation.cancel(); await gate.resume()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(manager.games.isEmpty && !manager.isLoading)
        #expect(try Data(contentsOf: source) == bytes)
        #expect((try FileManager.default.contentsOfDirectory(atPath: config.gamesDirectory.path)).isEmpty)
    }

    @Test func changingAFileDuringDuplicateReviewDoesNotImportUnreviewedBytes() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .nes
        let source = root.appendingPathComponent("Super Mario Bros. (USA).nes")
        let bytes = Data([78, 69, 83, 26] + Array(repeating: UInt8(7), count: 128)); try bytes.write(to: source)
        let manager = GameManagerService(config: config)
        await #expect(throws: (any Error).self) {
            try await manager.importROMsResponsive(urls: [source], consoleType: .nes, reviewIncluded: { _ in
                try! (bytes + Data([42])).write(to: source)
                return .keepCopies
            }, progress: { _, _ in })
        }
        #expect(manager.games.isEmpty && !manager.isLoading)
        if FileManager.default.fileExists(atPath: config.gamesDirectory.path) {
            #expect((try FileManager.default.contentsOfDirectory(atPath: config.gamesDirectory.path)).isEmpty)
        }
        #expect(try Data(contentsOf: source) == bytes + Data([42]))
    }

    @Test(.timeLimit(.minutes(1))) func appShowsProgressUntilImportedGameIsReady() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .nes
        let source = root.appendingPathComponent("Example adventure.nes")
        try Data([78, 69, 83, 26] + Array(repeating: UInt8(7), count: 128)).write(to: source)
        let manager = GameManagerService(config: config)
        let app = AppState(startDeviceMonitoring: false, deviceManager: DeviceManager(), gameManager: manager, config: config, saveConfiguration: {})
        app.startGameFileImport(console: .nes, urls: [source])
        #expect(app.showTaskProgress && app.taskRunner.isRunning && app.taskRunner.displayState == .working)
        while app.taskRunner.isRunning { await Task.yield() }
        #expect(app.taskRunner.displayState == .completed && app.taskRunner.error == nil)
        #expect(manager.games.count == 1 && app.statusMessage?.hasPrefix("Added 1 game.") == true)
    }

    @Test func importsOnlySupportedGamesFromAnArchive() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .nes
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data([78, 69, 83, 26] + Array(repeating: UInt8(7), count: 128))
        try bytes.write(to: source.appendingPathComponent("Example.nes"))
        try Data("ignore".utf8).write(to: source.appendingPathComponent("notes.txt"))
        let archive = root.appendingPathComponent("games.zip")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source; zip.arguments = ["-q", archive.path, "Example.nes", "notes.txt"]
        try zip.run(); zip.waitUntilExit(); try #require(zip.terminationStatus == 0)
        let manager = GameManagerService(config: config)
        let result = try await manager.importROMsResponsive(urls: [archive], consoleType: .nes,
            reviewIncluded: { _ in .keepCopies }, progress: { _, _ in })
        #expect(result.added == 1 && manager.games.count == 1)
        let game = try #require(manager.games.first)
        let contents = try FileManager.default.contentsOfDirectory(atPath: game.romPath)
        #expect(contents.contains("Example.nes") && !contents.contains("notes.txt"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: game.romPath).appendingPathComponent("Example.nes")) == bytes)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }
}

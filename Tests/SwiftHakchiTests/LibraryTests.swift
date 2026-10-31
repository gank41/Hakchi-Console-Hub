import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized)
@MainActor
struct LibraryTests {
    @Test func importingAndDeletingManagedCopyPreservesSourceROM() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.nes")
        let bytes = Data([78, 69, 83, 26] + Array(repeating: UInt8(0), count: 60))
        try bytes.write(to: source)
        let config = AppConfig.shared
        let oldPath = config.workspacePath
        config.workspacePath = directory.path
        defer { config.workspacePath = oldPath }
        let manager = GameManagerService()
        try manager.importROMs(urls: [source], consoleType: .nes)
        let game = try #require(manager.games.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: game.romPath).appendingPathComponent("original.nes")) == bytes)
        manager.deleteGame(game)
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test func refreshingAndDisconnectingCannotReplaceSavedSelections() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let config = AppConfig.shared; let oldPath = config.workspacePath
        config.workspacePath = directory.path; defer { config.workspacePath = oldPath }
        let store = ConsoleProfileStore(directory: config.workspace.profiles)
        try store.save(ConsoleProfile(deviceID: "DEVICE", systemCode: "nes-usa", selectedCustomCodes: ["CLV-H-AAAAA"]))
        let manager = GameManagerService()
        let first = Game(code: "CLV-H-AAAAA", desktopContent: "Name=First\nCode=CLV-H-AAAAA", consoleType: .nes, source: .console)
        let second = Game(code: "CLV-H-BBBBB", desktopContent: "Name=Second\nCode=CLV-H-BBBBB", consoleType: .nes, source: .console)
        manager.configureSelection(deviceID: "DEVICE", consoleType: .nes)
        manager.mergeConsoleGames([first, second], installedCodes: [first.code, second.code], deviceID: "DEVICE", consoleType: .nes)
        #expect(manager.games.filter(\.isSelected).map(\.code) == ["CLV-H-AAAAA"])
        manager.clearConsoleGames()
        #expect(try store.load(deviceID: "DEVICE", systemCode: "nes-usa")?.selectedCustomCodes == ["CLV-H-AAAAA"])
    }

}

extension LibraryTests {
    @Test(arguments: ["Super Mario Bros.nes", "Mario's Adventure (USA).nes"])
    func ordinaryImportedFilenamesPassReviewAndStaging(filename: String) async throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(filename)
        let bytes = Data([78, 69, 83, 26] + Array(repeating: UInt8(0), count: 60))
        try bytes.write(to: source)
        let config = AppConfig.shared; let oldPath = config.workspacePath
        config.workspacePath = directory.path; defer { config.workspacePath = oldPath }
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        manager.games[0].isSelected = true
        let game = try #require(manager.games.first)
        let inputs = try SyncPlanAdapter.inputs(games: manager.games)
        let plan = try SyncPlanner.makePlan(inputs: inputs, installedCodes: [], profile: .init(deviceID: "ABC123", systemCode: "nes-usa"), freeBytes: 20_000_000, reserveBytes: 10_000_000)
        let shell = ArchiveShell()
        let base = "/var/lib/hakchi/games/nes-usa"
        try await GameSyncService(shell: shell, consoleType: .nes).prepareStage(plan: plan, stagingBase: "/stage", finalBase: base)
        let desktop = try #require(await shell.file("/stage/000/" + game.code + "/" + game.code + ".desktop"))
        let args = try LaunchCommand.arguments(in: DesktopFile(data: desktop).exec)
        #expect(args.contains(base + "/.storage/" + game.code + "/" + filename))
        #expect(try Data(contentsOf: source) == bytes)
        var unsafe = manager.games[0]; unsafe.commandLine = "/bin/play /bad/path.nes; echo unsafe"
        #expect(throws: SyncPlanError.self) { try SyncPlanAdapter.inputs(games: [unsafe]) }
    }
}

extension LibraryTests {
    @Test func legacyInspectionCannotOverwriteModernProfileOrLibrary() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let config = AppConfig.shared; let oldPath = config.workspacePath
        config.workspacePath = directory.path; defer { config.workspacePath = oldPath }
        let store = ConsoleProfileStore(directory: config.workspace.profiles)
        let profile = ConsoleProfile(deviceID: "MODERN", systemCode: "nes-usa", selectedCustomCodes: ["CLV-H-AAAAA"])
        try store.save(profile)
        let manager = GameManagerService()
        var local = Game(code: "CLV-H-AAAAA", desktopContent: "Name=Local\nCode=CLV-H-AAAAA", consoleType: .nes, source: .local)
        local.isSelected = true; manager.games = [local]
        manager.configureSelection(deviceID: "MODERN", consoleType: .nes)
        var remote = Game(code: "CLV-P-BBBBB", desktopContent: "Name=Remote\nCode=CLV-P-BBBBB", consoleType: .nes, source: .stock)
        remote.isSelected = true
        manager.mergeInspectionGames([remote])
        #expect(Set(manager.games.map(\.code)) == [local.code, remote.code])
        #expect(manager.games.first(where: { $0.code == local.code })?.name == "Local")
        manager.games[0].isSelected = false
        #expect(try store.load(deviceID: "MODERN", systemCode: "nes-usa") == profile)
        manager.clearConsoleGames()
        #expect(manager.games.map(\.code) == [local.code])
        #expect(manager.games[0].isSelected)
    }
}

extension LibraryTests {
    @Test(arguments: ["sfc", "snes", "bin"])
    func unsupportedNESImportDoesNotCopyAnySelectedFiles(extensionName: String) throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let config = AppConfig.shared; let oldPath = config.workspacePath
        config.workspacePath = directory.path; defer { config.workspacePath = oldPath }
        let source = directory.appendingPathComponent("valid.nes")
        let unsupported = directory.appendingPathComponent("unsupported." + extensionName)
        let bytes = Data([78, 69, 83, 26] + Array(repeating: UInt8(0), count: 60))
        try bytes.write(to: source); try Data([80, 75, 1, 2]).write(to: unsupported)
        let manager = GameManagerService()
        #expect(throws: (any Error).self) { try manager.importROMs(urls: [source, unsupported], consoleType: .nes) }
        #expect(manager.games.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
        #expect(try Data(contentsOf: source) == bytes)
    }
}

extension LibraryTests {
    @Test func zipImportKeepsOnlyExtractedROMsInManagedLibrary() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let source = root.appendingPathComponent("source")
        let folder = source.appendingPathComponent("games")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rom = NESROMIdentityTests.rom()
        try rom.write(to: folder.appendingPathComponent("Adventure.nes"))
        try Data("read me".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let macMetadata = folder.appendingPathComponent("__MACOSX")
        try FileManager.default.createDirectory(at: macMetadata, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: macMetadata.appendingPathComponent("._Adventure.nes"))
        let archive = source.appendingPathComponent("collection.zip")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source; zip.arguments = ["-q", "-r", archive.path, "games"]
        try zip.run(); zip.waitUntilExit(); #expect(zip.terminationStatus == 0)

        let manager = GameManagerService()
        try manager.importROMs(urls: [archive], consoleType: .nes)
        let game = try #require(manager.games.first)
        #expect(manager.games.count == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: game.romPath)
        #expect(files.filter { $0.hasSuffix(".nes") } == ["Adventure.nes"])
        #expect(!files.contains { $0.hasSuffix(".zip") || $0 == "notes.txt" })
        #expect(try Data(contentsOf: URL(fileURLWithPath: game.romPath).appendingPathComponent("Adventure.nes")) == rom)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func folderPickerIncludesArchivesAndRejectsMalformedOnImport() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let rom = source.appendingPathComponent("plain.nes")
        try NESROMIdentityTests.rom().write(to: rom)
        let broken = source.appendingPathComponent("broken.zip")
        try Data([0x50, 0x4b, 0x01, 0x02]).write(to: broken)
        #expect(Set(try ROMImportPolicy.collectFolder(source, for: .nes)) == [rom, broken])
        let manager = GameManagerService()
        #expect(throws: (any Error).self) { try manager.importROMs(urls: [rom, broken], consoleType: .nes) }
        #expect(manager.games.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
    }

    @Test func archiveWithParentPathCannotWriteOutsideTemporaryImport() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let archive = root.appendingPathComponent("unsafe.zip")
        let fixture = "UEsDBBQAAAAAAHJpU11QpoILFAAAABQAAAANAAAALi4vZXNjYXBlLm5lc05FUxoAAAAAAAAAAAAAAAAAAAAAUEsBAhQDFAAAAAAAcmlTXVCmggsUAAAAFAAAAA0AAAAAAAAAAAAAAIABAAAAAC4uL2VzY2FwZS5uZXNQSwUGAAAAAAEAAQA7AAAAPwAAAAAA"
        try #require(Data(base64Encoded: fixture)).write(to: archive)
        let manager = GameManagerService()
        #expect(throws: (any Error).self) { try manager.importROMs(urls: [archive], consoleType: .nes) }
        #expect(manager.games.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.nes").path))
        #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
    }

    @Test func archiveImportUsesSelectedConsoleFamily() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data([0x53, 0x4e, 0x45, 0x53, 1, 2, 3, 4])
        try bytes.write(to: source.appendingPathComponent("Example.sfc"))
        try NESROMIdentityTests.rom().write(to: source.appendingPathComponent("Other.nes"))
        let archive = source.appendingPathComponent("mixed.zip")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source; zip.arguments = ["-q", archive.path, "Example.sfc", "Other.nes"]
        try zip.run(); zip.waitUntilExit(); #expect(zip.terminationStatus == 0)
        let manager = GameManagerService()
        try manager.importROMs(urls: [archive], consoleType: .snesUsa)
        let game = try #require(manager.games.first)
        #expect(manager.games.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: game.romPath).appendingPathComponent("Example.sfc")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: game.romPath).appendingPathComponent("Other.nes").path))
    }
}

extension LibraryTests {
    @Test func editedNameKeepsImportDefaultAcrossSaveAndReload() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let config = AppConfig.shared; let oldPath = config.workspacePath; let oldType = config.lastConsoleType
        config.workspacePath = directory.path; config.lastConsoleType = .nes
        defer { config.workspacePath = oldPath; config.lastConsoleType = oldType }
        let source = directory.appendingPathComponent("MY TEST TITLE.nes")
        let bytes = Data([78, 69, 83, 26] + Array(repeating: UInt8(0), count: 60))
        try bytes.write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        var game = try #require(manager.games.first)
        let defaultName = game.name
        #expect(game.defaultName == defaultName)
        let command = game.commandLine
        game.name = "my CUSTOM title"; manager.saveGame(game)
        let reloaded = GameManagerService(); reloaded.loadGames()
        var saved = try #require(reloaded.games.first { $0.code == game.code })
        #expect(saved.name == "my CUSTOM title")
        #expect(saved.defaultName == defaultName)
        saved.name = saved.defaultName; reloaded.saveGame(saved)
        let restored = DesktopFile(data: try Data(contentsOf: URL(fileURLWithPath: saved.romPath).appendingPathComponent(saved.code + ".desktop")))
        #expect(restored.name == defaultName)
        #expect(restored.exec == command)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!SyncPlanAdapter.desktopFile(for: saved).serialize().contains("X-SwiftHakchi-DefaultName"))
    }
}

extension LibraryTests {
    @Test func canonicalDuplicateImportPreservesBothSourcesAndManagedBytes() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = directory.path; defer { config.workspacePath = previous }
        let first = directory.appendingPathComponent("First.NES"), second = directory.appendingPathComponent("Other.nes")
        let bytes = NESROMIdentityTests.rom(trailer: 128)
        try bytes.write(to: first); try NESROMIdentityTests.rom(trailer: 127).write(to: second)
        let manager = GameManagerService(); try manager.importROMs(urls: [first, second], consoleType: .nes)
        #expect(manager.games.count == 1)
        let game = try #require(manager.games.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: game.romPath).appendingPathComponent(first.lastPathComponent)) == bytes)
        #expect(try Data(contentsOf: first) == bytes)
        #expect(try Data(contentsOf: second) == NESROMIdentityTests.rom(trailer: 127))
        #expect(game.releaseDate.isEmpty)
    }
}

extension LibraryTests {
    @Test func publisherSpellingSurvivesReloadWithoutChangingConsoleSortField() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let source = root.appendingPathComponent("synthetic.nes"); try NESROMIdentityTests.rom().write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        var game = try #require(manager.games.first); game.publisher = "Data East"; manager.saveGame(game)
        let next = GameManagerService(); next.loadGames()
        let loaded = try #require(next.games.first(where: { $0.id == game.id }))
        #expect(loaded.publisher == "Data East")
        let console = SyncPlanAdapter.desktopFile(for: loaded).serialize()
        #expect(console.contains("SortRawPublisher=DATA EAST"))
        #expect(!console.contains("X-SwiftHakchi-Publisher"))
    }
}

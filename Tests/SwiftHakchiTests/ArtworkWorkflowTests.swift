import Foundation
import Testing
@testable import SwiftHakchi

struct ArtworkWorkflowTests {
    @Test func autoFillPreservesManualCoverAndRefusesUnknownROMOrRegion() throws {
        let code = "CLV-H-AAAAA"
        let game = Game(code: code, desktopContent: "Name=Contra\nCode=\(code)", consoleType: .nes, source: .local)
        let candidate = ArtworkCandidate(filename: "Contra (USA).png", platform: .nes)
        let entry = GameDatabase.Entry(name: "Contra", publisher: "Konami", releaseDate: "1988-02", players: 2, coverUrl: nil, region: "USA")
        #expect(ArtworkFillPolicy.candidate(game: game, entry: entry, existingImage: true, candidates: [candidate]) == nil)
        #expect(ArtworkFillPolicy.candidate(game: game, entry: nil, existingImage: false, candidates: [candidate]) == nil)
        #expect(ArtworkFillPolicy.candidate(game: game, entry: entry, existingImage: false, candidates: [candidate]) == candidate)
        let second = ArtworkCandidate(filename: "Contra (USA, Europe).png", platform: .nes)
        #expect(ArtworkFillPolicy.candidate(game: game, entry: entry, existingImage: false, candidates: [candidate, second]) == nil)
        var remote = game; remote.source = .console
        #expect(ArtworkFillPolicy.candidate(game: remote, entry: entry, existingImage: false, candidates: [candidate]) == nil)
    }
}

extension LibraryTests {
    @Test func artworkCannotCommitToAChangedWorkspaceOrInspectionLibrary() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let source = root.appendingPathComponent("synthetic.nes"); try NESROMIdentityTests.rom().write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let game = try #require(manager.games.first)
        let target = try GameArtworkTarget(game: game, gamesDirectory: config.gamesDirectory)
        try manager.validateArtworkTarget(target)
        config.workspacePath = root.appendingPathComponent("different").path
        #expect(throws: (any Error).self) { try manager.validateArtworkTarget(target) }
        config.workspacePath = root.path
        manager.mergeInspectionGames([])
        #expect(throws: (any Error).self) { try manager.validateArtworkTarget(target) }
    }
}

extension LibraryTests {
    @Test func replacingArtworkAtTheSameFilenameRefreshesEveryPresentation() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let source = root.appendingPathComponent("synthetic.nes"); try NESROMIdentityTests.rom().write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        let game = try #require(manager.games.first); let original = game.artworkRevision
        let target = try GameArtworkTarget(game: game, gamesDirectory: config.gamesDirectory)
        let provenance = GameArtworkStore.Provenance(provider: "Test", source: "fixture", matchedAutomatically: false, savedAt: Date())
        try manager.applyArtwork(ArtworkCatalogTests.image, target: target, provenance: provenance)
        let first = manager.games[0].artworkRevision
        try manager.applyArtwork(ArtworkCatalogTests.image, target: target, provenance: provenance)
        #expect(original != first)
        #expect(first != manager.games[0].artworkRevision)
        #expect(manager.games[0].coverImage != nil)
    }
}

private actor MetadataSpy: GameMetadataProviding {
    var requests = 0
    func validateApiKey(_ apiKey: String) async throws -> Int { requests += 1; return 100 }
    func searchGames(name: String, apiKey: String, platform: Int?) async throws -> [ScraperService.SearchResult] { requests += 1; return [] }
    func fetchGamesByIds(ids: [Int], apiKey: String, progress: ((Double) -> Void)?) async throws -> [Int: ScraperService.GameInfo] {
        requests += 1
        return [1258: .init(id: 1258, title: "Wrong asynchronous title", overview: "Wrong asynchronous description", releaseDate: nil, players: nil, genres: nil, publishers: nil, boxartFrontURL: nil)]
    }
}

extension LibraryTests {
    @Test func configuredKeyCannotScheduleImportMutationsAcrossSortingAndWorkspaceChange() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath; let key = config.theGamesDbApiKey
        config.workspacePath = root.path; config.theGamesDbApiKey = "synthetic-test-key"
        defer { config.workspacePath = previous; config.theGamesDbApiKey = key }
        // Synthetic zeros plus a CRC patch; no commercial game bytes.
        var bytes = Data([78,69,83,26,1,0,0,0] + Array(repeating: 0, count: 8))
        bytes.append(Data(repeating: 0, count: 16_380)); bytes.append(contentsOf: [80,74,124,210])
        let source = root.appendingPathComponent("Z-last.nes"); try bytes.write(to: source)
        #expect(CRC32.romChecksum(file: source) == 0xF6035030)
        let other = root.appendingPathComponent("Aardvark.nes"); try NESROMIdentityTests.rom().write(to: other)
        let spy = MetadataSpy(); let manager = GameManagerService(metadataProvider: spy)
        try manager.importROMs(urls: [source, other], consoleType: .nes)
        let game = try #require(manager.games.first(where: { $0.name == "Contra" }))
        let target = try GameArtworkTarget(game: game, gamesDirectory: config.gamesDirectory)
        try manager.applyArtwork(ArtworkCatalogTests.image, target: target,
            provenance: .init(provider: "Manual", source: "fixture", matchedAutomatically: false, savedAt: Date()))
        let cover = target.folder.appendingPathComponent(game.code + ".png"); let manual = try Data(contentsOf: cover)
        config.workspacePath = root.appendingPathComponent("different").path
        // Give any obsolete import task an opportunity to cross its awaited response.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await spy.requests == 0)
        #expect(manager.games.contains { $0.name == "Aardvark" && $0.description.isEmpty })
        #expect(try Data(contentsOf: cover) == manual)
        #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
    }
}

private actor LateArtworkGate {
    private var requested = false
    private var started: [CheckedContinuation<Void, Never>] = []
    private var response: CheckedContinuation<Void, Never>?
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { started.append($0) }
    }
    func pauseResponse() async {
        requested = true
        for waiter in started { waiter.resume() }; started = []
        await withCheckedContinuation { response = $0 }
    }
    func release() { response?.resume(); response = nil }
}

extension LibraryTests {
    @Test(arguments: [false, true])
    func lateCoverCannotOverwriteManualArtworkOrFollowAChangedWorkspace(changeWorkspace: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        var bytes = Data([78,69,83,26,1,0,0,0] + Array(repeating: 0, count: 8))
        bytes.append(Data(repeating: 0, count: 16_380)); bytes.append(contentsOf: [80,74,124,210])
        let source = root.appendingPathComponent("ContraFixture.nes"); try bytes.write(to: source)
        let other = root.appendingPathComponent("Other.nes"); try NESROMIdentityTests.rom().write(to: other)
        let manager = GameManagerService(); try manager.importROMs(urls: [source, other], consoleType: .nes)
        let game = try #require(manager.games.first(where: { $0.name == "Contra" }))
        let target = try GameArtworkTarget(game: game, gamesDirectory: config.gamesDirectory)
        let gate = LateArtworkGate()
        let service = ArtworkCatalogService(fetch: { url in
            if url.pathExtension.lowercased() != "png" {
                return .init(data: Data("<a href=\"Contra%20(USA).png\">cover</a>".utf8), status: 200, url: url)
            }
            await gate.pauseResponse()
            return .init(data: ArtworkCatalogTests.image, status: 200, url: url)
        })
        let fill = Task { try await manager.fillMissingCoverArt(service: service) { _, _ in } }
        await gate.waitUntilRequested()
        manager.games.reverse() // A response must never use the old array position.
        if changeWorkspace { config.workspacePath = root.appendingPathComponent("different").path }
        else {
            try manager.applyArtwork(ArtworkCatalogTests.image, target: target,
                provenance: .init(provider: "Manual", source: "manual fixture", matchedAutomatically: false, savedAt: Date()))
        }
        await gate.release()
        if changeWorkspace {
            await #expect(throws: (any Error).self) { try await fill.value }
            #expect(!FileManager.default.fileExists(atPath: target.folder.appendingPathComponent(game.code + ".png").path))
            #expect(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
        } else {
            let report = try await fill.value
            #expect(report.preserved.contains(game.code), "\(String(describing: report))")
            let evidence = try String(contentsOf: target.folder.appendingPathComponent("artwork-source.json"))
            #expect(evidence.contains("Manual"))
            #expect(!evidence.contains("Libretro"))
        }
        #expect(try Data(contentsOf: source) == bytes)
    }
}

extension ArtworkWorkflowTests {
    @Test func fillCannotChooseAnotherConsoleArtworkForAnIdenticalTitle() throws {
        let game = Game(code: "CLV-P-ABCDE", desktopContent: "Name=Shadowrun\n", consoleType: .megaDrive, source: .local)
        let entry = GameDatabase.Entry(name: "Shadowrun", publisher: nil, releaseDate: nil, players: 1, coverUrl: nil, region: "USA")
        let wrong = ArtworkCandidate(filename: "Shadowrun (USA).png", platform: .snes)
        #expect(ArtworkFillPolicy.candidate(game: game, entry: entry, existingImage: false, candidates: [wrong]) == nil)
    }
}

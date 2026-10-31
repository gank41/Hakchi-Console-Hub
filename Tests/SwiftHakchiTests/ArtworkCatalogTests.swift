import Foundation
import Testing
import ImageIO
@testable import SwiftHakchi

struct ArtworkCatalogTests {
    static let index = Data("""
    <a href="Contra%20(USA).png">Contra</a>
    <a href="Contra%20(USA).png">Duplicate</a>
    <a href="Contra%20(Japan).png">Japan</a>
    <a href="Contra%20Force%20(USA).png">Sequel</a>
    <a href="Contra%20(1988)(Konami)(US)%5bh%5d.png">Historic</a>
    <a href="../escape.png">Escape</a>
    <a href="%2e%2e%2fescape.png">Encoded escape</a>
    <a href="https://evil.test/cover.png">Remote</a>
    <a href="%00bad.png">Control</a>
    <a href="Legend%20of%20Zelda,%20The%20(USA).png">Zelda</a>
    """.utf8)

    @Test func indexRejectsEscapesAndDeduplicates() throws {
        let entries = try ArtworkCatalogService.parseIndex(Self.index, platform: .nes)
        #expect(entries.count == 5)
        #expect(entries.allSatisfy { $0.url.host == "thumbnails.libretro.com" })
        #expect(entries.allSatisfy { !$0.filename.contains("/") && !$0.filename.contains("\0") })
    }
    @Test func automaticMatchRequiresCompleteTitleAndUniqueRegion() throws {
        let entries = try ArtworkCatalogService.parseIndex(Self.index, platform: .nes)
        #expect(ArtworkCatalogService.uniqueMatch(title: "Contra", region: "USA", candidates: entries)?.filename == "Contra (USA).png")
        #expect(ArtworkCatalogService.uniqueMatch(title: "The Legend of Zelda", region: "USA", candidates: entries)?.filename == "Legend of Zelda, The (USA).png")
        #expect(ArtworkCatalogService.uniqueMatch(title: "Contra II", region: "USA", candidates: entries) == nil)
        #expect(ArtworkCatalogService.uniqueMatch(title: "Contra", region: nil, candidates: entries) == nil)
        let other = ArtworkCandidate(filename: "Contra (USA, Europe).png", platform: .nes)
        #expect(ArtworkCatalogService.uniqueMatch(title: "Contra", region: "USA", candidates: entries + [other]) == nil)
    }
    @Test func searchIsKeyFreeAndIndexIsCached() async throws {
        let count = ArtworkCounter()
        let service = ArtworkCatalogService(fetch: { url in
            await count.increment()
            return ArtworkHTTPResponse(data: Self.index, status: 200, url: url)
        })
        let first = try await service.search(query: "Contra", platform: .nes)
        #expect(first.contains { $0.filename == "Contra (USA).png" })
        #expect(!(try await service.search(query: "Zelda", platform: .nes)).isEmpty)
        #expect(await count.value == 1)
    }
    @Test func failuresDoNotBecomeImageData() async throws {
        let candidate = ArtworkCandidate(filename: "Contra (USA).png", platform: .nes)
        for status in [403, 404, 429, 500] {
            let service = ArtworkCatalogService(fetch: { url in .init(data: Data("error".utf8), status: status, url: url) })
            await #expect(throws: (any Error).self) { try await service.download(candidate) }
        }
        let invalid = ArtworkCatalogService(fetch: { url in .init(data: Data("<html>not art</html>".utf8), status: 200, url: url) })
        await #expect(throws: (any Error).self) { try await invalid.download(candidate) }
        let redirected = ArtworkCatalogService(fetch: { _ in .init(data: Data(), status: 200, url: URL(string: "https://evil.test/image")!) })
        await #expect(throws: (any Error).self) { try await redirected.download(candidate) }
    }
    @Test func imageStoreRejectsInvalidAndOversizedData() throws {
        #expect(throws: (any Error).self) { try GameArtworkStore.png(from: Data("not an image".utf8)) }
        #expect(throws: (any Error).self) { try GameArtworkStore.png(from: Data(repeating: 0, count: 8 * 1024 * 1024 + 1)) }
    }
}

private actor ArtworkCounter {
    var value = 0
    func increment() { value += 1 }
}

extension ArtworkCatalogTests {
    static var image: Data {
        // A real small image, independent of commercial box art.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 4, height: 6, bitsPerComponent: 8, bytesPerRow: 16,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
    @Test func savePreservesROMAndLauncherAndRejectsChangedTarget() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let code = "CLV-H-AAAAA"; let folder = root.appendingPathComponent(code, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desktop = Data("Name=My Game\nCode=CLV-H-AAAAA\nExec=/bin/play file.nes\n".utf8)
        let metadata = folder.appendingPathComponent(code + ".desktop"); try desktop.write(to: metadata)
        let rom = folder.appendingPathComponent("file.nes"); let bytes = NESROMIdentityTests.rom(); try bytes.write(to: rom)
        let game = Game(desktopFile: DesktopFile(data: desktop), consoleType: .nes, basePath: root.path)
        let target = try GameArtworkTarget(game: game, gamesDirectory: root)
        let source = GameArtworkStore.Provenance(provider: "Local image", source: "test.png", matchedAutomatically: false, savedAt: Date())
        let path = try GameArtworkStore.save(data: Self.image, target: target, provenance: source)
        #expect(CGImageSourceCreateWithData(try Data(contentsOf: path) as CFData, nil) != nil)
        #expect(try Data(contentsOf: rom) == bytes)
        #expect(try Data(contentsOf: metadata) == desktop)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("artwork-source.json").path))
        try Data("Name=Changed\n".utf8).write(to: metadata)
        #expect(throws: (any Error).self) { try GameArtworkStore.save(data: Self.image, target: target, provenance: source) }
        try FileManager.default.removeItem(at: folder)
        #expect(throws: (any Error).self) { try target.validate() }
    }
    @Test func downloadReturnsDecodedPNGWithoutChangingItsSourceURL() async throws {
        let candidate = ArtworkCandidate(filename: "My Game (USA).png", platform: .nes)
        let service = ArtworkCatalogService(fetch: { url in .init(data: Self.image, status: 200, url: url) })
        let image = try await service.download(candidate)
        #expect(image.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        #expect(candidate.url.absoluteString.contains("My%20Game"))
    }
}

extension ArtworkCatalogTests {
    @Test func sharedCRCDoesNotProveARegionOrRegionalTitle() throws {
        let sameTitle = try #require(GameDatabase.shared.lookup(crc32: "171251E3"))
        #expect(sameTitle.region == nil)
        #expect(ArtworkCatalogService.uniqueMatch(title: sameTitle.name, region: sameTitle.region,
             candidates: [ArtworkCandidate(filename: "1942 (USA).png", platform: .nes)]) == nil)
        let differentTitles = try #require(GameDatabase.shared.lookup(crc32: "DF67DAA1"))
        #expect(differentTitles.name.isEmpty)
        #expect(differentTitles.region == nil)
    }
}

extension ArtworkCatalogTests {
    @Test func genesisArtworkUsesOnlyTheGenesisCatalogAndRejectsCrossPlatformRedirects() async throws {
        let platform = try #require(ArtworkPlatform(console: .megaDrive))
        #expect(ArtworkPlatform(console: .unknown) == nil)
        let service = ArtworkCatalogService(fetch: { url in
            .init(data: Data("<a href=\"Sonic%20The%20Hedgehog%20(USA,%20Europe).png\">Sonic</a>".utf8), status: 200, url: url)
        })
        let found = try await service.search(query: "Sonic", platform: platform)
        let result = try #require(found.first)
        #expect(result.url.path.hasPrefix("/Sega - Mega Drive - Genesis/Named_Boxarts/"))
        let foreign = ArtworkCatalogService(fetch: { _ in
            .init(data: Self.index, status: 200, url: URL(string: "https://thumbnails.libretro.com/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System/Named_Boxarts/")!)
        })
        await #expect(throws: (any Error).self) { try await foreign.search(query: "Sonic", platform: platform) }
    }
}

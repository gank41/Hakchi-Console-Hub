import Foundation
import ImageIO
import CryptoKit

/// A snapshot of one managed local game. Never derives write paths from downloaded data.
struct GameArtworkTarget: Sendable {
    let code: String
    let gamesDirectory: URL
    let folder: URL
    let metadataDigest: String

    init(game: Game, gamesDirectory: URL) throws {
        guard game.source == .local, game.code.range(of: #"^CLV-[A-Z]-[A-Z0-9]{5}$"#, options: .regularExpression) != nil else { throw ArtworkError.staleTarget }
        let folder = gamesDirectory.appendingPathComponent(game.code, isDirectory: true).standardizedFileURL
        guard URL(fileURLWithPath: game.romPath).standardizedFileURL == folder else { throw ArtworkError.staleTarget }
        self.code = game.code; self.gamesDirectory = gamesDirectory.standardizedFileURL; self.folder = folder
        metadataDigest = try Self.digest(folder: folder, code: game.code)
    }

    static func digest(folder: URL, code: String) throws -> String {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let desktop = folder.appendingPathComponent(code + ".desktop")
        let fileValues = try desktop.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else { throw ArtworkError.staleTarget }
        return SHA256.hash(data: try Data(contentsOf: desktop)).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        guard try Self.digest(folder: folder, code: code) == metadataDigest else { throw ArtworkError.staleTarget }
    }
}

enum GameArtworkStore {
    struct Provenance: Codable, Sendable {
        let provider: String
        let source: String
        let matchedAutomatically: Bool
        let savedAt: Date
    }

    static func png(from data: Data) throws -> Data {
        guard data.count <= 8 * 1024 * 1024 else { throw ArtworkError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096 else { throw ArtworkError.invalidImage }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 1024,
                                      kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ArtworkError.invalidImage }
        let result = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { throw ArtworkError.invalidImage }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ArtworkError.invalidImage }
        return result as Data
    }

    @discardableResult
    static func save(data: Data, target: GameArtworkTarget, provenance: Provenance) throws -> URL {
        let image = try png(from: data)
        try target.validate()
        let imageURL = target.folder.appendingPathComponent(target.code + ".png")
        let sidecar = target.folder.appendingPathComponent("artwork-source.json")
        for url in [imageURL, sidecar] where FileManager.default.fileExists(atPath: url.path) {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v.isRegularFile == true, v.isSymbolicLink != true else { throw ArtworkError.staleTarget }
        }
        let previous = try? Data(contentsOf: sidecar)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(provenance).write(to: sidecar, options: .atomic)
        do { try image.write(to: imageURL, options: .atomic) }
        catch {
            if let previous { try? previous.write(to: sidecar, options: .atomic) }
            else { try? FileManager.default.removeItem(at: sidecar) }
            throw error
        }
        return imageURL
    }
}

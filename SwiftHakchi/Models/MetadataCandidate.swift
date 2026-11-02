import Foundation
import CryptoKit

/// A manual metadata choice, not a claim that the ROM is the same revision.
struct MetadataCandidate: Identifiable, Hashable, Sendable {
    let title: String
    let region: String?
    let releaseDate: String?
    let players: Int?
    let publisher: String?
    let genre: String?
    let overview: String?
    let platform: String
    var id: String {
        let fields = [platform, title, region ?? "", releaseDate ?? "", players.map(String.init) ?? "", publisher ?? "", genre ?? "", overview ?? ""]
        let bytes = try! JSONEncoder().encode(fields)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func applying(to game: Game) -> Game {
        var updated = game
        updated.name = game.isCheatCodeCopy && !title.hasSuffix(" [Cheat Code]") ? title + " [Cheat Code]" : title
        if let releaseDate { updated.releaseDate = releaseDate }
        if let players { updated.players = players }
        if let publisher { updated.publisher = publisher }
        if let genre { updated.genre = genre }
        if let overview { updated.description = overview }
        return updated
    }
}

import Foundation
import SwiftHakchiCore

/// Checked, immutable Mac bytes for a responsive review. Freeze still rehashes all selected sources.
struct SNESLibraryObjectCache: Sendable {
    let unavailable: [String: String]
    private let games: [Game], stockCodes: Set<String>, items: [String: SNESLibraryObjects.Item], objects: [String: Data]
    private let sources: [String: [SNESLibrarySourceFile]], seals: [SNESFirmwareSourceSeal]
    @MainActor static func prepare(review: SNESLibraryCompatibility) throws -> Self {
        var unavailable: [String: String] = [:], items: [String: SNESLibraryObjects.Item] = [:], objects: [String: Data] = [:]
        var sources: [String: [SNESLibrarySourceFile]] = [:]
        for row in review.rows {
            try Task.checkCancellation()
            if let issue = row.issue { unavailable[row.game.code] = issue; continue }
            do {
                let content = try SNESLibraryObjects.prepare(review: review, resolvedCodes: [row.game.code])
                guard let item = content.items[row.game.code] else { throw SNESLibraryMenu.failure() }
                items[row.game.code] = item; sources[row.game.code] = content.sources
                for (name, data) in content.objects {
                    guard objects[name] == nil || objects[name] == data else { throw SNESLibraryMenu.failure() }; objects[name] = data
                }
            } catch is CancellationError { throw CancellationError() }
              catch { unavailable[row.game.code] = "Check this game's ROM, saved details and box art, then refresh the review." }
        }
        guard objects.values.reduce(0, { $0 + $1.count }) <= 192 * 1024 * 1024 else { throw SNESLibraryCompatibility.failure("Choose a smaller selection for this review.") }
        let all = sources.keys.sorted().flatMap { sources[$0]! }
        var seals: [SNESFirmwareSourceSeal] = []
        for start in stride(from: 0, to: all.count, by: 16) {
            seals.append(try .capture(directories: [], files: all[start..<min(start+16, all.count)].map { URL(fileURLWithPath: $0.directory).appendingPathComponent($0.name) }))
        }
        for source in all { try source.verify() }
        for seal in seals { try seal.validate() }
        return .init(unavailable: unavailable, games: review.rows.map(\.game), stockCodes: review.stockCodes, items: items, objects: objects, sources: sources, seals: seals)
    }
    func content(review: SNESLibraryCompatibility, resolvedCodes: Set<String>) throws -> SNESLibraryObjects {
        try Task.checkCancellation()
        guard games == review.rows.map(\.game), stockCodes == review.stockCodes,
              resolvedCodes.isSubset(of: stockCodes.union(games.map(\.code))), Set(unavailable.keys).isDisjoint(with: resolvedCodes) else { throw SNESLibraryMenu.failure() }
        for seal in seals { try seal.validate() }
        let codes = resolvedCodes.subtracting(stockCodes), selected = items.filter { codes.contains($0.key) }
        guard Set(selected.keys) == codes else { throw SNESLibraryMenu.failure() }
        let names = Set(selected.values.flatMap { [$0.rom, $0.artwork, $0.smallArtwork] })
        return .init(items: selected, objects: objects.filter { names.contains($0.key) }, sources: codes.sorted().flatMap { sources[$0] ?? [] })
    }
}

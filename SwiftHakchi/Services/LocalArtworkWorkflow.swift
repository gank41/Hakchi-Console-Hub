import Foundation

struct ArtworkFillPolicy {
    static func candidate(game: Game, entry: GameDatabase.Entry?, existingImage: Bool,
                          candidates: [ArtworkCandidate]) -> ArtworkCandidate? {
        guard game.source == .local, !existingImage, let entry, !entry.name.isEmpty,
              let platform = ArtworkPlatform(console: game.consoleType) else { return nil }
        return ArtworkCatalogService.uniqueMatch(title: entry.name, region: entry.region,
            candidates: candidates.filter { $0.platform == platform })
    }
}

struct ArtworkFillReport: Codable {
    var filled: [String] = []
    var preserved: [String] = []
    var needsReview: [String] = []
    var failures: [String: String] = [:]
    var summary: String {
        "Added \(filled.count) covers; kept \(preserved.count) existing; \(needsReview.count) need review; \(failures.count) failed."
    }
}

extension GameManagerService {
    func validateArtworkTarget(_ target: GameArtworkTarget) throws {
        guard !isInspectingLegacy, AppConfig.shared.gamesDirectory.standardizedFileURL.path == target.gamesDirectory.path,
              let game = games.first(where: { $0.code == target.code }), game.source == .local,
              URL(fileURLWithPath: game.romPath).standardizedFileURL.path == target.folder.path else { throw ArtworkError.staleTarget }
        try target.validate()
    }

    func applyArtwork(_ data: Data, target: GameArtworkTarget, provenance: GameArtworkStore.Provenance) throws {
        try validateArtworkTarget(target)
        let path = try GameArtworkStore.save(data: data, target: target, provenance: provenance)
        ImageCache.shared.evict(path.path)
        if let index = games.firstIndex(where: { $0.code == target.code }) { games[index].coverArtPath = path.path; games[index].artworkRevision = UUID(); games[index].modifiedAt = Date() }
    }

    func fillMissingCoverArt(service: ArtworkCatalogService = .shared,
                             progress: (String, Double) -> Void) async throws -> ArtworkFillReport {
        guard !isInspectingLegacy else { throw ArtworkError.staleTarget }
        let directory = AppConfig.shared.gamesDirectory
        let snapshot = games.filter { $0.source == .local }
        var report = ArtworkFillReport()
        for (offset, game) in snapshot.enumerated() {
            try Task.checkCancellation()
            let target = try GameArtworkTarget(game: game, gamesDirectory: directory)
            try validateArtworkTarget(target)
            progress("Finding cover for \(game.name)", Double(offset) / Double(max(1, snapshot.count)))
            let art = target.folder.appendingPathComponent(game.code + ".png")
            if let data = try? Data(contentsOf: art), (try? GameArtworkStore.png(from: data)) != nil {
                report.preserved.append(game.code); continue
            }
            let files = try FileManager.default.contentsOfDirectory(at: target.folder, includingPropertiesForKeys: nil)
            guard let rom = files.first(where: { ROMImportPolicy.extensions(for: game.consoleType).contains($0.pathExtension.lowercased()) }),
                  let entry = GameDatabase.shared.lookup(romURL: rom, consoleType: game.consoleType), !entry.name.isEmpty else {
                report.needsReview.append(game.code); continue
            }
            guard let platform = ArtworkPlatform(console: game.consoleType) else { report.needsReview.append(game.code); continue }
            do {
                let candidates = try await service.catalog(platform: platform)
                try validateArtworkTarget(target)
                guard let candidate = ArtworkFillPolicy.candidate(game: game, entry: entry, existingImage: false, candidates: candidates) else {
                    report.needsReview.append(game.code); continue
                }
                let png = try await service.download(candidate)
                try Task.checkCancellation()
                try validateArtworkTarget(target)
                // A manual cover may have appeared during the network operation.
                if let data = try? Data(contentsOf: art), (try? GameArtworkStore.png(from: data)) != nil {
                    report.preserved.append(game.code); continue
                }
                try applyArtwork(png, target: target, provenance: .init(provider: "Libretro thumbnails", source: candidate.url.absoluteString,
                                                                      matchedAutomatically: true, savedAt: Date()))
                report.filled.append(game.code)
            } catch is CancellationError { throw CancellationError() }
            catch ArtworkError.staleTarget { throw ArtworkError.staleTarget }
            catch { report.failures[game.code] = error.localizedDescription }
        }
        try Task.checkCancellation()
        guard AppConfig.shared.gamesDirectory.standardizedFileURL.path == directory.standardizedFileURL.path, !isInspectingLegacy else { throw ArtworkError.staleTarget }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("artwork-fill-report.json"), options: .atomic)
        return report
    }
}

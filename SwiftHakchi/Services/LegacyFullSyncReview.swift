import Foundation
import SwiftHakchiCore

/// A local-only review of an entire NES library against one verified console inventory.
/// It freezes the duplicate evidence before any inactive upload is prepared.
@MainActor struct LegacyFullSyncReview {
    struct SavedSelection {
        let decisions: [String: LegacyStockDuplicateReview.Resolution]
        let excludedCodes: Set<String>
    }

    struct CompatibilityWarning: Sendable {
        let code: String
        let title: String
        let trailingBytes: Int?
        let detail: String
        /// Trailing data after a valid NES image is information, not a failed ROM check.
        var requiresAcknowledgement: Bool { trailingBytes == nil }
    }

    let duplicateReview: LegacyStockDuplicateReview
    let compatibilityWarnings: [CompatibilityWarning]
    let newLocalCodes: Set<String>
    let missingSelectedCodes: Set<String>
    let suggestedDecisions: [String: LegacyStockDuplicateReview.Resolution]
    let previouslySelectedCodes: Set<String>?
    let previousStructure: ConsoleStructure?
    let capacityEstimate: LegacySyncCapacityEstimate

    private let localGames: [Game]
    private let remoteGames: [Game]
    private let report: LegacyConsoleReport

    static func make(localGames: [Game], remoteGames: [Game], report: LegacyConsoleReport,
                     factoryROMHashes: [String: String], accepted: LegacySyncJournal?) throws -> Self {
        let stock = remoteGames.filter(\.isStock)
        guard Set(stock.map(\.code)) == report.stockCodes else {
            throw SyncPlanError.invalidInput("The verified built-in game inventory is incomplete.")
        }
        if let accepted {
            guard accepted.phase == .accepted, accepted.resolvedScope == .full,
                  let selected = accepted.selectedCodes,
                  accepted.reviewedLocalCodes != nil,
                  Set(selected) == report.visibleCodes else {
                throw SyncPlanError.invalidInput("The last accepted library cannot be updated from these sources. Review a fresh full sync.")
            }
        }
        let duplicates = try LegacyStockDuplicateReview.make(local: localGames, stock: stock,
                                                              factoryROMHashes: factoryROMHashes)
        let priorReviewed = Set(accepted?.reviewedLocalCodes ?? [])
        let priorSelected = accepted?.selectedCodes.map(Set.init)
        var suggestions: [String: LegacyStockDuplicateReview.Resolution] = [:]
        if let priorSelected {
            for row in duplicates.rows where row.stockCode != nil && priorReviewed.contains(row.localCode) {
                if priorSelected.contains(row.localCode) {
                    suggestions[row.localCode] = .keepImported
                } else if let stockCode = row.stockCode, priorSelected.contains(stockCode) {
                    suggestions[row.localCode] = .keepBuiltIn
                }
            }
        }
        var warnings: [CompatibilityWarning] = []
        for row in duplicates.rows {
            guard let game = localGames.first(where: { $0.code == row.localCode }) else { continue }
            let folder = URL(fileURLWithPath: game.romPath, isDirectory: true)
            let roms = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "nes" }
            guard roms.count == 1 else { throw SyncPlanError.missingFile(game.name) }
            let source = try LegacySyncPlan.SourceFile.capture(roms[0])
            guard source.sha256 == row.localROMHash else {
                throw SyncPlanError.invalidInput("A local ROM changed during duplicate review: \(game.name).")
            }
            guard source.byteCount <= 32 * 1024 * 1024 else {
                warnings.append(.init(code: row.localCode, title: row.localTitle,
                                      trailingBytes: nil, detail: "ROM is larger than the supported compatibility check."))
                continue
            }
            do {
                let identity = try NESROMIdentity(data: Data(contentsOf: roms[0], options: .mappedIfSafe))
                if identity.trailingBytes > 0 {
                    warnings.append(.init(code: row.localCode, title: row.localTitle,
                        trailingBytes: identity.trailingBytes,
                        detail: "This ROM has \(identity.trailingBytes) extra bytes after its declared NES data; check gameplay after syncing."))
                }
            } catch {
                warnings.append(.init(code: row.localCode, title: row.localTitle,
                    trailingBytes: nil, detail: "The NES ROM header could not be validated; this game may not launch."))
            }
        }
        return Self(duplicateReview: duplicates,
                    compatibilityWarnings: warnings.sorted { $0.title < $1.title },
                    newLocalCodes: Set(localGames.map(\.code)).subtracting(priorReviewed),
                    missingSelectedCodes: (priorSelected ?? []).subtracting(
                        Set(localGames.map(\.code)).union(report.stockCodes)),
                    suggestedDecisions: suggestions, previouslySelectedCodes: priorSelected,
                    previousStructure: accepted?.resolvedStructure,
                    capacityEstimate: LegacySyncCapacityEstimate.fromLibrary(
                        localGames: localGames, stockCodes: report.stockCodes, freeBytes: report.freeBytes),
                    localGames: localGames, remoteGames: remoteGames, report: report)
    }

    func plan(decisions: [String: LegacyStockDuplicateReview.Resolution],
              excludedCodes: Set<String>, consoleOrder: ConsoleMenuOrder,
              maximumGamesPerPage: Int, structure: ConsoleStructure? = nil,
              folderArtworkDirectory: URL? = nil, selectedCodes: Set<String>? = nil) throws -> LegacySyncPlan {
        guard missingSelectedCodes.isSubset(of: excludedCodes) else {
            throw SyncPlanError.invalidInput("Restore the missing source ROMs or confirm their removal from the NES menu.")
        }
        for row in duplicateReview.rows {
            guard let game = localGames.first(where: { $0.code == row.localCode }) else { continue }
            let folder = URL(fileURLWithPath: game.romPath, isDirectory: true)
            let roms = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "nes" }
            guard roms.count == 1, try LegacySyncPlan.SourceFile.capture(roms[0]).sha256 == row.localROMHash else {
                throw SyncPlanError.invalidInput("A local ROM changed after duplicate review: \(game.name).")
            }
        }
        let available = try proposedCodes(decisions: decisions, includePreviouslyExcluded: true)
        let selected = try (selectedCodes ?? proposedCodes(decisions: decisions)).subtracting(excludedCodes)
        guard selected.isSubset(of: available),
              excludedCodes.isSubset(of: try proposedCodes(decisions: decisions, defaultUnreviewed: true,
                                                           includePreviouslyExcluded: true)
            .union(previouslySelectedCodes ?? [])) else {
            throw SyncPlanError.invalidInput("A removal refers to a different library review.")
        }
        let chosenStructure = structure ?? previousStructure
        let selectedLimit = chosenStructure?.maximumGamesPerPage.rawValue ?? maximumGamesPerPage
        let plan = try LegacySyncPlan.make(localGames: localGames, remoteGames: remoteGames,
            report: report, selectedCodes: selected, maximumGamesPerPage: selectedLimit,
            trialCode: nil, consoleOrder: consoleOrder,
            reviewedLocalCodes: localGames.map(\.code).sorted(), structure: chosenStructure,
            folderArtworkDirectory: folderArtworkDirectory)
        try plan.verifyLocalSources()
        return plan
    }

    /// Proposed selection before explicit removals. The UI can display the default
    /// built-in version while still requiring a decision to create a stage.
    func proposedCodes(decisions: [String: LegacyStockDuplicateReview.Resolution],
                       defaultUnreviewed: Bool = false,
                       includePreviouslyExcluded: Bool = false) throws -> Set<String> {
        var allDecisions = suggestedDecisions.merging(decisions) { _, latest in latest }
        if defaultUnreviewed {
            for row in duplicateReview.rows where row.needsDecision && allDecisions[row.localCode] == nil {
                allDecisions[row.localCode] = .keepBuiltIn
            }
        }
        let resolved = try duplicateReview.resolvedCodes(decisions: allDecisions)
        if let previouslySelectedCodes, !includePreviouslyExcluded {
            var chosen = previouslySelectedCodes.intersection(resolved)
                .union(resolved.intersection(newLocalCodes))
            // When the user reverses an earlier duplicate decision, carry the
            // selected position over to the newly chosen version of that game.
            for row in duplicateReview.rows where row.stockCode != nil {
                guard let stockCode = row.stockCode,
                      let choice = allDecisions[row.localCode] else { continue }
                if choice == .keepImported && previouslySelectedCodes.contains(stockCode) {
                    chosen.insert(row.localCode)
                } else if choice == .keepBuiltIn && previouslySelectedCodes.contains(row.localCode) {
                    chosen.insert(stockCode)
                }
            }
            return chosen
        } else {
            return resolved
        }
    }

    /// Rebuilds the user's choices from a saved, still-inactive full-sync operation.
    /// It accepts only codes that the fresh review can propose from the same library.
    func selectionForSavedPreview(_ selectedCodes: Set<String>) throws -> SavedSelection {
        var decisions = suggestedDecisions
        for row in duplicateReview.rows {
            guard let stockCode = row.stockCode else { continue }
            let imported = selectedCodes.contains(row.localCode)
            let builtIn = selectedCodes.contains(stockCode)
            guard !(imported && builtIn) else {
                throw SyncPlanError.invalidInput("A saved menu selected both versions of \(row.localTitle).")
            }
            decisions[row.localCode] = imported ? .keepImported : .keepBuiltIn
        }
        let proposed = try proposedCodes(decisions: decisions, defaultUnreviewed: true,
                                         includePreviouslyExcluded: true)
        guard selectedCodes.isSubset(of: proposed) else {
            throw SyncPlanError.invalidInput("The saved menu no longer matches this local game library.")
        }
        return SavedSelection(decisions: decisions, excludedCodes: proposed.subtracting(selectedCodes))
    }
}

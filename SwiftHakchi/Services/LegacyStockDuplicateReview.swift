import Foundation
import SwiftHakchiCore

/// Offline duplicate evidence for a proposed NES menu. It never opens USB or edits a ROM.
struct LegacyStockDuplicateReview: Sendable {
    enum Evidence: Sendable, Equatable {
        case exact, titleCandidate, aliasCandidate, distinct
    }

    enum Resolution: Sendable, Equatable {
        case keepBuiltIn, keepImported
    }

    struct Row: Sendable {
        let localCode: String
        let localTitle: String
        let stockCode: String?
        let stockTitle: String?
        let evidence: Evidence
        let localROMHash: String
        let stockROMHash: String?

        var needsDecision: Bool { evidence == .titleCandidate || evidence == .aliasCandidate }
    }

    let rows: [Row]
    let stockCodes: Set<String>

    @MainActor static func make(local: [Game], stock: [Game],
                                factoryROMHashes: [String: String]) throws -> Self {
        let stockCodes = Set(stock.map(\.code))
        let localCodes = Set(local.map(\.code))
        guard stockCodes.count == stock.count, localCodes.count == local.count,
              !stockCodes.isEmpty, localCodes.isDisjoint(with: stockCodes),
              stock.allSatisfy({ $0.isStock && $0.consoleType == .nes && SyncPlanner.validCode($0.code) }),
              local.allSatisfy({ $0.source == .local && $0.consoleType == .nes && SyncPlanner.validCode($0.code) }),
              Set(factoryROMHashes.keys) == stockCodes,
              factoryROMHashes.values.allSatisfy({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) else {
            throw SyncPlanError.invalidInput("The built-in game inventory or factory ROM hashes are incomplete.")
        }

        let rows = try local.map { game -> Row in
            let folder = URL(fileURLWithPath: game.romPath, isDirectory: true).standardizedFileURL
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  folder.lastPathComponent == game.code else {
                throw SyncPlanError.missingFile(game.name)
            }
            let files = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension.lowercased() == "nes" }
            guard files.count == 1 else {
                throw SyncPlanError.invalidInput("\(game.name) needs exactly one raw .nes ROM for duplicate review.")
            }
            let hash = try LegacySyncPlan.SourceFile.capture(files[0]).sha256
            if try GameGenieVariantStore.isManagedCopy(game) {
                return Row(localCode: game.code, localTitle: game.name, stockCode: nil, stockTitle: nil,
                           evidence: .distinct, localROMHash: hash, stockROMHash: nil)
            }
            let exact = stock.filter { factoryROMHashes[$0.code] == hash }
            guard exact.count <= 1 else {
                throw SyncPlanError.invalidInput("One imported ROM matches multiple built-in games; review manually.")
            }
            let match: Game?
            let evidence: Evidence
            if let found = exact.first {
                match = found; evidence = .exact
            } else {
                let title = normalized(game.name)
                let titled = stock.filter { normalized($0.name) == title }
                let aliases = stock.filter { aliasPairs.contains(Pair(local: title, stock: normalized($0.name))) }
                let candidateCodes = Set((titled + aliases).map(\.code))
                guard candidateCodes.count <= 1 else {
                    throw SyncPlanError.invalidInput("\(game.name) matches more than one built-in title; resolve it before staging.")
                }
                match = stock.first { candidateCodes.contains($0.code) }
                evidence = match == nil ? .distinct : (titled.isEmpty ? .aliasCandidate : .titleCandidate)
            }
            return Row(localCode: game.code, localTitle: game.name,
                       stockCode: match?.code, stockTitle: match?.name,
                       evidence: evidence, localROMHash: hash,
                       stockROMHash: match.flatMap { factoryROMHashes[$0.code] })
        }.sorted { ($0.localTitle, $0.localCode) < ($1.localTitle, $1.localCode) }
        return Self(rows: rows, stockCodes: stockCodes)
    }

    func resolvedCodes(decisions: [String: Resolution]) throws -> Set<String> {
        let matched = Set(rows.filter { $0.stockCode != nil }.map(\.localCode))
        guard Set(decisions.keys).isSubset(of: matched) else {
            throw SyncPlanError.invalidInput("A duplicate decision refers to a different library review.")
        }
        var chosen = stockCodes
        var chosenImportedForStock: [String: String] = [:]
        for row in rows {
            guard let stockCode = row.stockCode else {
                chosen.insert(row.localCode)
                continue
            }
            guard !row.needsDecision || decisions[row.localCode] != nil else {
                throw SyncPlanError.invalidInput("Review the possible built-in duplicate: \(row.localTitle).")
            }
            if decisions[row.localCode] == .keepImported {
                guard chosenImportedForStock.updateValue(row.localCode, forKey: stockCode) == nil else {
                    throw SyncPlanError.invalidInput("Choose only one imported version of \(row.stockTitle ?? stockCode).")
                }
                chosen.insert(row.localCode)
                chosen.remove(stockCode)
            }
        }
        for row in rows where row.stockCode != nil {
            if decisions[row.localCode] == .keepBuiltIn,
               let stockCode = row.stockCode, chosenImportedForStock[stockCode] != nil {
                throw SyncPlanError.invalidInput("Duplicate choices for \(row.stockTitle ?? stockCode) conflict.")
            }
        }
        return chosen
    }

    private struct Pair: Hashable {
        let local: String
        let stock: String
    }

    private static let aliasPairs: Set<Pair> = [
        Pair(local: "zelda 1", stock: "the legend of zelda"),
        Pair(local: "zelda 2 the adventure of link", stock: "zelda ii the adventure of link"),
    ]

    private static func normalized(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).joined(separator: " ")
    }
}

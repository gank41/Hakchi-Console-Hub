import Foundation
import SwiftHakchiCore

/// The complete menu that review, staging, and readback must agree on.
struct ConsoleMenuGraph: Codable, Equatable, Sendable {
    enum Warning: String, Codable, Sendable { case stockRootHas31Entries }
    enum Role: String, Codable, Sendable { case back, more, folder }
    enum Entry: Hashable, Sendable { case game(String), link(Int) }

    struct Link: Codable, Equatable, Sendable {
        let target: Int
        let title: String
        let role: Role
        let artKey: String?

        var consoleCode: String { String(format: "CLV-S-%05d", target) }
    }

    struct Screen: Codable, Equatable, Sendable {
        let number: Int
        let title: String
        let gameCodes: [String]
        let links: [Link]
        var backPosition: ConsoleStructure.BackPosition = .bottom

        var entryCount: Int { gameCodes.count + links.count }
        var entries: [Entry] {
            let back = links.filter { $0.role == .back }.map { Entry.link($0.target) }
            let other = links.filter { $0.role != .back }.map { Entry.link($0.target) }
            let games = gameCodes.map(Entry.game)
            return backPosition == .top ? back + games + other : games + other + back
        }
    }

    let screens: [Screen]
    let warnings: [Warning]
    var maximumGamesPerPage: Int = 30
    var resolvedMode: ConsoleStructure.Mode = .pagesEqual

    func validate(selectedCodes: Set<String>) throws {
        guard !screens.isEmpty, screens.count <= 999,
              screens.enumerated().allSatisfy({ $0.offset == $0.element.number }),
              selectedCodes.allSatisfy({ SyncPlanner.validCode($0) && !$0.hasPrefix("CLV-S-") }) else {
            throw SyncPlanError.invalidInput("The menu has invalid game codes or screen numbering.")
        }
        let chosen = screens.flatMap(\.gameCodes)
        guard chosen.count == selectedCodes.count, Set(chosen) == selectedCodes else {
            throw SyncPlanError.invalidInput("Each selected game must appear on exactly one screen.")
        }
        for screen in screens {
            let stockRootMode: Bool = [.stockRootPagesEqual, .stockRootFoldersEqual,
                                       .stockRootFoldersAlphabetical].contains(resolvedMode)
            let stockRootException = screen.number == 0 && stockRootMode &&
                screen.gameCodes.count <= 30 && screen.links.count <= 1 &&
                screen.links.allSatisfy({ $0.role == .folder }) && screen.entryCount <= 31
            guard Self.safeTitle(screen.title), (screen.gameCodes.count <= maximumGamesPerPage || stockRootException),
                  (screen.entryCount <= maximumGamesPerPage + 2 || stockRootException),
                  screen.links.count <= 30 else {
                throw SyncPlanError.invalidInput("A menu screen has an unsafe title or too many entries.")
            }
            let targets = screen.links.map(\.target)
            guard Set(targets).count == targets.count,
                  targets.allSatisfy({ $0 >= 0 && $0 < screens.count && $0 != screen.number }),
                  screen.links.allSatisfy({ Self.safeTitle($0.title) && ($0.artKey == nil || Self.safeArtKey($0.artKey!)) }) else {
                throw SyncPlanError.invalidInput("A navigation link is duplicated or unsafe.")
            }
        }
        var reached: Set<Int> = [0]
        var pending = [0]
        while let page = pending.popLast() {
            for target in screens[page].links.map(\.target) where reached.insert(target).inserted {
                pending.append(target)
            }
        }
        guard reached.count == screens.count else {
            throw SyncPlanError.invalidInput("A menu screen cannot be reached from the root.")
        }
        let crowdedStockRoot = screens[0].gameCodes.count == 30 && screens[0].entryCount == 31
        guard !crowdedStockRoot || warnings.contains(.stockRootHas31Entries),
              warnings.filter({ $0 == .stockRootHas31Entries }).isEmpty || crowdedStockRoot else {
            throw SyncPlanError.invalidInput("A crowded built-in root needs an explicit warning.")
        }
    }

    private static func safeTitle(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func safeArtKey(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}\.png$"#, options: .regularExpression) != nil
            && !value.contains("..")
    }
}

import Foundation

public struct MenuPage: Equatable, Sendable {
    public let number: Int
    public let gameCodes: [String]
    public let previousPage: Int?
    public let nextPage: Int?
    public var entryCount: Int { gameCodes.count + (previousPage == nil ? 0 : 1) + (nextPage == nil ? 0 : 1) }
}

public enum MenuPaginator {
    public static func pages(codes: [String], maximumEntries: Int = 30) throws -> [MenuPage] {
        guard maximumEntries >= 3, maximumEntries <= 30 else {
            throw SyncPlanError.invalidInput("The menu has invalid identifiers or page limits.")
        }
        return try balancedPages(codes: codes, capacity: maximumEntries - 2, unsplitLimit: maximumEntries)
    }

    public static func pages(codes: [String], maximumGamesPerPage: Int) throws -> [MenuPage] {
        guard ConsoleMenuLimit(rawValue: maximumGamesPerPage) != nil else {
            throw SyncPlanError.invalidInput("Choose a supported maximum games per page/folder value.")
        }
        return try balancedPages(codes: codes, capacity: maximumGamesPerPage, unsplitLimit: maximumGamesPerPage)
    }

    private static func balancedPages(codes: [String], capacity: Int, unsplitLimit: Int) throws -> [MenuPage] {
        guard codes.allSatisfy({ SyncPlanner.validCode($0) && !$0.hasPrefix("CLV-S-") }), Set(codes).count == codes.count else {
            throw SyncPlanError.invalidInput("The menu has invalid or duplicate game identifiers.")
        }
        guard codes.count > unsplitLimit else {
            return [MenuPage(number: 0, gameCodes: codes, previousPage: nil, nextPage: nil)]
        }
        // Balance pages to avoid an almost-empty final screen.
        let count = (codes.count + capacity - 1) / capacity
        let base = codes.count / count
        let extra = codes.count % count
        var offset = 0
        return (0..<count).map { index in
            let size = base + (index < extra ? 1 : 0)
            defer { offset += size }
            return MenuPage(number: index, gameCodes: Array(codes[offset..<offset + size]),
                previousPage: index == 0 ? nil : index - 1, nextPage: index + 1 == count ? nil : index + 1)
        }
    }
}

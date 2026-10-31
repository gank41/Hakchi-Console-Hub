import Foundation
import SwiftHakchiCore

/// Order of game entries on the console; independent of the Mac library sort setting.
enum ConsoleMenuOrder: Codable, Equatable, Sendable {
    case title
    case releaseDate
    case publisher
    case manual([String])

    var reviewKey: String {
        switch self {
        case .title: return "title"
        case .releaseDate: return "release-date"
        case .publisher: return "publisher"
        case .manual(let codes): return "manual:" + codes.joined(separator: ",")
        }
    }

    func ordered(_ games: [Game]) throws -> [Game] {
        let codes = games.map(\.code)
        guard Set(codes).count == codes.count else {
            throw SyncPlanError.invalidInput("The console menu contains duplicate game codes.")
        }
        switch self {
        case .title:
            // Preserve the existing trial's exact order and review digest.
            return games.sorted { titleKey($0) < titleKey($1) }
        case .releaseDate:
            return games.sorted { a, b in
                let x = Self.validDate(a.releaseDate), y = Self.validDate(b.releaseDate)
                if x != y { return (x ?? "9999") < (y ?? "9999") }
                return titleKey(a) < titleKey(b)
            }
        case .publisher:
            return games.sorted { a, b in
                let x = Self.validPublisher(a.publisher), y = Self.validPublisher(b.publisher)
                if x != y { return (x ?? "\u{10FFFF}") < (y ?? "\u{10FFFF}") }
                return titleKey(a) < titleKey(b)
            }
        case .manual(let orderedCodes):
            guard orderedCodes.count == codes.count, Set(orderedCodes) == Set(codes) else {
                throw SyncPlanError.invalidInput("Manual console order must contain every selected game exactly once.")
            }
            let byCode = Dictionary(uniqueKeysWithValues: games.map { ($0.code, $0) })
            return orderedCodes.compactMap { byCode[$0] }
        }
    }

    private func titleKey(_ game: Game) -> (String, String) {
        (game.sortName.isEmpty ? game.name : game.sortName, game.code)
    }

    private static func validDate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "1900-01-01",
              trimmed.range(of: #"^[0-9]{4}(-[0-9]{2})?(-[0-9]{2})?$"#, options: .regularExpression) != nil,
              let year = Int(trimmed.prefix(4)), (1970...2100).contains(year) else { return nil }
        return trimmed
    }

    private static func validPublisher(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.uppercased() != "UNKNOWN" else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
    }
}

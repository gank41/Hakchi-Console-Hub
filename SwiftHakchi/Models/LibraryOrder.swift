import Foundation

enum LibraryOrder: String, Codable, CaseIterable, Identifiable {
    case nameAscending, nameDescending, dateAdded, dateModified, cheatCodesFirst
    var id: Self { self }
    var label: String {
        switch self {
        case .nameAscending: return "Name A–Z"
        case .nameDescending: return "Name Z–A"
        case .dateAdded: return "Date Added (newest)"
        case .dateModified: return "Date Modified (newest)"
        case .cheatCodesFirst: return "Cheat Codes First"
        }
    }
    func ordered(_ games: [Game]) -> [Game] {
        games.sorted { a, b in
            if self == .cheatCodesFirst, a.isCheatCodeCopy != b.isCheatCodeCopy { return a.isCheatCodeCopy }
            if self == .dateAdded || self == .dateModified {
                let x = self == .dateAdded ? a.addedAt : a.modifiedAt
                let y = self == .dateAdded ? b.addedAt : b.modifiedAt
                if x != y { return (x ?? .distantPast) > (y ?? .distantPast) }
            }
            let comparison = a.name.localizedStandardCompare(b.name)
            if comparison != .orderedSame {
                return comparison == (self == .nameDescending ? .orderedDescending : .orderedAscending)
            }
            return a.code < b.code
        }
    }
}

import Foundation

struct IncludedGameDuplicate: Sendable, Equatable {
    let importCode: String
    let importedTitle: String
    let builtInTitle: String
}

enum IncludedGameImportChoice { case skipMatches, keepCopies, cancel }
struct ROMImportSummary {
    let added: Int
    let skippedLocal: Int
    let skippedIncluded: Int
    let keptIncluded: Int
    var message: String {
        var parts = ["Added \(added) games."]
        if skippedLocal > 0 { parts.append("\(skippedLocal) already in your Mac library were skipped.") }
        if skippedIncluded > 0 { parts.append("\(skippedIncluded) built-in title matches were skipped.") }
        if keptIncluded > 0 { parts.append("\(keptIncluded) built-in title matches were kept unchecked; select them only if you want to sync your copies.") }
        parts.append("Your original files are unchanged.")
        return parts.joined(separator: " ")
    }
}

enum IncludedGameDuplicates {
    static func match(title: String, originalTitle: String? = nil, console: ConsoleType,
                      stock: [Game]) -> Game? {
        guard console != .unknown,
              ![title, originalTitle].compactMap({ $0 }).contains(where: { value in
                  [" [Cheat Code]", " [Cheat Codes]", " [Game Genie]"].contains(where: value.hasSuffix)
              }) else { return nil }
        let names = Set([title, originalTitle].compactMap { $0 }.map(normalized).filter { !$0.isEmpty })
        return stock.first { $0.isStock && $0.consoleType == console &&
            !names.isDisjoint(with: [normalized($0.name), normalized($0.defaultName)]) }
    }

    private static func normalized(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        // Common catalog spelling: “Legend of Zelda, The - …”. This is an exact
        // article-order normalization, not fuzzy matching or ROM identity proof.
        let ordered = folded.replacingOccurrences(of: #"^([^,]+),\s*(the|a|an)(?=\s*(?:[-:–—]|$))"#,
            with: "$2 $1", options: .regularExpression)
        let value = ordered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        switch value {
        case "zelda 1": return "the legend of zelda"
        case "zelda 2 the adventure of link": return "zelda ii the adventure of link"
        default: return value
        }
    }
}

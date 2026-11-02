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
        var parts = ["Added \(added) \(added == 1 ? "game" : "games")."]
        if skippedLocal > 0 { parts.append("\(skippedLocal) already in your Mac library were skipped.") }
        if skippedIncluded > 0 { parts.append("\(skippedIncluded) built-in title matches were skipped.") }
        if keptIncluded > 0 { parts.append("\(keptIncluded) built-in title matches were kept unchecked; select them only if you want to sync your copies.") }
        parts.append("Your original files are unchanged.")
        return parts.joined(separator: " ")
    }
}

enum IncludedGameDuplicates {
    // Title hints only, based on Nintendo's published US Classic Edition lists.
    // They are not a console inventory or proof that ROM bytes match.
    private static let usNES = [
        "Balloon Fight", "Bubble Bobble", "Castlevania", "Castlevania II: Simon's Quest", "Donkey Kong", "Donkey Kong Jr.",
        "Double Dragon II: The Revenge", "Dr. Mario", "Excitebike", "Final Fantasy", "Galaga", "Ghosts 'n Goblins",
        "Gradius", "Ice Climber", "Kid Icarus", "Kirby's Adventure", "Mario Bros.", "Mega Man 2", "Metroid", "Ninja Gaiden",
        "Pac-Man", "Punch-Out!! Featuring Mr. Dream", "StarTropics", "Super C", "Super Mario Bros.", "Super Mario Bros. 2",
        "Super Mario Bros. 3", "Tecmo Bowl", "The Legend of Zelda", "Zelda II: The Adventure of Link"
    ]
    private static let usSNES = [
        "Contra III: The Alien Wars", "Donkey Kong Country", "Kirby Super Star", "Kirby's Dream Course", "Secret of Mana",
        "Street Fighter II Turbo: Hyper Fighting", "Super Mario Kart", "Super Mario World", "Final Fantasy III",
        "Super Castlevania IV", "EarthBound", "F-Zero", "Mega Man X", "Star Fox", "Star Fox 2", "Super Ghouls 'n Ghosts",
        "Super Mario RPG: Legend of the Seven Stars", "Super Metroid", "Super Punch-Out!!", "The Legend of Zelda: A Link to the Past", "Yoshi's Island"
    ]
    static func titleHint(title: String, originalTitle: String? = nil, console: ConsoleType, stock: [Game]) -> String? {
        if let actual = match(title: title, originalTitle: originalTitle, console: console, stock: stock) { return actual.name }
        guard !stock.contains(where: { $0.isStock && $0.consoleType == console }),
              !isCheatCopy(title, originalTitle) else { return nil }
        let list: [String]
        switch console { case .nes: list = usNES; case .snesUsa: list = usSNES; default: return nil }
        let names = Set([title, originalTitle].compactMap { $0 }.map(normalized).filter { !$0.isEmpty })
        return list.first { names.contains(normalized($0)) }
    }
    private static func isCheatCopy(_ title: String, _ originalTitle: String?) -> Bool {
        [title, originalTitle].compactMap { $0 }.contains { value in
            [" [Cheat Code]", " [Cheat Codes]", " [Game Genie]"].contains(where: value.hasSuffix)
        }
    }
    static func match(title: String, originalTitle: String? = nil, console: ConsoleType,
                      stock: [Game]) -> Game? {
        guard console != .unknown, !isCheatCopy(title, originalTitle) else { return nil }
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
        case "super mario world 2 yoshi s island", "super mario world 2 yoshis island", "yoshis island": return "yoshi s island"
        default: return value
        }
    }
}

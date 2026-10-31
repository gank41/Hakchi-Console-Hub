import Foundation

enum RetroArchCheatFile {
    enum ExportError: LocalizedError {
        case noEffects, incompatibleGroup(String)
        var errorDescription: String? {
            switch self {
            case .noEffects: return "Add at least one named effect before exporting runtime cheats."
            case .incompatibleGroup(let name): return "\(name): this effect has a conflicting same-address group or exceeds the portable code-group limit. Review its codes for the selected FCEUmm version."
            }
        }
    }
    /// Historical Classic parsers do not reliably understand backslash-escaped quotes.
    /// Keep originals in the profile/manifest; project only the portable display string.
    static func label(_ text: String) -> String {
        let cleaned = text.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            if scalar == "\"" { return "'" }
            if scalar == "\\" { return "/" }
            return String(scalar)
        }.joined()
        return cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func encode(profile: GameGenieProfile) throws -> Data {
        try profile.validate(sha256: profile.romSHA256)
        guard !profile.effects.isEmpty else { throw ExportError.noEffects }
        var lines = ["# NES Cheat Codes — emulator-handled FCEUmm format", "# All effects start disabled. Validate core/version and ROM revision on the console.", "cheats = \(profile.effects.count)", ""]
        var notes = Set<String>()
        for (index, effect) in profile.effects.enumerated() {
            var addresses: [UInt16: String] = [:]
            var codes: [String] = []
            for code in effect.codes.map({ $0.uppercased() }) {
                guard let decoded = GameGenieNES.decode(code) else { throw GameGenieError.invalidCode(code) }
                if let previous = addresses[decoded.address] {
                    guard previous == code else { throw ExportError.incompatibleGroup(effect.name) }
                    continue
                }
                addresses[decoded.address] = code; codes.append(code)
            }
            let group = codes.joined(separator: "+")
            guard group.utf8.count <= 127 else { throw ExportError.incompatibleGroup(effect.name) }
            if let source = effect.source { lines.append("# Source: " + label(source)) }
            for note in effect.notes ?? [] where notes.insert(note).inserted { lines.append("# Note: " + label(note)) }
            lines.append("cheat\(index)_desc = \"\(label(effect.name))\"")
            lines.append("cheat\(index)_code = \"\(group)\"")
            lines.append("cheat\(index)_enable = false")
            lines.append("cheat\(index)_handler = 0")
            lines.append("")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

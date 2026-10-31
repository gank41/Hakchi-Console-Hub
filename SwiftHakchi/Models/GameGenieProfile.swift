import Foundation

struct GameGenieEffect: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var codes: [String]
    var enabled = false
    var source: String? = nil
    var notes: [String]? = nil
    static func codes(from text: String) -> [String] {
        text.uppercased().components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))).filter { !$0.isEmpty }
    }
}

struct GameGenieProfile: Codable, Equatable, Sendable {
    static let maximumStoredBytes = 1024 * 1024
    var version = 1
    var system: GameGenieSystem? = nil
    var codeSystem: GameGenieSystem { system ?? .nes }
    let romSHA256: String
    var effects: [GameGenieEffect] = []
    var enabledCodes: [String] { effects.filter(\.enabled).flatMap(\.codes) }
    func encodedForStorage() throws -> Data {
        try validate(sha256: romSHA256)
        // Bound raw text before allocating the encoded representation; escaping is checked below.
        var textBytes = romSHA256.utf8.count
        for effect in effects {
            textBytes += effect.name.utf8.count + (effect.source?.utf8.count ?? 0)
            for note in effect.notes ?? [] { textBytes += note.utf8.count }
            guard textBytes <= Self.maximumStoredBytes else { throw GameGenieError.profileTooLarge }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumStoredBytes else { throw GameGenieError.profileTooLarge }
        return data
    }
    func validate(sha256: String) throws {
        guard version == 1, romSHA256 == sha256 else { throw GameGenieError.changedROM }
        guard effects.count <= 100, Set(effects.map(\.id)).count == effects.count else { throw GameGenieError.invalidProfile }
        for effect in effects {
            guard !effect.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, effect.name.count <= 512,
                  !effect.codes.isEmpty, effect.codes.count <= 32,
                  effect.codes.allSatisfy({ codeSystem.accepts($0) }),
                  (effect.source?.count ?? 0) <= 16_384, (effect.notes?.count ?? 0) <= 256,
                  effect.notes?.allSatisfy({ $0.count <= 8192 }) ?? true else { throw GameGenieError.invalidProfile }
        }
    }
}

enum GameGenieError: LocalizedError {
    case invalidCode(String), compareNotFound(String), conflict, changedROM, invalidProfile, unsupportedROM, noCodes, unsafeDestination, profileTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidCode(let code): return "Invalid Cheat Codes code: \(code). Check the code format for the selected console."
        case .compareNotFound(let code): return "\(code): compare byte not found. Check the game's region and ROM revision."
        case .conflict: return "Enabled codes write different values to the same byte. Disable one effect before exporting."
        case .changedROM: return "The ROM or workspace has changed. Reopen Cheat Codes for the current managed copy. The saved profile is preserved."
        case .invalidProfile: return "Each effect needs a name and 1–32 valid codes for this console. Up to 100 effects are supported."
        case .unsupportedROM: return "Use a supported raw NES, SNES or Genesis ROM. Compressed, interleaved and special cartridge layouts may need separate support."
        case .profileTooLarge: return "This annotated profile exceeds the 1 MiB storage limit. Remove some effects before saving or exporting; the previous saved profile is unchanged."
        case .unsafeDestination: return "Cheat Codes needs ordinary workspace folders. A profile or export folder is a symbolic link or is not a directory."
        case .noCodes: return "Enable at least one effect to preview or export."
        }
    }
}

enum NESGameGeniePatcher {
    struct Result { let data: Data; let offsets: [Int] }
    /// Static ROM patching. UxROM uses its actual 16 KiB CPU windows;
    /// other mappers retain the legacy hakchi2 PRG scan, not runtime emulation.
    static func patch(data: Data, codes: [String]) throws -> Result {
        let identity = try NESROMIdentity(data: data)
        guard !codes.isEmpty, codes.count <= 3200 else { throw GameGenieError.noCodes }
        let start = identity.content.lowerBound
        let length = Int(data[4]) * 16_384
        var writes: [Int: UInt8] = [:]
        for code in codes {
            guard let decoded = GameGenieNES.decode(code) else { throw GameGenieError.invalidCode(code) }
            var positions: [Int]
            if identity.mapper == 2 {
                // $C000-$FFFF always reads the final 16 KiB bank. Scanning
                // every 8 KiB here corrupts unrelated code and graphics.
                let offset = Int(decoded.address & 0x3FFF)
                if decoded.address >= 0xC000 {
                    positions = [length - 0x4000 + offset]
                } else {
                    positions = Array(stride(from: offset, to: length, by: 0x4000))
                }
            } else if decoded.compare == nil && length <= 0x8000 {
                positions = [Int(decoded.address & 0x7FFF) % length]
            } else {
                positions = Array(stride(from: Int(decoded.address) % 0x2000, to: length, by: 0x2000))
            }
            if let compare = decoded.compare { positions = positions.filter { data[start + $0] == compare } }
            guard !positions.isEmpty else { throw GameGenieError.compareNotFound(code) }
            for position in positions {
                let offset = start + position
                if let previous = writes[offset], previous != decoded.value { throw GameGenieError.conflict }
                writes[offset] = decoded.value
            }
        }
        var copy = data
        for (offset, value) in writes { copy[offset] = value }
        return Result(data: copy, offsets: writes.keys.sorted())
    }
}

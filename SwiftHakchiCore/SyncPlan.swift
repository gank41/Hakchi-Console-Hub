import Foundation

public enum SyncPlanError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case missingFile(String)
    case insufficientSpace(required: Int64, available: Int64)
    case unsupportedConsole
    case unsafeCommand

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): return message
        case .missingFile(let path): return "A selected game's files are missing or unreadable: \(path)"
        case .insufficientSpace(let required, let available):
            return "Copying needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .binary)) free, including temporary transfer files and reserved space. The console has \(ByteCountFormatter.string(fromByteCount: available, countStyle: .binary)). Clean up old files or select fewer games, then review again."
        case .unsupportedConsole: return "Game synchronization requires an identified, compatible NES console. This console is available for inspection only."
        case .unsafeCommand: return "The game's launch command is unsupported or ambiguous. Review its ROM path and emulator settings before syncing."
        }
    }
}

public struct SyncGameInput: Sendable {
    public let code: String
    public let name: String
    public let sortName: String
    public let isStock: Bool
    public let localDirectory: URL?
    public let romFilename: String?
    public let desktopData: Data
    public let selected: Bool
    public let byteCount: Int64

    public init(code: String, name: String, isStock: Bool, localDirectory: URL?, romFilename: String?, desktopData: Data, selected: Bool, byteCount: Int64, sortName: String = "") {
        self.code = code; self.name = name; self.sortName = sortName; self.isStock = isStock
        self.localDirectory = localDirectory; self.romFilename = romFilename
        self.desktopData = desktopData; self.selected = selected; self.byteCount = byteCount
    }
}

public struct SyncPlan: Sendable {
    public let profile: ConsoleProfile
    public let selectedGames: [SyncGameInput]
    public let gameNames: [String: String]
    public let addedCodes: Set<String>
    public let keptCodes: Set<String>
    public let removedCodes: Set<String>
    public let pages: [MenuPage]
    public let maximumGamesPerPage: Int
    public let requiredStagingBytes: Int64
}

public enum SyncPlanner {
    public static func validCode(_ code: String) -> Bool {
        code.range(of: #"^CLV-[A-Z]-[A-Z0-9]{5}$"#, options: .regularExpression) != nil
    }

    public static func makePlan(inputs: [SyncGameInput], installedCodes: Set<String>, profile: ConsoleProfile, freeBytes: Int64, reserveBytes: Int64, maximumGamesPerPage: Int = 30) throws -> SyncPlan {
        guard profile.supportsGameSync else { throw SyncPlanError.unsupportedConsole }
        guard freeBytes >= 0, reserveBytes >= 0 else { throw SyncPlanError.invalidInput("Storage measurement is invalid.") }
        guard inputs.allSatisfy({ validCode($0.code) && !$0.code.hasPrefix("CLV-S-") && $0.byteCount >= 0 }),
              Set(inputs.map(\.code)).count == inputs.count,
              installedCodes.allSatisfy(validCode) else {
            throw SyncPlanError.invalidInput("The library has invalid or duplicate game identifiers.")
        }
        let selected = inputs.filter(\.selected).sorted {
            ($0.sortName.isEmpty ? $0.name : $0.sortName, $0.code)
                < ($1.sortName.isEmpty ? $1.name : $1.sortName, $1.code)
        }
        var bytes: Int64 = 4096
        for input in selected {
            if !input.isStock {
                guard let directory = input.localDirectory, let filename = input.romFilename,
                      filename == (filename as NSString).lastPathComponent, !filename.isEmpty,
                      filename != ".", filename != "..",
                      FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(filename).path) else {
                    throw SyncPlanError.missingFile(input.name)
                }
            }
            // Include menu entries, archive padding, and conservative artwork overhead.
            let (total, overflow) = bytes.addingReportingOverflow(input.byteCount)
            guard !overflow else { throw SyncPlanError.invalidInput("The library size is too large.") }
            bytes = total
            let (withOverhead, overheadOverflow) = bytes.addingReportingOverflow(64 * 1024)
            guard !overheadOverflow else { throw SyncPlanError.invalidInput("The library size is too large.") }
            bytes = withOverhead
        }
        let (required, overflow) = bytes.addingReportingOverflow(reserveBytes)
        guard !overflow, required <= freeBytes else {
            throw SyncPlanError.insufficientSpace(required: overflow ? Int64.max : required, available: freeBytes)
        }
        let customCodes = Set(selected.filter { !$0.isStock }.map(\.code))
        return SyncPlan(profile: profile, selectedGames: selected, gameNames: Dictionary(uniqueKeysWithValues: inputs.map { ($0.code, $0.name) }),
            addedCodes: customCodes.subtracting(installedCodes), keptCodes: customCodes.intersection(installedCodes),
            removedCodes: installedCodes.subtracting(customCodes),
            pages: try MenuPaginator.pages(codes: selected.map(\.code), maximumGamesPerPage: maximumGamesPerPage),
            maximumGamesPerPage: maximumGamesPerPage, requiredStagingBytes: bytes)
    }
}

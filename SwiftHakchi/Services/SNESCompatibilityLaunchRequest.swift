import Foundation

/// A prepared local game identity. The frame carries no launch authority and
/// must only be sent through the supervisor's privately owned channel after
/// the console executable and its save locations have been independently checked.
struct SNESCompatibilityLaunchRequest: Sendable {
    let frame: Data
    let source: SNESLibraryROMSource

    // Data slices can retain nonzero indices. The wire-format consumers use
    // fixed offsets, so normalize on entry rather than indexing a slice.
    init(frame: Data, source: SNESLibraryROMSource) {
        self.frame = Data(Array(frame))
        self.source = source
    }

    /// Correlates an observed console-created session with an independently
    /// selected local game and ROM. The result is untrusted observation, not
    /// authentication or authority to launch, restore, or delete anything.
    static func observeConsoleFrame(_ frame: Data, game: Game, source: SNESLibraryROMSource) throws -> Self {
        guard frame.count == 107 else {
            throw SNESLibraryCompatibility.failure("The observed session could not be verified.")
        }
        let bytes = Array(frame)
        let session = Data(bytes[83..<99])
        let epoch = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[99 + $1]) << (8 * $1) }
        let canonical = try prepare(game: game, source: source, session: session, epoch: epoch)
        guard canonical.frame.elementsEqual(bytes) else {
            throw SNESLibraryCompatibility.failure("The observed session could not be verified.")
        }
        return canonical
    }

    /// Recheck the reviewed directory as well as the ROM bytes before using
    /// a saved request. Callers must still exclude concurrent modifications.
    func verifySource() throws {
        let parent = try RestoreDirectory(source.directory)
        func checkNames() throws {
            let names = try parent.names().filter { ["sfc", "smc"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            guard names.count == 1, names.first == source.filename else {
                throw SNESLibraryCompatibility.failure("The game folder changed. Prepare a new review.")
            }
            try parent.check()
        }
        try checkNames(); try source.verify(); try checkNames()
    }

    static func prepare(game: Game, source: SNESLibraryROMSource, session: Data, epoch: UInt64) throws -> Self {
        let directory = URL(fileURLWithPath: game.romPath, isDirectory: true).standardizedFileURL
        guard game.source == .local, game.consoleType == .snesUsa,
              SNESRecoveryBinding.validGameCode(game.code), directory.lastPathComponent == game.code,
              directory == source.directory.standardizedFileURL,
              session.count == 16, session.contains(where: { $0 != 0 }), epoch > 0,
              source.sha256.utf8.count == 64, SNESRuntimeBinding.hex(source.sha256) else {
            throw SNESLibraryCompatibility.failure("The selected game could not be verified. Prepare a new review.")
        }
        let parent = try RestoreDirectory(directory)
        func checkROM() throws {
            let names = try parent.names().filter { ["sfc", "smc"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            guard names.count == 1, names.first == source.filename else {
                throw SNESLibraryCompatibility.failure("Keep one SNES game file in this game’s folder and prepare a new review.")
            }
            try source.verify()
            try parent.check()
        }
        try checkROM()
        var frame = Data("HCLREQ1\0".utf8)
        frame.append(contentsOf: game.code.utf8)
        frame.append(contentsOf: source.sha256.utf8)
        frame.append(session)
        for shift in stride(from: 0, through: 56, by: 8) { frame.append(UInt8(truncatingIfNeeded: epoch >> shift)) }
        guard frame.count == 107 else { throw SNESLibraryCompatibility.failure("The selected game could not be verified.") }
        try checkROM()
        return Self(frame: frame, source: source)
    }
}

extension SNESLibraryCompatibility {
    /// Prepare a group of reviewed compatibility games on the Mac. This does
    /// not add them to a menu or authorize a transfer or console launch.
    func prepareCompatibilityLaunches(selected: Set<String>, decisions: [String: Resolution], sessions: [String: Data], epoch: UInt64) throws -> [String: SNESCompatibilityLaunchRequest] {
        guard epoch > 0 else { throw Self.failure("The session details changed. Prepare a new review.") }
        let candidates = try compatibilitySelection(selected: selected, decisions: decisions).candidates
        guard Set(sessions.keys) == candidates,
              sessions.values.allSatisfy({ $0.count == 16 && $0.contains(where: { $0 != 0 }) }),
              Set(sessions.values).count == sessions.count else {
            throw Self.failure("The selected games or session details changed. Prepare a new review.")
        }
        var result: [String: SNESCompatibilityLaunchRequest] = [:]
        for code in candidates.sorted() {
            guard let token = sessions[code] else { throw Self.failure("The selected games changed. Prepare a new review.") }
            result[code] = try prepareCompatibilityLaunch(code: code, selected: selected, decisions: decisions, session: token, epoch: epoch)
        }
        for code in candidates.sorted() {
            guard let request = result[code] else { throw Self.failure("The selected games changed. Prepare a new review.") }
            try request.verifySource()
        }
        return result
    }
    /// Resolves the preview using the same duplicate choices as the batch.
    /// No returned code authorizes a console menu or a transfer.
    func compatibilitySelection(selected: Set<String>, decisions: [String: Resolution]) throws -> (resolved: Set<String>, candidates: Set<String>) {
        let codes = rows.map { $0.game.code }
        guard codes.count <= 256, Set(codes).count == codes.count,
              stockCodes.isDisjoint(with: Set(codes)), selected.isSubset(of: Set(codes)),
              Set(decisions.keys).isSubset(of: selected) else {
            throw Self.failure("The selection changed. Prepare a new review.")
        }
        let byCode = Dictionary(uniqueKeysWithValues: rows.map { ($0.game.code, $0) })
        var resolved = stockCodes, candidates = Set<String>(), replaced = Set<String>(), kept = Set<String>()
        for code in selected.sorted() {
            guard let row = byCode[code], Set(row.matches).count == row.matches.count,
                  Set(row.matches).isSubset(of: stockCodes),
                  !(row.matches.isEmpty && decisions[code] != nil) else {
                throw Self.failure("The duplicate choices changed. Prepare a new review.")
            }
            if row.needsDecision && decisions[code] == nil {
                throw Self.failure("Choose which version to keep for \(row.game.name).")
            }
            if !row.matches.isEmpty && decisions[code] != .keepImported {
                kept.formUnion(row.matches)
                continue
            }
            if !row.matches.isEmpty {
                guard row.matches.count == 1, let original = row.matches.first, replaced.insert(original).inserted else {
                    throw Self.failure("Choose only one imported version for each built-in game.")
                }
                resolved.remove(original)
            }
            switch row.readiness {
            case .ready: resolved.insert(code)
            case .appSupportNeeded: candidates.insert(code); resolved.insert(code)
            case .fileCheck, .notStandalone:
                throw Self.failure("\(row.game.name) needs a file check before it can be prepared.")
            }
        }
        guard kept.isDisjoint(with: replaced), resolved.count <= 304 else { throw Self.failure("Some duplicate choices conflict. Keep one version of each game.") }
        return (resolved, candidates)
    }
    /// Prepares only an explicitly selected compatibility candidate. This is
    /// an offline review artifact; no console transfer or launch is enabled.
    func prepareCompatibilityLaunch(code: String, selected: Set<String>, decisions: [String: Resolution],
                                    session: Data, epoch: UInt64) throws -> SNESCompatibilityLaunchRequest {
        let matches = rows.filter { $0.game.code == code }
        guard matches.count == 1, selected.contains(code),
              selected.isSubset(of: Set(rows.map { $0.game.code })),
              Set(decisions.keys).isSubset(of: selected), let row = matches.first,
              case .appSupportNeeded = row.readiness, let source = row.source,
              row.matches.count <= 1, Set(row.matches).isSubset(of: stockCodes),
              row.matches.isEmpty ? decisions[code] == nil : decisions[code] == .keepImported else {
            throw Self.failure("Choose a selected game and review any built-in duplicate before preparing compatibility support.")
        }
        return try SNESCompatibilityLaunchRequest.prepare(game: row.game, source: source, session: session, epoch: epoch)
    }
}

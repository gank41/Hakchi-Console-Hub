import Foundation
import Darwin
import SwiftHakchiCore

/// Bounded descriptor-bound local input. It conveys no console or mutation permission.
struct SNESLibraryROMSource: Sendable {
    let directory: URL, filename: String, sha256: String, byteCount: Int
    private init(directory: URL, filename: String, bytes: Data) {
        self.directory = directory; self.filename = filename
        sha256 = BackupManifest.digest(bytes); byteCount = bytes.count
    }
    static func capture(directory: URL, filename: String) throws -> (Self, Data) {
        let data = try read(directory, filename)
        return (.init(directory: directory, filename: filename, bytes: data), data)
    }
    func verify() throws {
        let data = try Self.read(directory, filename)
        guard data.count == byteCount, BackupManifest.digest(data) == sha256 else {
            throw SNESLibraryCompatibility.failure("The ROM changed. Prepare a new review.")
        }
    }
    private static func read(_ directory: URL, _ name: String) throws -> Data {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw RestoreDirectory.failure() }
        let parent = try RestoreDirectory(directory)
        let fd = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RestoreDirectory.failure() }
        defer { close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 4 * 1024 * 1024 + 512 else { throw RestoreDirectory.failure() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, count <= Int(before.st_size) - result.count else { throw RestoreDirectory.failure() }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1, after.st_nlink == 1,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino,
              after.st_size == before.st_size, named.st_size == before.st_size, result.count == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw RestoreDirectory.failure()
        }
        try parent.check()
        return result
    }
}

/// Offline compatibility/duplicate evidence. A review never edits the library selection.
struct SNESLibraryCompatibility: Sendable {
    enum Evidence: Sendable { case distinct, exact, possible }
    enum Resolution: Sendable { case keepBuiltIn, keepImported }
    enum Readiness: Sendable {
        case ready, appSupportNeeded, fileCheck, notStandalone
        var title: String {
            switch self {
            case .ready: return "Ready for sync review"
            case .appSupportNeeded: return "Compatibility support needed"
            case .fileCheck: return "File check needed"
            case .notStandalone: return "Adapter software"
            }
        }
    }
    struct Row: Sendable {
        let game: Game, source: SNESLibraryROMSource?, prepared: SNESCanoeImage.Result?
        let issue: String?, matches: [String], evidence: Evidence
        var preparationError: SNESCanoeImage.PreparationError? = nil
        var readiness: Readiness {
            if issue == nil && prepared != nil { return .ready }
            switch preparationError {
            case .unsupportedCartridge, .unsupportedRegion, .knownCompatibilityReview: return .appSupportNeeded
            case .adapterSoftware: return .notStandalone
            default: return .fileCheck
            }
        }
        var guidance: String? {
            guard issue != nil else { return nil }
            switch readiness {
            case .appSupportNeeded:
                return "The app needs additional emulator support for this game. Leave it on your Mac for now; you do not need to change its technical settings."
            case .notStandalone:
                return "Super Game Boy is software for a Game Boy cartridge adapter. It cannot be played as a standalone SNES game."
            case .fileCheck:
                if preparationError == .checksumNeedsReview {
                    return "The game's internal checksum doesn't match this file. The file may be modified or incomplete; check its source or try another verified copy. Your original file is unchanged."
                }
                if preparationError != nil { return "The app could not verify this ROM file. Keep the original on your Mac; choose another copy you own, or leave this game out of this sync." }
                return issue
            case .ready: return nil
            }
        }
        var needsDecision: Bool { evidence == .possible }
    }
    let rows: [Row], stockCodes: Set<String>
    static func failure(_ message: String) -> SyncPlanError { .invalidInput(message) }
    /// Local library classification uses the same ROM checks as sync review.
    /// It does not change selection or establish that a game will play.
    static func libraryAttention(games: [Game]) -> [String: Readiness] {
        var result: [String: Readiness] = [:]
        for game in games where game.source == .local && game.consoleType == .snesUsa {
            if Task.isCancelled { break }
            let inspection = inspect(game)
            let row = Row(game: game, source: inspection.source, prepared: inspection.prepared,
                          issue: inspection.issue, matches: [], evidence: .distinct,
                          preparationError: inspection.preparationError)
            if row.readiness != .ready { result[game.id] = row.readiness }
        }
        return result
    }
    private static func inspect(_ game: Game) -> (source: SNESLibraryROMSource?, prepared: SNESCanoeImage.Result?, issue: String?, preparationError: SNESCanoeImage.PreparationError?) {
        do {
            let directory = URL(fileURLWithPath: game.romPath, isDirectory: true).standardizedFileURL
            guard directory.lastPathComponent == game.code else { throw RestoreDirectory.failure() }
            let parent = try RestoreDirectory(directory)
            let names = try parent.names().filter { ["sfc", "smc"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            guard names.count == 1, let name = names.first else { throw RestoreDirectory.failure() }
            let captured = try SNESLibraryROMSource.capture(directory: directory, filename: name)
            do { return (captured.0, try SNESCanoeImage.prepare(rom: captured.1), nil, nil) }
            catch let error as SNESCanoeImage.PreparationError { return (captured.0, nil, error.localizedDescription, error) }
        } catch {
            return (nil, nil, "The ROM file needs review. Keep one ordinary, uncompressed .sfc or .smc file and prepare again.", nil)
        }
    }
    @MainActor static func review(games: [Game], originals: SNESOriginalGamesFrame,
                                  stockPayloadSHA256: [String: String] = [:]) throws -> Self {
        let stock = Set(originals.entries.map(\.code))
        guard !stock.isEmpty, games.count <= 256, Set(games.map(\.code)).count == games.count,
              games.allSatisfy({ $0.source == .local && $0.consoleType == .snesUsa &&
                  $0.code.range(of: #"^CLV-U-[A-Z0-9]{5}$"#, options: .regularExpression) != nil }),
              stock.isDisjoint(with: Set(games.map(\.code))),
              Set(stockPayloadSHA256.keys).isSubset(of: stock),
              stockPayloadSHA256.values.allSatisfy(SNESDataSnapshotChunk.isDigest) else {
            throw failure("Choose a valid SNES library and verified built-in game information.")
        }
        var titles: [String: String] = [:]
        for entry in originals.entries {
            guard let desktop = entry.files.first(where: { $0.name == entry.code + ".desktop" }),
                  let title = try SNESOneGameMenu.fields(desktop.data)["name"], !title.isEmpty else {
                throw failure("The built-in game information is incomplete.")
            }
            titles[entry.code] = normalized(title)
        }
        var rows: [Row] = [], total = 0
        for game in games {
            try Task.checkCancellation()
            let inspection = inspect(game)
            let source = inspection.source, prepared = inspection.prepared, preparationError = inspection.preparationError
            var issue = inspection.issue
            total += prepared?.data.count ?? 0
            guard total <= 128 * 1024 * 1024 else { throw failure("Prepare a smaller game selection for this review.") }
            var matches: [String] = [], evidence: Evidence = .distinct
            do {
                if try !GameGenieVariantStore.isManagedCopy(game) {
                    if let prepared { matches = stockPayloadSHA256.filter { $0.value == prepared.sourcePayloadSHA256 }.map(\.key).sorted() }
                    if !matches.isEmpty { evidence = matches.count == 1 ? .exact : .possible }
                    else {
                        matches = titles.filter { $0.value == normalized(game.name) }.map(\.key).sorted()
                        if !matches.isEmpty { evidence = .possible }
                    }
                }
            } catch { issue = "This cheat copy's source information needs review. Reopen Cheat Codes before syncing." }
            rows.append(.init(game: game, source: source, prepared: prepared, issue: issue, matches: matches, evidence: evidence, preparationError: preparationError))
        }
        return .init(rows: rows, stockCodes: stock)
    }
    func resolvedCodes(selected: Set<String>, decisions: [String: Resolution]) throws -> Set<String> {
        let byCode = Dictionary(uniqueKeysWithValues: rows.map { ($0.game.code, $0) })
        guard selected.isSubset(of: Set(byCode.keys)), Set(decisions.keys).isSubset(of: selected),
              decisions.keys.allSatisfy({ !(byCode[$0]?.matches.isEmpty ?? true) }) else {
            throw Self.failure("The selection or duplicate choices changed. Prepare a new review.")
        }
        var result = stockCodes, replaced = Set<String>(), kept = Set<String>()
        for code in selected.sorted() {
            let row = byCode[code]!
            if row.needsDecision && decisions[code] == nil { throw Self.failure("Choose which version to keep for \(row.game.name).") }
            if !row.matches.isEmpty && decisions[code] != .keepImported { kept.formUnion(row.matches); continue }
            guard row.issue == nil, row.prepared != nil, row.source != nil else {
                throw Self.failure("\(row.game.name) needs compatibility review. Your library selection has been kept.")
            }
            if !row.matches.isEmpty {
                guard row.matches.count == 1, let original = row.matches.first, replaced.insert(original).inserted else {
                    throw Self.failure("Choose only one imported version for each built-in game.")
                }
                result.remove(original)
            }
            result.insert(code)
        }
        guard kept.isDisjoint(with: replaced) else { throw Self.failure("Some duplicate choices conflict. Keep one version of each game.") }
        return result
    }
    private static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

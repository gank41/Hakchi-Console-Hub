import Foundation
import SwiftHakchiCore
import Darwin

enum LegacySyncJournalError: Error, LocalizedError {
    case invalidRecord, unresolvedOperation, missingOperation, invalidTransition

    var errorDescription: String? {
        switch self {
        case .invalidRecord: return "The legacy sync journal is invalid. Review it before another console write."
        case .unresolvedOperation: return "A legacy sync operation still needs review or recovery."
        case .missingOperation: return "The legacy sync journal is missing."
        case .invalidTransition: return "This legacy sync phase cannot be repeated or skipped."
        }
    }
}

struct LegacySyncJournal: Codable, Sendable {
    enum Scope: Codable, Equatable, Sendable {
        case trial(code: String)
        case full
        case savedMenu
    }

    struct SavedMenuBinding: Codable, Sendable {
        let snapshotArchiveSHA256: String
        let chipIDFingerprint: String
        let previousOperationID: UUID
        let previousTreeSHA256: String
    }

    enum Phase: String, Codable, Sendable {
        case prepared, uploaded, verified, activationIntent, uncertain, activePendingAcceptance
        case accepted, discarded, rolledBack
    }

    let operationID: UUID
    let reviewSHA256: String
    let archiveSHA256: String
    let treeSHA256: String
    let backupSHA256: String
    let backupDirectory: URL
    let stageDirectory: URL
    let trialCode: String?
    let scope: Scope?
    let selectedCodes: [String]?
    let reviewedLocalCodes: [String]?
    let consoleOrder: ConsoleMenuOrder?
    let structure: ConsoleStructure?
    let savedMenuBinding: SavedMenuBinding?
    var chipIDFingerprint: String?
    let maximumGamesPerPage: Int
    let archiveBytes: Int64
    let createdAt: Date
    var phase: Phase

    var resolvedScope: Scope { scope ?? .trial(code: trialCode ?? "") }
    /// Older saved-menu journals already carried the device in their binding.
    var effectiveChipIDFingerprint: String? {
        if let chipIDFingerprint { return chipIDFingerprint }
        if case .savedMenu = resolvedScope { return savedMenuBinding?.chipIDFingerprint }
        return nil
    }
    var resolvedStructure: ConsoleStructure {
        structure ?? ConsoleStructure(maximumGamesPerPage:
            ConsoleMenuLimit(rawValue: maximumGamesPerPage) ?? .thirty)
    }

    func identityReviewDigest() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return BackupManifest.digest(try encoder.encode(self))
    }

    init(operationID: UUID, reviewSHA256: String, archiveSHA256: String, treeSHA256: String,
         backupSHA256: String, backupDirectory: URL, stageDirectory: URL,
         trialCode: String, maximumGamesPerPage: Int, archiveBytes: Int64,
         chipIDFingerprint: String? = nil) throws {
        self.operationID = operationID
        self.reviewSHA256 = reviewSHA256
        self.archiveSHA256 = archiveSHA256
        self.treeSHA256 = treeSHA256
        self.backupSHA256 = backupSHA256
        self.backupDirectory = backupDirectory.standardizedFileURL
        self.stageDirectory = stageDirectory.standardizedFileURL
        self.trialCode = trialCode
        self.scope = nil
        self.selectedCodes = nil
        self.reviewedLocalCodes = nil
        self.consoleOrder = nil
        self.structure = nil
        self.savedMenuBinding = nil
        self.chipIDFingerprint = chipIDFingerprint
        self.maximumGamesPerPage = maximumGamesPerPage
        self.archiveBytes = archiveBytes
        self.createdAt = Date()
        self.phase = .prepared
        try validate()
    }

    init(operationID: UUID, reviewSHA256: String, archiveSHA256: String, treeSHA256: String,
         backupSHA256: String, backupDirectory: URL, stageDirectory: URL,
         scope: Scope, selectedCodes: [String], reviewedLocalCodes: [String] = [],
         consoleOrder: ConsoleMenuOrder,
         maximumGamesPerPage: Int, archiveBytes: Int64,
         structure: ConsoleStructure? = nil, chipIDFingerprint: String? = nil) throws {
        self.operationID = operationID
        self.reviewSHA256 = reviewSHA256
        self.archiveSHA256 = archiveSHA256
        self.treeSHA256 = treeSHA256
        self.backupSHA256 = backupSHA256
        self.backupDirectory = backupDirectory.standardizedFileURL
        self.stageDirectory = stageDirectory.standardizedFileURL
        self.trialCode = {
            if case .trial(let code) = scope { return code }
            return nil
        }()
        self.scope = scope
        self.selectedCodes = selectedCodes
        self.reviewedLocalCodes = reviewedLocalCodes
        self.consoleOrder = consoleOrder
        self.structure = structure
        self.savedMenuBinding = nil
        self.chipIDFingerprint = chipIDFingerprint
        self.maximumGamesPerPage = maximumGamesPerPage
        self.archiveBytes = archiveBytes
        self.createdAt = Date()
        self.phase = .prepared
        try validate()
    }

    init(operationID: UUID, snapshot: LegacyMenuSnapshot.Verified,
         backupDirectory: URL, stage: LegacyMenuStageManifest,
         previous: LegacySyncJournal) throws {
        self.operationID = operationID
        reviewSHA256 = stage.reviewSHA256
        archiveSHA256 = stage.archiveSHA256
        treeSHA256 = stage.treeSHA256
        backupSHA256 = snapshot.manifest.archiveSHA256
        self.backupDirectory = backupDirectory.standardizedFileURL
        stageDirectory = stage.menuDirectory.deletingLastPathComponent().standardizedFileURL
        trialCode = nil
        scope = .savedMenu
        selectedCodes = LegacyMenuSnapshot.gameCodes(snapshot.entries).sorted()
        reviewedLocalCodes = nil
        consoleOrder = nil
        structure = nil
        chipIDFingerprint = snapshot.manifest.chipIDFingerprint
        savedMenuBinding = .init(snapshotArchiveSHA256: snapshot.manifest.archiveSHA256,
            chipIDFingerprint: snapshot.manifest.chipIDFingerprint,
            previousOperationID: previous.operationID, previousTreeSHA256: previous.treeSHA256)
        maximumGamesPerPage = 30
        archiveBytes = stage.archiveBytes
        createdAt = Date()
        phase = .prepared
        try validate()
    }

    func validate() throws {
        let hashes = [reviewSHA256, archiveSHA256, treeSHA256, backupSHA256]
        guard chipIDFingerprint.map({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) ?? true else {
            throw LegacySyncJournalError.invalidRecord
        }
        guard hashes.allSatisfy({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }),
              archiveBytes > 0, archiveBytes <= 256 * 1024 * 1024,
              backupDirectory.isFileURL, backupDirectory.path.hasPrefix("/"),
              backupDirectory.standardizedFileURL == backupDirectory,
              stageDirectory.isFileURL, stageDirectory.path.hasPrefix("/"),
              stageDirectory.standardizedFileURL == stageDirectory,
              ConsoleMenuLimit(rawValue: maximumGamesPerPage) != nil,
              createdAt.timeIntervalSince1970.isFinite else {
            throw LegacySyncJournalError.invalidRecord
        }
        guard resolvedStructure.maximumGamesPerPage.rawValue == maximumGamesPerPage else {
            throw LegacySyncJournalError.invalidRecord
        }
        try resolvedStructure.validate()
        switch resolvedScope {
        case .trial(let code):
            guard LegacyChangeScripts.validCode(code), trialCode == code,
                  selectedCodes == nil || selectedCodes == [code],
                  reviewedLocalCodes == nil || reviewedLocalCodes == [] else {
                throw LegacySyncJournalError.invalidRecord
            }
        case .full:
            guard trialCode == nil, let selectedCodes, !selectedCodes.isEmpty,
                  selectedCodes.allSatisfy({ ($0.hasPrefix("CLV-H-") || $0.hasPrefix("CLV-P-"))
                      && SyncPlanner.validCode($0) }),
                  selectedCodes == Array(Set(selectedCodes)).sorted(),
                  let consoleOrder, let reviewedLocalCodes,
                  reviewedLocalCodes == Array(Set(reviewedLocalCodes)).sorted(),
                  reviewedLocalCodes.allSatisfy({ $0.hasPrefix("CLV-H-") && SyncPlanner.validCode($0) })
                  else { throw LegacySyncJournalError.invalidRecord }
            if case .manual(let manualCodes) = consoleOrder {
                guard manualCodes.count == selectedCodes.count,
                      Set(manualCodes) == Set(selectedCodes) else {
                    throw LegacySyncJournalError.invalidRecord
                }
            }
        case .savedMenu:
            guard trialCode == nil, let selectedCodes, !selectedCodes.isEmpty,
                  selectedCodes == Array(Set(selectedCodes)).sorted(),
                  selectedCodes.allSatisfy({ ($0.hasPrefix("CLV-H-") || $0.hasPrefix("CLV-P-"))
                      && SyncPlanner.validCode($0) }),
                  reviewedLocalCodes == nil, consoleOrder == nil,
                  let savedMenuBinding,
                  (chipIDFingerprint == nil || chipIDFingerprint == savedMenuBinding.chipIDFingerprint),
                  savedMenuBinding.snapshotArchiveSHA256 == backupSHA256,
                  savedMenuBinding.snapshotArchiveSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  savedMenuBinding.chipIDFingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  savedMenuBinding.previousTreeSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  savedMenuBinding.previousOperationID != operationID else {
                throw LegacySyncJournalError.invalidRecord
            }
        }
    }

    func matches(_ plan: LegacySyncPlan) -> Bool {
        switch resolvedScope {
        case .trial(let code):
            return plan.trialCode == code && plan.consoleOrder == .title
                && resolvedStructure == plan.structure
        case .full:
            return plan.trialCode == nil && selectedCodes == plan.selectedGames.map { $0.game.code }.sorted()
                && consoleOrder == plan.consoleOrder && reviewedLocalCodes == plan.reviewedLocalCodes
                && resolvedStructure == plan.structure
        case .savedMenu:
            return false
        }
    }
}

/// Durable host-side gate. A corrupt or unresolved journal blocks every new sync operation.
actor LegacySyncJournalStore {
    // Shared by every store in this process. Other app processes must not be
    // used concurrently; the lock does not coordinate console operations.
    private static let mutationLock = NSLock()
    private let directory: URL
    private let synchronize: @Sendable (Int32) -> Int32
    init(directory: URL, synchronize: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }) {
        self.directory = directory.standardizedFileURL
        self.synchronize = synchronize
    }

    private nonisolated func file(for id: UUID) -> URL {
        directory.appendingPathComponent("nes-sync-" + id.uuidString + ".json")
    }

    private func journalFiles() throws -> [URL] {
        let fm = FileManager.default
        // Walk existing components without following links, rather than
        // resolving a URL for a path that may not exist yet. A genuinely
        // missing component means there are no journals at this path.
        guard try directoryExistsWithoutFollowingLinks() else { return [] }
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw LegacySyncJournalError.invalidRecord }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw LegacySyncJournalError.invalidRecord }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LegacySyncJournalError.invalidRecord }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LegacySyncJournalError.invalidRecord
        }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("nes-sync-") && $0.pathExtension == "json" }
    }

    private func directoryExistsWithoutFollowingLinks() throws -> Bool {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw LegacySyncJournalError.invalidRecord
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw LegacySyncJournalError.invalidRecord }
        defer { close(current) }
        for component in directory.pathComponents.dropFirst() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return false }
                throw LegacySyncJournalError.invalidRecord
            }
            close(current)
            current = next
        }
        return true
    }

    private func read(_ url: URL) throws -> LegacySyncJournal {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 16_384 else {
            throw LegacySyncJournalError.invalidRecord
        }
        let record = try JSONDecoder().decode(LegacySyncJournal.self, from: Data(contentsOf: url))
        try record.validate()
        guard url.standardizedFileURL.path == file(for: record.operationID).path else { throw LegacySyncJournalError.invalidRecord }
        return record
    }

    private nonisolated func withMutationDirectory<T>(create: Bool = false,
                                          _ body: (RestoreDirectory) throws -> T) throws -> T {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        if create {
            let components = directory.standardizedFileURL.pathComponents
            guard components.count > 2, components[0] == "/" else { throw LegacySyncJournalError.invalidRecord }
            // The top-level system directory is the established anchor. Sync
            // every parent below it even on retry after an interrupted mkdir.
            let ancestor = URL(fileURLWithPath: "/" + components[1], isDirectory: true)
            try RecoveryFirmwareJournalPolicy.createDirectoryWithoutFollowingSymlinks(
                at: directory, durableFrom: ancestor, synchronize: synchronize)
        }
        let root = try RestoreDirectory(directory)
        try root.check()
        let result = try body(root)
        try root.check()
        return result
    }

    private nonisolated func read(_ id: UUID, in root: RestoreDirectory) throws -> LegacySyncJournal {
        let name = file(for: id).lastPathComponent
        let record = try JSONDecoder().decode(LegacySyncJournal.self, from: root.read(name, maximum: 16_384))
        try record.validate()
        guard record.operationID == id else { throw LegacySyncJournalError.invalidRecord }
        return record
    }

    private nonisolated func unresolved(in root: RestoreDirectory) throws -> LegacySyncJournal? {
        let names = try root.names().filter { $0.hasPrefix("nes-sync-") && $0.hasSuffix(".json") }
        let records = try names.map { name -> LegacySyncJournal in
            guard let id = UUID(uuidString: String(name.dropFirst("nes-sync-".count).dropLast(".json".count))),
                  file(for: id).lastPathComponent == name else { throw LegacySyncJournalError.invalidRecord }
            return try read(id, in: root)
        }.filter { ![.accepted, .discarded, .rolledBack].contains($0.phase) }
        guard records.count <= 1 else { throw LegacySyncJournalError.unresolvedOperation }
        return records.first
    }

    private nonisolated func persist(_ record: LegacySyncJournal, in root: RestoreDirectory) throws {
        try record.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        let name = file(for: record.operationID).lastPathComponent
        let temp = ".nes-sync-" + UUID().uuidString + ".tmp"
        try root.check()
        let fd = openat(root.fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LegacySyncJournalError.invalidRecord }
        defer { _ = close(fd); _ = unlinkat(root.fd, temp, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard synchronize(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try root.check()
        guard renameat(root.fd, temp, root.fd, name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard synchronize(root.fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // A failure here can occur after the atomic replacement; callers must
        // reopen the journal before attempting a recovery action.
        try root.check()
    }

    func begin(_ record: LegacySyncJournal) throws {
        try record.validate()
        guard record.phase == .prepared else { throw LegacySyncJournalError.invalidRecord }
        try withMutationDirectory(create: true) { root in
            guard try unresolved(in: root) == nil else { throw LegacySyncJournalError.unresolvedOperation }
            var info = stat()
            let found = fstatat(root.fd, file(for: record.operationID).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW)
            guard found != 0 && errno == ENOENT else { throw LegacySyncJournalError.unresolvedOperation }
            try persist(record, in: root)
        }
    }

    func load(_ id: UUID) throws -> LegacySyncJournal {
        let url = file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LegacySyncJournalError.missingOperation }
        return try read(url)
    }

    func allRecords() throws -> [LegacySyncJournal] {
        try journalFiles().map(read)
    }

    /// This compare-and-bind follows the existing single-app-instance journal
    /// model. Other app processes are not serialized by this store.
    nonisolated func bindReviewedIdentity(_ id: UUID, fingerprint: String, expectedRecordDigest: String) throws {
        try Task.checkCancellation()
        try withMutationDirectory { root in
            guard fingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  var current = try unresolved(in: root), current.operationID == id,
                  current.effectiveChipIDFingerprint == nil,
                  try current.identityReviewDigest() == expectedRecordDigest else {
                throw LegacySyncJournalError.invalidRecord
            }
            current.chipIDFingerprint = fingerprint
            try persist(current, in: root)
        }
    }

    /// An accepted historical record is bound only after its independent
    /// former-menu review. No backup index is created or changed here.
    nonisolated func bindReviewedAcceptedIdentity(_ id: UUID, fingerprint: String, expectedRecordDigest: String) throws {
        try Task.checkCancellation()
        try withMutationDirectory { root in
            guard fingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  try unresolved(in: root) == nil else { throw LegacySyncJournalError.invalidRecord }
            var current = try read(id, in: root)
            guard current.phase == .accepted, current.resolvedScope != .savedMenu,
                  current.effectiveChipIDFingerprint == nil,
                  try current.identityReviewDigest() == expectedRecordDigest else {
                throw LegacySyncJournalError.invalidRecord
            }
            current.chipIDFingerprint = fingerprint
            try persist(current, in: root)
        }
    }

    func latestUnresolved() throws -> LegacySyncJournal? {
        let records = try journalFiles().map(read).filter {
            ![.accepted, .discarded, .rolledBack].contains($0.phase)
        }
        guard records.count <= 1 else { throw LegacySyncJournalError.unresolvedOperation }
        return records.first
    }

    func latestAcceptedFull() throws -> LegacySyncJournal? {
        try journalFiles().map(read)
            .filter { $0.phase == .accepted && $0.resolvedScope == .full }
            .max { $0.createdAt < $1.createdAt }
    }

    func latestAcceptedMenu() throws -> LegacySyncJournal? {
        try journalFiles().map(read)
            .filter { $0.phase == .accepted && ($0.resolvedScope == .full || $0.resolvedScope == .savedMenu) }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Accepted history is shared by the Mac library, so filter by the
    /// connected console before selecting the newest record. Unbound legacy
    /// records without a device binding are excluded.
    func latestAcceptedMenu(matchingChipID chipID: String) throws -> LegacySyncJournal? {
        try latestAccepted(matchingChipID: chipID, fullOnly: false)
    }

    func latestAcceptedFull(matchingChipID chipID: String) throws -> LegacySyncJournal? {
        try latestAccepted(matchingChipID: chipID, fullOnly: true)
    }

    /// When reopening a saved preview, only its recorded fingerprint is
    /// available. Unbound history is excluded until independently reviewed.
    func latestAcceptedFull(matchingFingerprint fingerprint: String?) throws -> LegacySyncJournal? {
        if let fingerprint, fingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) == nil {
            throw LegacySyncJournalError.invalidRecord
        }
        guard let fingerprint else { return nil }
        return try journalFiles().map(read)
            .filter { record in
                record.phase == .accepted && record.resolvedScope == .full &&
                record.effectiveChipIDFingerprint == fingerprint
            }
            .max { $0.createdAt < $1.createdAt }
    }

    private func latestAccepted(matchingChipID chipID: String, fullOnly: Bool) throws -> LegacySyncJournal? {
        guard chipID.contains(where: { $0 != "0" }),
              LegacyDeviceIdentity.matches(chipID, fingerprint: BackupManifest.digest(Data(chipID.utf8))) else {
            throw LegacyInspectionError.invalidResponse
        }
        return try journalFiles().map(read).filter { record in
            guard record.phase == .accepted,
                  record.resolvedScope == .full || (!fullOnly && record.resolvedScope == .savedMenu) else { return false }
            return (try? LegacyDeviceIdentity.requireOperationIdentity(chipID, fingerprint: record.effectiveChipIDFingerprint)) != nil
        }.max { $0.createdAt < $1.createdAt }
    }

    func advance(_ id: UUID, from expected: LegacySyncJournal.Phase,
                 to next: LegacySyncJournal.Phase) throws {
        try withMutationDirectory { root in
            try advance(id, from: expected, to: next, in: root)
        }
    }

    private func advance(_ id: UUID, from expected: LegacySyncJournal.Phase,
                         to next: LegacySyncJournal.Phase, in root: RestoreDirectory) throws {
        var record = try read(id, in: root)
        guard record.phase == expected,
              Self.transitions.contains(.init(from: expected, to: next)) else {
            throw LegacySyncJournalError.invalidTransition
        }
        record.phase = next
        try persist(record, in: root)
    }

    func markUncertain(_ id: UUID) throws {
        try withMutationDirectory { root in
            let current = try read(id, in: root).phase
            guard current == .activationIntent || current == .activePendingAcceptance else {
                throw LegacySyncJournalError.invalidTransition
            }
            try advance(id, from: current, to: .uncertain, in: root)
        }
    }

    private struct Transition: Hashable {
        let from: LegacySyncJournal.Phase
        let to: LegacySyncJournal.Phase
    }
    private static let transitions: Set<Transition> = [
        .init(from: .prepared, to: .uploaded),
        .init(from: .uploaded, to: .verified),
        .init(from: .verified, to: .activationIntent),
        .init(from: .activationIntent, to: .activePendingAcceptance),
        .init(from: .activationIntent, to: .uncertain),
        .init(from: .activePendingAcceptance, to: .uncertain),
        .init(from: .activePendingAcceptance, to: .accepted),
        .init(from: .prepared, to: .discarded),
        .init(from: .uploaded, to: .discarded),
        .init(from: .verified, to: .discarded),
        .init(from: .activationIntent, to: .discarded),
        .init(from: .uncertain, to: .discarded),
        .init(from: .activationIntent, to: .rolledBack),
        .init(from: .uncertain, to: .rolledBack),
        .init(from: .activePendingAcceptance, to: .rolledBack),
        .init(from: .uncertain, to: .activePendingAcceptance),
        .init(from: .uncertain, to: .accepted)
    ]
}

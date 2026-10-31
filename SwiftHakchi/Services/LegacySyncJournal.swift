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
    let maximumGamesPerPage: Int
    let archiveBytes: Int64
    let createdAt: Date
    var phase: Phase

    var resolvedScope: Scope { scope ?? .trial(code: trialCode ?? "") }
    var resolvedStructure: ConsoleStructure {
        structure ?? ConsoleStructure(maximumGamesPerPage:
            ConsoleMenuLimit(rawValue: maximumGamesPerPage) ?? .thirty)
    }

    init(operationID: UUID, reviewSHA256: String, archiveSHA256: String, treeSHA256: String,
         backupSHA256: String, backupDirectory: URL, stageDirectory: URL,
         trialCode: String, maximumGamesPerPage: Int, archiveBytes: Int64) throws {
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
         structure: ConsoleStructure? = nil) throws {
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
    private let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent("nes-sync-" + id.uuidString + ".json")
    }

    private func journalFiles() throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LegacySyncJournalError.invalidRecord
        }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("nes-sync-") && $0.pathExtension == "json" }
    }

    private func read(_ url: URL) throws -> LegacySyncJournal {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 16_384 else {
            throw LegacySyncJournalError.invalidRecord
        }
        let record = try JSONDecoder().decode(LegacySyncJournal.self, from: Data(contentsOf: url))
        try record.validate()
        guard url == file(for: record.operationID) else { throw LegacySyncJournalError.invalidRecord }
        return record
    }

    private func persist(_ record: LegacySyncJournal) throws {
        try record.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = file(for: record.operationID)
        try encoder.encode(record).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        // The activation intent must survive a crash even if this was the first
        // journal file or an atomic replacement of an earlier phase.
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func begin(_ record: LegacySyncJournal) throws {
        try record.validate()
        guard record.phase == .prepared else { throw LegacySyncJournalError.invalidRecord }
        guard try latestUnresolved() == nil else { throw LegacySyncJournalError.unresolvedOperation }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: file(for: record.operationID).path) else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        try persist(record)
    }

    func load(_ id: UUID) throws -> LegacySyncJournal {
        let url = file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LegacySyncJournalError.missingOperation }
        return try read(url)
    }

    func allRecords() throws -> [LegacySyncJournal] {
        try journalFiles().map(read)
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

    func advance(_ id: UUID, from expected: LegacySyncJournal.Phase,
                 to next: LegacySyncJournal.Phase) throws {
        var record = try load(id)
        guard record.phase == expected,
              Self.transitions.contains(.init(from: expected, to: next)) else {
            throw LegacySyncJournalError.invalidTransition
        }
        record.phase = next
        try persist(record)
    }

    func markUncertain(_ id: UUID) throws {
        let current = try load(id).phase
        guard current == .activationIntent || current == .activePendingAcceptance else {
            throw LegacySyncJournalError.invalidTransition
        }
        try advance(id, from: current, to: .uncertain)
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

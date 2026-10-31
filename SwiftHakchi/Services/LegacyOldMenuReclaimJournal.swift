import Foundation
import Darwin

struct LegacyOldMenuReclaimJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared, removalIntent, uncertain, completed, abandoned
    }
    let operationID: UUID
    let currentTreeSHA256: String
    let previousTreeSHA256: String
    let previousSnapshotSHA256: String
    let chipIDFingerprint: String
    let createdAt: Date
    var phase: Phase
    var testedMenus: Bool? = nil
}

actor LegacyOldMenuReclaimJournalStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent("nes-oldmenu-reclaim-" + id.uuidString + ".json")
    }

    func load(_ id: UUID) throws -> LegacyOldMenuReclaimJournal {
        let url = file(for: id)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 4096 else {
            throw LegacySyncJournalError.invalidRecord
        }
        let record = try JSONDecoder().decode(LegacyOldMenuReclaimJournal.self,
                                              from: Data(contentsOf: url))
        let hashes = [record.currentTreeSHA256, record.previousTreeSHA256,
                      record.previousSnapshotSHA256, record.chipIDFingerprint]
        guard record.operationID == id, hashes.allSatisfy({
            $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        }), record.createdAt.timeIntervalSince1970.isFinite else {
            throw LegacySyncJournalError.invalidRecord
        }
        return record
    }

    func begin(_ record: LegacyOldMenuReclaimJournal) throws {
        guard record.phase == .prepared,
              try latestUnresolved() == nil else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LegacySyncJournalError.invalidRecord
        }
        if FileManager.default.fileExists(atPath: file(for: record.operationID).path) {
            let previous = try load(record.operationID)
            guard previous.phase == .abandoned,
                  previous.currentTreeSHA256 == record.currentTreeSHA256,
                  previous.previousTreeSHA256 == record.previousTreeSHA256,
                  previous.previousSnapshotSHA256 == record.previousSnapshotSHA256,
                  previous.chipIDFingerprint == record.chipIDFingerprint else {
                throw LegacySyncJournalError.unresolvedOperation
            }
        }
        try persist(record)
    }

    func advance(_ id: UUID, from expected: LegacyOldMenuReclaimJournal.Phase,
                 to next: LegacyOldMenuReclaimJournal.Phase) throws {
        var record = try load(id)
        let allowed: Bool
        switch (expected, next) {
        case (.prepared, .removalIntent), (.prepared, .abandoned),
             (.removalIntent, .prepared),
             (.removalIntent, .uncertain),
             (.removalIntent, .completed), (.uncertain, .prepared),
             (.uncertain, .completed): allowed = true
        default: allowed = false
        }
        guard record.phase == expected, allowed else {
            throw LegacySyncJournalError.invalidTransition
        }
        record.phase = next
        try persist(record)
    }

    func latestUnresolved() throws -> LegacyOldMenuReclaimJournal? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("nes-oldmenu-reclaim-") && $0.pathExtension == "json" }
        let pending = try files.map { url -> LegacyOldMenuReclaimJournal in
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: String(stem.dropFirst("nes-oldmenu-reclaim-".count))),
                  url.lastPathComponent == file(for: id).lastPathComponent,
                  url.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == directory.resolvingSymlinksInPath().path else {
                throw LegacySyncJournalError.invalidRecord
            }
            return try load(id)
        }.filter { $0.phase != .completed && $0.phase != .abandoned }
        guard pending.count <= 1 else { throw LegacySyncJournalError.unresolvedOperation }
        return pending.first
    }

    private func persist(_ record: LegacyOldMenuReclaimJournal) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = file(for: record.operationID)
        try encoder.encode(record).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

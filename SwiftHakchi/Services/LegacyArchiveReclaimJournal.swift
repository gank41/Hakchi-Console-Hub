import Foundation
import Darwin

struct LegacyArchiveReclaimJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared, removalIntent, uncertain, completed, abandoned
    }

    let operationID: UUID
    let archiveSHA256: String
    let treeSHA256: String
    let archiveBytes: Int64
    let createdAt: Date
    var phase: Phase
}

actor LegacyArchiveReclaimJournalStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent("nes-reclaim-" + id.uuidString + ".json")
    }

    func load(_ id: UUID) throws -> LegacyArchiveReclaimJournal {
        let url = file(for: id)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 4096 else {
            throw LegacySyncJournalError.invalidRecord
        }
        let record = try JSONDecoder().decode(LegacyArchiveReclaimJournal.self,
                                              from: Data(contentsOf: url))
        guard record.operationID == id,
              record.archiveSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              record.treeSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              record.archiveBytes > 0, record.archiveBytes <= 256 * 1024 * 1024 else {
            throw LegacySyncJournalError.invalidRecord
        }
        return record
    }

    func begin(_ record: LegacyArchiveReclaimJournal) throws {
        guard record.phase == .prepared else { throw LegacySyncJournalError.invalidTransition }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LegacySyncJournalError.invalidRecord
        }
        if FileManager.default.fileExists(atPath: file(for: record.operationID).path) {
            let previous = try load(record.operationID)
            guard previous.phase == .abandoned,
                  previous.archiveSHA256 == record.archiveSHA256,
                  previous.treeSHA256 == record.treeSHA256,
                  previous.archiveBytes == record.archiveBytes else {
                throw LegacySyncJournalError.unresolvedOperation
            }
        }
        try persist(record)
    }

    func advance(_ id: UUID, from expected: LegacyArchiveReclaimJournal.Phase,
                 to next: LegacyArchiveReclaimJournal.Phase) throws {
        var record = try load(id)
        let allowed: Bool
        switch (expected, next) {
        case (.prepared, .removalIntent), (.prepared, .abandoned),
             (.removalIntent, .uncertain), (.removalIntent, .prepared),
             (.removalIntent, .completed), (.uncertain, .completed),
             (.uncertain, .prepared): allowed = true
        default: allowed = false
        }
        guard record.phase == expected, allowed else {
            throw LegacySyncJournalError.invalidTransition
        }
        record.phase = next
        try persist(record)
    }

    func latestUnresolved() throws -> LegacyArchiveReclaimJournal? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LegacySyncJournalError.invalidRecord
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("nes-reclaim-") && $0.pathExtension == "json" }
        let records = try files.map { file -> LegacyArchiveReclaimJournal in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "nes-reclaim-", with: "")),
                file.lastPathComponent == self.file(for: id).lastPathComponent,
                file.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == directory.resolvingSymlinksInPath().path else {
                throw LegacySyncJournalError.invalidRecord
            }
            return try load(id)
        }.filter { $0.phase != .completed && $0.phase != .abandoned }
        guard records.count <= 1 else { throw LegacySyncJournalError.unresolvedOperation }
        return records.first
    }

    private func persist(_ record: LegacyArchiveReclaimJournal) throws {
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

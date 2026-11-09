import Foundation
import SWCompression
import SwiftHakchiCore
import Darwin

/// A Mac-backed cleanup of terminal operations, including history older than the
/// latest accepted menu. The active menu and factory partition are never targets.
enum LegacyHistoricalCleanup {
    enum Failure: Error { case noOldFiles }
    struct Target: Codable, Identifiable, Sendable {
        let path: String
        let operationID: UUID
        var id: String { path }
        init(path: String) throws {
            let prefixes = ["/var/lib/hakchi/games/nes.swift-old-", "/var/lib/hakchi/games/nes.swift-failed-",
                            "/var/lib/hakchi/games/nes.swift-stage-", "/var/lib/hakchi/.swift-hakchi-sync-"]
            guard let prefix = prefixes.first(where: { path.hasPrefix($0) }),
                  let id = UUID(uuidString: String(path.dropFirst(prefix.count))),
                  path == prefix + id.uuidString else { throw LegacySyncJournalError.invalidRecord }
            self.path = path; operationID = id
        }
    }
    struct Item: Codable, Sendable {
        let target: Target
        let treeSHA256: String
        let allocatedBytes: Int64
    }
    struct Record: Codable, Sendable {
        enum Phase: String, Codable, Sendable { case prepared, removalIntent, uncertain, completed }
        let id: UUID
        let operationID: UUID
        let backupDirectory: URL
        let backupSHA256: String
        let chipIDFingerprint: String
        let liveTreeSHA256: String
        var items: [Item]
        var removedPaths: Set<String>
        var phase: Phase
        var bytesToReclaim: Int64 { items.reduce(0) { $0 + $1.allocatedBytes } }
    }
    struct FormerMenuProof: Codable, Sendable {
        let operationID: UUID
        let chipIDFingerprint: String
        let currentTreeSHA256: String
        let formerTreeSHA256: String
    }
    static func preserveFormerMenuProof(_ record: Record, workspace: WorkspacePaths) throws {
        let path = LegacySyncCommands.oldPath(for: record.operationID)
        guard record.removedPaths.contains(path), let item = record.items.first(where: { $0.target.path == path }) else { return }
        let proof = FormerMenuProof(operationID: record.operationID, chipIDFingerprint: record.chipIDFingerprint,
            currentTreeSHA256: record.liveTreeSHA256, formerTreeSHA256: item.treeSHA256)
        let file = workspace.journals.appendingPathComponent("nes-former-menu-proof-" + record.operationID.uuidString + ".json")
        try JSONEncoder().encode(proof).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(workspace.journals.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }; defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
    static func formerMenuProof(operationID: UUID, workspace: WorkspacePaths) throws -> FormerMenuProof? {
        let file = workspace.journals.appendingPathComponent("nes-former-menu-proof-" + operationID.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 4096 else { throw LegacySyncJournalError.invalidRecord }
        let proof = try JSONDecoder().decode(FormerMenuProof.self, from: Data(contentsOf: file))
        guard proof.operationID == operationID,
              [proof.chipIDFingerprint, proof.currentTreeSHA256, proof.formerTreeSHA256].allSatisfy({
                $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
              }) else { throw LegacySyncJournalError.invalidRecord }
        return proof
    }

    static func archiveEntries(_ archive: Data, target: Target) throws -> [LegacyMenuStageManifest.Entry] {
        let root = String(target.path.dropFirst()), prefix = root + "/"
        var entries: [LegacyMenuStageManifest.Entry] = [], seen = Set<String>(), rootFound = false
        for entry in try TarContainer.open(container: archive) {
            let name = entry.info.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if name == root {
                guard entry.info.type == .directory, !rootFound else { throw LegacyInspectionError.invalidBackup }
                rootFound = true; continue
            }
            guard name.hasPrefix(prefix) else { continue }
            let relative = String(name.dropFirst(prefix.count))
            guard !entry.info.name.hasPrefix("/"), !relative.isEmpty, relative.utf8.count <= 512,
                  !relative.contains(".."), !relative.contains("\\"),
                  !relative.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(relative).inserted else { throw LegacyInspectionError.invalidBackup }
            let kind: LegacyMenuStageManifest.Kind
            var bytes: Int64 = 0, hash: String?, link: String?
            switch entry.info.type {
            case .directory: kind = .directory
            case .regular:
                guard let data = entry.data else { throw LegacyInspectionError.invalidBackup }
                kind = .regular; bytes = Int64(data.count); hash = BackupManifest.digest(data)
            case .symbolicLink:
                kind = .symbolicLink; link = entry.info.linkName
                guard let link, !link.isEmpty,
                      !link.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw LegacyInspectionError.invalidBackup
                }
            default: throw LegacyInspectionError.invalidBackup
            }
            entries.append(.init(relativePath: relative, kind: kind, byteCount: bytes, sha256: hash, linkTarget: link))
            guard entries.count <= LegacyStageVerification.maximumEntries else { throw LegacyInspectionError.outputLimit }
        }
        guard rootFound else { throw LegacyInspectionError.invalidBackup }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    /// Reconciliation can freeze a smaller remainder only when every surviving
    /// entry still exactly matches the Mac archive. A new reviewed action removes it.
    static func remainingTreeDigest(_ inventory: Data, operationID: UUID,
                                    original: [LegacyMenuStageManifest.Entry]) throws -> String {
        let differences = try LegacyStageVerification.compareInventory(inventory,
            operationID: operationID, expected: original)
        guard differences.allSatisfy({ $0.hasSuffix(": missing on NES") }) else {
            throw LegacyInspectionError.invalidBackup
        }
        let lines = String(decoding: inventory, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .dropFirst().dropLast(2).sorted()
        let description = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return BackupManifest.digest(Data(description.utf8))
    }

    static func recordURL(_ workspace: WorkspacePaths) -> URL {
        workspace.journals.appendingPathComponent("nes-historical-cleanup.json")
    }
    static func load(workspace: WorkspacePaths) throws -> Record? {
        let file = recordURL(workspace)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 131072 else { throw LegacySyncJournalError.invalidRecord }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard workspace.containsBackup(record.backupDirectory), record.items.count <= 64,
              Set(record.items.map { $0.target.path }).count == record.items.count,
              record.removedPaths.isSubset(of: Set(record.items.map { $0.target.path })),
              ([record.backupSHA256, record.chipIDFingerprint, record.liveTreeSHA256] + record.items.map(\.treeSHA256))
                .allSatisfy({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) else {
            throw LegacySyncJournalError.invalidRecord
        }
        for item in record.items {
            guard try Target(path: item.target.path).operationID == item.target.operationID,
                  item.target.path != LegacyStageTransfer.directory(for: record.operationID),
                  item.allocatedBytes >= 0, item.allocatedBytes <= 512 * 1024 * 1024 else {
                throw LegacySyncJournalError.invalidRecord
            }
        }
        return record
    }
    static func persist(_ record: Record, workspace: WorkspacePaths) throws {
        try FileManager.default.createDirectory(at: workspace.journals, withIntermediateDirectories: true)
        let folder = try workspace.journals.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folder.isDirectory == true, folder.isSymbolicLink != true else { throw LegacySyncJournalError.invalidRecord }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = recordURL(workspace)
        try encoder.encode(record).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(workspace.journals.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }; defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}

actor LegacyHistoricalCleanupService {
    private let workspace: WorkspacePaths
    init(workspace: WorkspacePaths) { self.workspace = workspace }

    func prepare(lease: LegacySessionLease, progress: @Sendable (String) -> Void) async throws -> LegacyHistoricalCleanup.Record {
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        let store = LegacySyncJournalStore(directory: workspace.journals)
        let chip = try await LegacyDeviceIdentity.read(client: lease)
        guard try await store.latestUnresolved() == nil, let accepted = try await store.latestAcceptedMenu(matchingChipID: chip),
              try LegacyGameChangeService.latest(workspace: workspace) == nil else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        try LegacyDeviceIdentity.requireOperationIdentity(chip, fingerprint: accepted.effectiveChipIDFingerprint)
        let report = try await LegacyConsoleService.inspect(client: lease)
        try LegacyGameChangeService.validateReport(report)
        try await requireAcceptedOperation(accepted, report: report, lease: lease)
        if let previous = try LegacyHistoricalCleanup.load(workspace: workspace) {
            try LegacyHistoricalCleanup.preserveFormerMenuProof(previous, workspace: workspace)
        }
        let storageResult = try await lease.execute(.storageReport, timeoutMilliseconds: 30000)
        guard storageResult.succeeded else { throw LegacyInspectionError.invalidResponse }
        let storage = try LegacyStorageReport.parse(storageResult.stdoutData)
        var candidates: [(LegacyHistoricalCleanup.Target, Int64)] = []
        for entry in storage.entries {
            guard let target = try? LegacyHistoricalCleanup.Target(path: entry.path),
                  let owner = try? await store.load(target.operationID),
                  [.accepted, .rolledBack, .discarded].contains(owner.phase),
                  (try? LegacyDeviceIdentity.requireOperationIdentity(chip, fingerprint: owner.effectiveChipIDFingerprint)) != nil else { continue }
            // The latest operation's small metadata folder is still needed for recovery/history.
            if target.path == LegacyStageTransfer.directory(for: accepted.operationID) { continue }
            candidates.append((target, entry.bytes))
        }
        guard !candidates.isEmpty else { throw LegacyHistoricalCleanup.Failure.noOldFiles }
        candidates.sort { ($0.1, $0.0.path) < ($1.1, $1.0.path) }
        progress("Saving and verifying old files on this Mac…")
        try workspace.requireActiveBackupsAvailable()
        let matching = try await LegacyCurrentBackup.find(report: report,
            device: LegacySyncLeaseDevice(lease: lease), workspace: workspace)
        var reusable: URL?
        if let matching {
            let data = try Data(contentsOf: matching.directory.appendingPathComponent("console.tar"), options: .mappedIfSafe)
            let roots = Set(try TarContainer.open(container: data).filter { $0.info.type == .directory }
                .map { $0.info.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
            if candidates.allSatisfy({ roots.contains(String($0.0.path.dropFirst())) }) { reusable = matching.directory }
        }
        let backup: URL
        if let reusable {
            progress("Reusing the verified Mac backup of these old files…")
            backup = reusable
        } else {
            backup = try await LegacyConsoleService.backup(client: lease, report: report,
                destination: workspace.backups) { message, _ in progress(message) }
        }
        let snapshot = try LegacyMenuSnapshot.verify(directory: backup, expectedChipID: chip)
        let archive = try Data(contentsOf: backup.appendingPathComponent("console.tar"), options: .mappedIfSafe)
        var items: [LegacyHistoricalCleanup.Item] = []
        for (target, bytes) in candidates {
            progress("Checking old files \(items.count + 1) of \(candidates.count)…")
            let entries = try LegacyHistoricalCleanup.archiveEntries(archive, target: target)
            let result = try await lease.perform(.inventoryHistorical(target))
            guard result.succeeded, result.stderr.isEmpty,
                  try LegacyStageVerification.compareInventory(result.stdoutData,
                    operationID: target.operationID, expected: entries).isEmpty else {
                throw LegacyInspectionError.invalidBackup
            }
            let digest = entries.isEmpty ? BackupManifest.digest(Data()) : LegacyMenuSnapshot.treeDigest(entries)
            items.append(.init(target: target, treeSHA256: digest, allocatedBytes: bytes))
        }
        let current = try await lease.perform(.inventoryLive(accepted.operationID))
        guard current.succeeded,
              try LegacyStageVerification.compareInventory(current.stdoutData,
                operationID: accepted.operationID, expected: snapshot.entries).isEmpty else {
            throw LegacyInspectionError.invalidBackup
        }
        let record = LegacyHistoricalCleanup.Record(id: UUID(), operationID: accepted.operationID,
            backupDirectory: backup, backupSHA256: snapshot.manifest.archiveSHA256,
            chipIDFingerprint: snapshot.manifest.chipIDFingerprint, liveTreeSHA256: snapshot.menuTreeSHA256,
            items: items, removedPaths: [], phase: .prepared)
        try LegacyHistoricalCleanup.persist(record, workspace: workspace)
        return record
    }

    func remove(_ preview: LegacyHistoricalCleanup.Record, lease: LegacySessionLease,
                progress: @Sendable (String) -> Void) async throws {
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        guard var record = try LegacyHistoricalCleanup.load(workspace: workspace), record.id == preview.id,
              record.phase == .prepared else { throw LegacySyncJournalError.invalidTransition }
        try await requireCurrent(record, lease: lease)
        for item in record.items where !record.removedPaths.contains(item.target.path) {
            progress("Removing old files \(record.removedPaths.count + 1) of \(record.items.count)…")
            record.phase = .removalIntent
            try LegacyHistoricalCleanup.persist(record, workspace: workspace)
            do {
                let result = try await lease.perform(.removeHistorical(item.target, record.liveTreeSHA256, item.treeSHA256))
                guard result.succeeded, result.stderr.isEmpty,
                      result.stdoutData == Data(("REMOVED_OLD_FILES:" + item.target.path + "\n").utf8) else {
                    throw LegacyInspectionError.invalidResponse
                }
                record.removedPaths.insert(item.target.path)
                try LegacyHistoricalCleanup.preserveFormerMenuProof(record, workspace: workspace)
                record.phase = .prepared
                try LegacyHistoricalCleanup.persist(record, workspace: workspace)
            } catch {
                record.phase = .uncertain
                try? LegacyHistoricalCleanup.persist(record, workspace: workspace)
                throw error
            }
        }
        try await requireCurrent(record, lease: lease)
        record.phase = .completed
        try LegacyHistoricalCleanup.persist(record, workspace: workspace)
    }

    /// Reads only: a missing target is recorded, an intact one stays reviewable.
    /// A partially deleted tree is never passed to a second recursive deletion.
    func reconcile(lease: LegacySessionLease) async throws -> LegacyHistoricalCleanup.Record {
        guard var record = try LegacyHistoricalCleanup.load(workspace: workspace),
              record.phase == .uncertain || record.phase == .removalIntent else {
            throw LegacySyncJournalError.invalidTransition
        }
        try await requireCurrent(record, lease: lease)
        let result = try await lease.execute(.storageReport, timeoutMilliseconds: 30000)
        guard result.succeeded else { throw LegacyInspectionError.invalidResponse }
        let paths = Set(try LegacyStorageReport.parse(result.stdoutData).entries.map(\.path))
        let archive = try Data(contentsOf: record.backupDirectory.appendingPathComponent("console.tar"), options: .mappedIfSafe)
        for index in record.items.indices {
            let item = record.items[index]
            if record.removedPaths.contains(item.target.path) { continue }
            if !paths.contains(item.target.path) { record.removedPaths.insert(item.target.path); continue }
            let inventory = try await lease.perform(.inventoryHistorical(item.target))
            let entries = try LegacyHistoricalCleanup.archiveEntries(archive, target: item.target)
            guard inventory.succeeded else { throw LegacyInspectionError.invalidResponse }
            let digest = try LegacyHistoricalCleanup.remainingTreeDigest(inventory.stdoutData,
                operationID: item.target.operationID, original: entries)
            record.items[index] = .init(target: item.target, treeSHA256: digest, allocatedBytes: item.allocatedBytes)
        }
        record.phase = record.removedPaths.count == record.items.count ? .completed : .prepared
        try LegacyHistoricalCleanup.preserveFormerMenuProof(record, workspace: workspace)
        try LegacyHistoricalCleanup.persist(record, workspace: workspace)
        return record
    }

    private func requireCurrent(_ record: LegacyHistoricalCleanup.Record, lease: LegacySessionLease) async throws {
        let store = LegacySyncJournalStore(directory: workspace.journals)
        let chip = try await LegacyDeviceIdentity.read(client: lease)
        guard try await store.latestUnresolved() == nil,
              let accepted = try await store.latestAcceptedMenu(matchingChipID: chip), accepted.operationID == record.operationID else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        guard LegacyDeviceIdentity.matches(chip, fingerprint: record.chipIDFingerprint) else {
            throw LegacyInspectionError.invalidBackup
        }
        let snapshot = try LegacyMenuSnapshot.verify(directory: record.backupDirectory, expectedChipID: chip)
        guard snapshot.manifest.archiveSHA256 == record.backupSHA256,
              snapshot.menuTreeSHA256 == record.liveTreeSHA256 else { throw LegacyInspectionError.invalidBackup }
        let report = try await LegacyConsoleService.inspect(client: lease)
        try LegacyGameChangeService.validateReport(report)
        try await requireAcceptedOperation(accepted, report: report, lease: lease)
        let live = try await lease.perform(.inventoryLive(record.operationID))
        guard live.succeeded,
              try LegacyStageVerification.compareInventory(live.stdoutData,
                operationID: record.operationID, expected: snapshot.entries).isEmpty else {
            throw LegacyInspectionError.invalidBackup
        }
    }

    private func requireAcceptedOperation(_ accepted: LegacySyncJournal, report: LegacyConsoleReport,
                                          lease: LegacySessionLease) async throws {
        guard accepted.selectedCodes.map(Set.init) == report.visibleCodes else {
            throw LegacySyncJournalError.invalidRecord
        }
        let result = try await lease.perform(.inspectStage(accepted.operationID, accepted.treeSHA256))
        guard result.succeeded else { throw LegacyInspectionError.invalidResponse }
        let state = try LegacySyncCommands.parseInspection(result.stdoutData, operationID: accepted.operationID)
        guard state.phase == .accepted, state.transaction, state.live,
              !state.stage, !state.failed, !state.lock else { throw LegacySyncJournalError.invalidTransition }
    }
}

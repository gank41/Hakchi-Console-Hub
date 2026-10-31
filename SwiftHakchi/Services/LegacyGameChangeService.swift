import Foundation
import SwiftHakchiCore

/// Recognizes this recovered NES image by its bytes, never by a manifest claim alone.
/// Recognition is not unique hardware identity and never enables kernel restore.
enum LegacyRecoveryEvidence {
    static func find(in roots: [URL]) throws -> URL {
        for root in roots {
            guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  root.resolvingSymlinksInPath().path == root.path else { continue }
            if let evidence = try? find(in: root) { return evidence }
        }
        throw LegacyChangeError.refused("The verified original Windows NES kernel is missing or changed. Locate its RecoveryMaterial folder in one of the saved Mac backup folders.")
    }

    static func find(in backups: URL) throws -> URL {
        let fm = FileManager.default
        for directory in try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where directory.lastPathComponent.hasPrefix("RecoveryMaterial-") {
            let manifest = directory.appendingPathComponent("manifest.json")
            let image = directory.appendingPathComponent("kernel-stock-NES.img")
            guard let data = try? Data(contentsOf: manifest), data.count < 65536,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["archiveFilename"] as? String == "kernel-stock-NES.img",
                  object["sha256"] as? String == "83efe33290867ec6e6b5c5a18e21f8cfe6f97b079c2e3c5039c628e729755888",
                  let size = try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == 2826240,
                  let bytes = try? Data(contentsOf: image), bytes.prefix(8) == Data("ANDROID!".utf8),
                  BackupManifest.digest(bytes) == object["sha256"] as? String else { continue }
            return directory
        }
        throw LegacyChangeError.refused("The verified original Windows NES kernel is missing or changed. Keep the RecoveryMaterial folder in this workspace's Backups folder.")
    }
}

actor LegacyGameChangeService {
    private var prepared: (LegacyChangePlan, LegacySessionLease)?
    private var working = false

    static func validateReport(_ report: LegacyConsoleReport, against baseline: LegacyConsoleReport? = nil) throws {
        guard report.bootVersion == "1.0.1", report.kernelVersion == "3.4.112.madmonkey",
              report.scriptVersion == "[master]v1.0.3-110(7f31082)", report.activePage == LegacyConsoleReport.gameRoot + "/000",
              report.savesPath == "/var/lib/clover/profiles/0", report.stockCodes.count == 30,
              baseline.map({ $0.matchesLayout(of: report) }) ?? true else {
            throw LegacyChangeError.refused("This first write adapter supports only the verified legacy NES firmware at root menu 000. Return to the main menu before continuing.")
        }
    }
    static func verifyBackup(_ directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard data.count < 131072,
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expected = manifest["sha256"] as? String,
              expected.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              let count = manifest["byteCount"] as? Int, count >= 1024, count <= 512 * 1024 * 1024,
              let size = try directory.appendingPathComponent("console.tar").resourceValues(forKeys: [.fileSizeKey]).fileSize, size == count else {
            throw LegacyChangeError.refused("The verified console backup is missing or changed.")
        }
        guard BackupManifest.digest(try Data(contentsOf: directory.appendingPathComponent("console.tar"))) == expected else {
            throw LegacyChangeError.refused("The console backup hash no longer matches its verified manifest.")
        }
    }
    static func journalURL(id: UUID, workspace: WorkspacePaths) -> URL { workspace.journals.appendingPathComponent("legacy-" + id.uuidString + ".json") }
    static func save(_ record: LegacyChangeRecord, workspace: WorkspacePaths) throws {
        try FileManager.default.createDirectory(at: workspace.journals, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let file = journalURL(id: record.id, workspace: workspace)
        try encoder.encode(record).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
    }
    static func latest(workspace: WorkspacePaths) throws -> LegacyChangeRecord? {
        guard FileManager.default.fileExists(atPath: workspace.journals.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: workspace.journals, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("legacy-") && $0.pathExtension == "json" }
        var records: [LegacyChangeRecord] = []
        for file in files {
            let data = try Data(contentsOf: file)
            guard data.count < 131072 else { throw LegacyChangeError.refused("Oversized legacy journal requires review.") }
            let record = try decoder.decode(LegacyChangeRecord.self, from: data)
            _ = try record.plan.target.validated()
            guard file.lastPathComponent == "legacy-" + record.id.uuidString + ".json" else { throw LegacyChangeError.refused("Legacy journal identity mismatch.") }
            if record.phase == .pending || record.phase == .applied { records.append(record) }
        }
        guard records.count <= 1 else { throw LegacyChangeError.refused("Multiple unresolved legacy transactions need manual review.") }
        return records.first
    }
    func prepare(game: Game, client: LegacyInspectionClient, report: LegacyConsoleReport, workspace: WorkspacePaths,
                 progress: @Sendable (String) -> Void = { _ in }) async throws -> LegacyChangePlan {
        guard !working, prepared == nil else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        guard game.source == .console, !report.stockCodes.contains(game.code), LegacyChangeScripts.validCode(game.code) else { throw LegacyChangeError.refused("Select an existing custom NES game.") }
        guard try Self.latest(workspace: workspace) == nil else { throw LegacyChangeError.refused("Review and restore the previous legacy change before hiding another game.") }
        let recovery = try LegacyRecoveryEvidence.find(in: workspace.knownBackupRoots)
        try Self.validateReport(report)
        let lease = try await client.reserveForChange()
        do {
            let fresh = try await LegacyConsoleService.inspect(client: lease)
            try Self.validateReport(fresh, against: report)
            progress("Checking target and menu readiness…")
            let target = try await probe(code: game.code, lease: lease)
            guard fresh.freeBytes > target.bytes * 2 + 8 * 1024 * 1024 else { throw LegacyChangeError.refused("Insufficient preservation space on the console.") }
            progress("Exporting a fresh verified backup of games and saves…")
            try workspace.requireActiveBackupsAvailable()
            let backup = try await LegacyConsoleService.backup(client: lease, report: fresh, destination: workspace.backups)
            let after = try await probe(code: game.code, lease: lease)
            guard after == target else { throw LegacyChangeError.refused("Game changed while making the backup. Prepare a new preview.") }
            let plan = LegacyChangePlan(id: UUID(), name: game.name, target: target, report: fresh, backup: backup, recovery: recovery, createdAt: Date())
            try Task.checkCancellation()
            prepared = (plan, lease); return plan
        } catch { await lease.release(); throw error }
    }
    func cancel() async {
        guard !working else { return }
        let lease = prepared?.1; prepared = nil; await lease?.release()
    }
    func apply(id: UUID, mainMenuConfirmed: Bool, workspace: WorkspacePaths) async throws -> LegacyChangeRecord {
        guard !working, let (plan, lease) = prepared, plan.id == id else { throw LegacyChangeError.refused("Prepare a fresh preview after reconnecting.") }
        guard mainMenuConfirmed, Date().timeIntervalSince(plan.createdAt) >= 0, Date().timeIntervalSince(plan.createdAt) < 300 else { throw LegacyChangeError.refused("Confirm the main menu and prepare a new preview if this one has expired.") }
        working = true; prepared = nil
        defer { working = false }
        // Deliberately independent of the sheet's task cancellation once commit begins.
        // Explicit device disconnect still invalidates the lease and leaves the pending journal.
        let task = Task.detached {
            do {
                let fresh = try await LegacyConsoleService.inspect(client: lease)
                try Self.validateReport(fresh, against: plan.report)
                let check = try await Self.checked(.probe(plan.target.code), lease: lease)
                guard try LegacyChangeScripts.parseProbe(check.stdout, code: plan.target.code) == plan.target else { throw LegacyChangeError.refused("The game changed; prepare another preview.") }
                try Self.verifyBackup(plan.backup)
                _ = try LegacyRecoveryEvidence.find(in: workspace.knownBackupRoots)
                let record = try await Self.commit(plan: plan, lease: lease, workspace: workspace)
                await lease.release(); return record
            } catch { await lease.release(); throw error }
        }
        return try await task.value
    }
    func undo(record: LegacyChangeRecord, client: LegacyInspectionClient, mainMenuConfirmed: Bool, workspace: WorkspacePaths) async throws -> LegacyChangeRecord {
        guard !working, prepared == nil, mainMenuConfirmed else { throw LegacyChangeError.refused("Confirm the console is idle before recovery or Undo.") }
        guard let stored = try Self.latest(workspace: workspace), stored.id == record.id else { throw LegacyChangeError.refused("The saved transaction changed. Review it again.") }
        _ = try stored.plan.target.validated()
        working = true; defer { working = false }
        let lease = try await client.reserveForChange()
        let task = Task.detached {
            do {
                let fresh = try await LegacyConsoleService.inspect(client: lease)
                try Self.validateReport(fresh, against: stored.plan.report)
                let result = try await Self.checked(.undo(stored.id, stored.plan.target), lease: lease)
                guard result.stdout == "RESTORED\n" else { throw LegacyChangeError.refused("Recovery result is uncertain; keep the journal and backups.") }
                let restored = LegacyChangeRecord(plan: stored.plan, phase: .restored)
                try Self.save(restored, workspace: workspace); await lease.release(); return restored
            } catch { await lease.release(); throw error }
        }
        return try await task.value
    }
    static func commit(plan: LegacyChangePlan, lease: LegacySessionLease, workspace: WorkspacePaths) async throws -> LegacyChangeRecord {
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        guard try latest(workspace: workspace) == nil else { throw LegacyChangeError.refused("Another legacy journal needs review.") }
        try save(LegacyChangeRecord(plan: plan, phase: .pending), workspace: workspace)
        let result = try await lease.perform(.hide(plan.id, plan.target))
        if !result.succeeded, result.stdout == "REFUSED_BEFORE_MUTATION\n" {
            try save(LegacyChangeRecord(plan: plan, phase: .unchanged), workspace: workspace)
            throw LegacyChangeError.refused(result.stderr.isEmpty ? "No change was started. Prepare a fresh preview." : result.stderr)
        }
        guard result.succeeded, result.stdout == "APPLIED\n" else { throw LegacyChangeError.refused("Uncertain result. Review the pending journal before another operation.") }
        let record = LegacyChangeRecord(plan: plan, phase: .applied)
        try save(record, workspace: workspace); return record
    }
    private func probe(code: String, lease: LegacySessionLease) async throws -> LegacyGameTarget {
        let result = try await Self.checked(.probe(code), lease: lease)
        return try LegacyChangeScripts.parseProbe(result.stdout, code: code)
    }
    private static func checked(_ request: LegacyChangeRequest, lease: LegacySessionLease) async throws -> SSHResult {
        let result = try await lease.perform(request)
        guard result.succeeded else { throw LegacyChangeError.refused(result.stderr.isEmpty ? "Console change was refused; review the saved transaction." : result.stderr) }
        return result
    }
}

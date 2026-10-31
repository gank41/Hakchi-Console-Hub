import Foundation
import Darwin
import SwiftHakchiCore

/// Signed developer-only observation. This command has no console mutation mode.
enum SNESLibraryInspectionDiagnostic {
    static func runIfPresent(_ arguments: [String],
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        inventory: @Sendable () async throws -> [RecoveryProbeUSBDevice] = { try RecoveryProbeUSBRegistry.inventory() },
        makeConnection: @Sendable (RecoveryProbeUSBDevice, WorkspacePaths) async throws -> NativeSNESLibraryIO.Connection = {
            try await NativeSNESLibraryIO.connect(attachment: $0, sessionID: UUID(), workspace: $1)
        }) async throws -> String? {
        guard let mode = arguments.first, ["--inspect-native-snes-library", "--backup-native-snes-library"].contains(mode) else { return nil }
        let backupRequested = mode == "--backup-native-snes-library"
        func path(_ value: String) -> Bool {
            value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 4096 && URL(fileURLWithPath: value).standardizedFileURL.path == value
        }
        guard arguments.count == 3, path(arguments[1]), path(arguments[2]) else { throw SNESLibraryInventory.failure() }
        let workspaceRoot = try RestoreDirectory(URL(fileURLWithPath: arguments[1]))
        let outputRoot = try RestoreDirectory(URL(fileURLWithPath: arguments[2]))
        let workspace = WorkspacePaths(root: workspaceRoot.url)
        if backupRequested { _ = try RestoreDirectory(workspace.backups) }
        try Task.checkCancellation(); try await checkHost()
        let devices = try await inventory()
        guard devices.count == 1, let device = devices.first, ConsoleAttachmentPolicy.kind(of: device) == .nativeSNES else { throw SNESLibraryInstallation.failure() }
        let connection = try await makeConnection(device, workspace)
        var observed: SNESLibraryObservation
        var savedBackup: SNESLibraryBackup?
        var restoredGameCount: Int?
        do {
            observed = try await connection.session.observe(connection.context)
            if backupRequested {
                FileHandle.standardError.write(Data("Saving the current custom games, settings and saves on this Mac…\n".utf8))
                savedBackup = try await connection.session.captureBackup(observed, root: workspace.backups)
                guard let savedBackup else { throw SNESLibraryInventory.failure() }
                let restore = try SNESLibraryRestore.prepare(backup: savedBackup, originals: connection.context.installation.originals.frame,
                    expectedHWID: connection.context.installation.expected.hwid)
                restoredGameCount = restore.menu?.graph.screens.flatMap(\.gameCodes).count ?? connection.context.installation.originals.frame.entries.count
                observed = try await connection.session.observe(connection.context)
                guard savedBackup.inventory.snapshotSHA256 == observed.inventory.snapshotSHA256,
                      savedBackup.inventory.stateSHA256 == observed.inventory.stateSHA256 else { throw SNESLibraryInventory.failure() }
            }
            try await connection.session.requireCurrent(observed)
            await connection.session.disconnect()
        } catch { await connection.session.disconnect(); throw error }
        try Task.checkCancellation(); try workspaceRoot.check(); try outputRoot.check()
        let leaf = "SNES-Library-Inspection-" + UUID().uuidString
        guard mkdirat(outputRoot.fd, leaf, 0o700) == 0 else { throw RestoreDirectory.failure() }
        let directory = try RestoreDirectory(outputRoot.url.appendingPathComponent(leaf))
        func write(_ name: String, _ data: Data) throws {
            try directory.check()
            let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw RestoreDirectory.failure() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
        }
        try write("inventory.frame", observed.inventory.rawFrame)
        try write("space.frame", observed.rawSpace)
        for (index, raw) in observed.reports.enumerated() { try write("report-\(index).frame", raw) }
        var record: [String: Any] = ["version": 1, "scope": "read-only-native-snes-library", "complete": true,
            "contextSHA256": observed.context.sha256, "hwid": observed.inventory.hwid,
            "operation": observed.context.installation.accepted.material.id.uuidString,
            "reviewSHA256": observed.context.installation.accepted.reviewSHA256,
            "catalogDirectory": observed.context.installation.originals.directoryURL.path,
            "catalogSHA256": observed.inventory.catalogSHA256, "attachment": ["registryID": device.registryEntryID ?? 0, "locationID": device.locationID, "version": device.deviceVersion],
            "inventoryChallenge": observed.inventoryChallenge.uuidString, "spaceChallenge": observed.spaceChallenge.uuidString,
            "reportChallenges": observed.reportChallenges.map(\.uuidString),
            "inventorySHA256": BackupManifest.digest(observed.inventory.rawFrame), "spaceSHA256": BackupManifest.digest(observed.rawSpace),
            "reportSHA256": observed.reports.map(BackupManifest.digest),
            "snapshotSHA256": observed.inventory.snapshotSHA256, "stateSHA256": observed.inventory.stateSHA256,
            "freeBytes": observed.capacity.freeBytes, "totalBytes": observed.inventory.totalBytes,
            "files": observed.inventory.files.count, "objects": observed.capacity.objects.count,
            "selection": observed.inventory.selection.kind.rawValue, "libraryStartupReady": observed.context.supportsLibrarySync,
            "consoleFilesWritten": false, "firmwareWritten": false, "backupRequested": backupRequested, "connectionClosed": true]
        if let savedBackup {
            record["backupDirectory"] = savedBackup.directory.path; record["backupSHA256"] = savedBackup.manifestSHA256
            record["restorationPrepared"] = true; record["restoredGameCount"] = restoredGameCount
        }
        try write("manifest.json", JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]))
        guard fsync(directory.fd) == 0, fsync(outputRoot.fd) == 0 else { throw RestoreDirectory.failure() }
        var summary: [String: Any] = ["directory": directory.url.path, "complete": true,
            "freeBytes": observed.capacity.freeBytes, "libraryStartupReady": observed.context.supportsLibrarySync,
            "consoleFilesWritten": false, "firmwareWritten": false, "connectionClosed": true]
        if let savedBackup { summary["backupDirectory"] = savedBackup.directory.path; summary["restorationPrepared"] = true }
        return String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)
    }
}

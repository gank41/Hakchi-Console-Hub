import Foundation

/// Binds the transaction's typed operations to one challenge-verified Clovershell lease.
struct LegacySyncLeaseDevice: LegacySyncDevice {
    let lease: LegacySessionLease
    let uploadProgress: (@Sendable (Int64, Int64) -> Void)?

    init(lease: LegacySessionLease,
         uploadProgress: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.lease = lease
        self.uploadProgress = uploadProgress
    }

    func inspect() async throws -> LegacyConsoleReport {
        try await LegacyConsoleService.inspect(client: lease)
    }

    func requireIdentity() async throws {
        try LegacyDeviceIdentity.requireFirstNES(try await LegacyDeviceIdentity.read(client: lease))
    }

    func upload(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws {
        _ = try await lease.uploadFile(manifest.archiveURL, operationID: operationID,
                                       expectedSHA256: manifest.archiveSHA256,
                                       expectedBytes: manifest.archiveBytes,
                                       progress: uploadProgress)
    }

    func verify(_ manifest: LegacyMenuStageManifest, operationID: UUID,
                stageBudgetBytes: Int64) async throws {
        let result = try await lease.perform(.verifyStage(operationID, manifest.archiveSHA256,
                                                          manifest.archiveBytes, manifest.treeSHA256,
                                                          stageBudgetBytes, manifest.entries))
        try LegacyStageVerification.requireReceipt(result, operationID: operationID,
                                                   treeSHA256: manifest.treeSHA256)
    }

    func inventoryStage(operationID: UUID) async throws -> Data {
        let result = try await lease.perform(.inventoryStage(operationID))
        guard result.succeeded, result.stderr.isEmpty else {
            throw LegacyChangeError.refused("The inactive game inventory could not be read. The active menu was not changed.")
        }
        return result.stdoutData
    }

    func activate(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws {
        let result = try await lease.perform(.activateStage(operationID, manifest.treeSHA256,
                                                            manifest.archiveSHA256, manifest.archiveBytes))
        try LegacySyncCommands.requireActiveReceipt(result, operationID: operationID,
                                                    treeSHA256: manifest.treeSHA256)
    }

    func inspectOperation(operationID: UUID, treeSHA256: String) async throws -> LegacySyncInspection {
        let result = try await lease.perform(.inspectStage(operationID, treeSHA256))
        guard result.succeeded, result.stderr.isEmpty else { throw LegacyInspectionError.invalidResponse }
        return try LegacySyncCommands.parseInspection(result.stdoutData, operationID: operationID)
    }

    func accept(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws {
        let result = try await lease.perform(.acceptStage(operationID, manifest.treeSHA256))
        try LegacySyncCommands.requireAcceptedReceipt(result, operationID: operationID,
                                                      treeSHA256: manifest.treeSHA256)
    }

    func discard(operationID: UUID, treeSHA256: String) async throws {
        let result = try await lease.perform(.discardStage(operationID, treeSHA256))
        try LegacySyncCommands.requireRecoveryReceipt(result, kind: "DISCARDED",
                                                       operationID: operationID, treeSHA256: treeSHA256)
    }

    func rollback(operationID: UUID, treeSHA256: String) async throws {
        let result = try await lease.perform(.rollbackStage(operationID, treeSHA256))
        try LegacySyncCommands.requireRecoveryReceipt(result, kind: "ROLLED_BACK",
                                                       operationID: operationID, treeSHA256: treeSHA256)
    }
}

extension LegacySyncLeaseDevice: LegacySavedMenuRestoreDevice {
    func chipID() async throws -> String {
        try await LegacyDeviceIdentity.read(client: lease)
    }

    func inventoryLive(operationID: UUID) async throws -> Data {
        let result = try await lease.perform(.inventoryLive(operationID))
        guard result.succeeded, result.stderr.isEmpty else {
            throw LegacyChangeError.refused("The read-only NES menu inventory stopped at console step \(result.exitCode). No files were changed.")
        }
        return result.stdoutData
    }
}

extension LegacySyncLeaseDevice: LegacyOldMenuBindingDevice {
    func inventoryOld(operationID: UUID) async throws -> Data {
        let result = try await lease.perform(.inventoryOld(operationID))
        guard result.succeeded, result.stderr.isEmpty else {
            throw LegacyChangeError.refused("The read-only former-menu inventory stopped at console step \(result.exitCode). No files were changed.")
        }
        return result.stdoutData
    }
}

extension LegacySyncLeaseDevice: LegacyArchiveReclaimDevice {
    func inspectArchive(operationID: UUID, treeSHA256: String,
                        archiveSHA256: String, archiveBytes: Int64) async throws -> LegacyArchiveReclaimCommands.Inspection {
        let result = try await lease.perform(.inspectReclaimArchive(operationID, treeSHA256,
                                                                     archiveSHA256, archiveBytes))
        if result.exitCode == 127 {
            throw LegacyArchiveReclaimError.activeMenuChanged([])
        }
        guard result.succeeded, result.stderr.isEmpty else {
            throw LegacyChangeError.refused("Archive safety check stopped on the NES (code \(result.exitCode)). No archive was removed.")
        }
        return try LegacyArchiveReclaimCommands.parseState(result.stdoutData,
            operationID: operationID, archiveSHA256: archiveSHA256,
            archiveBytes: archiveBytes, treeSHA256: treeSHA256)
    }

    func removeArchive(operationID: UUID, treeSHA256: String,
                       archiveSHA256: String, archiveBytes: Int64) async throws {
        let result = try await lease.perform(.removeReclaimArchive(operationID, treeSHA256,
                                                                    archiveSHA256, archiveBytes))
        try LegacyArchiveReclaimCommands.requireRemovedReceipt(result,
            operationID: operationID, archiveSHA256: archiveSHA256)
    }
}

extension LegacySyncLeaseDevice: LegacyOldMenuReclaimDevice {
    func inspectOldMenu(operationID: UUID, liveTreeSHA256: String,
                        oldTreeSHA256: String) async throws -> Int64 {
        let result = try await lease.perform(.inspectReclaimOldMenu(
            operationID, liveTreeSHA256, oldTreeSHA256))
        guard result.succeeded, result.stderr.isEmpty else {
            throw LegacyChangeError.refused("The former-menu safety check stopped on the NES (code \(result.exitCode)). No menu was removed.")
        }
        return try LegacyOldMenuReclaimCommands.parseInspection(result.stdoutData,
            operationID: operationID, oldTreeSHA256: oldTreeSHA256)
    }

    func removeOldMenu(operationID: UUID, liveTreeSHA256: String,
                       oldTreeSHA256: String) async throws {
        let result = try await lease.perform(.removeReclaimOldMenu(
            operationID, liveTreeSHA256, oldTreeSHA256))
        try LegacyOldMenuReclaimCommands.requireRemovedReceipt(result,
            operationID: operationID, oldTreeSHA256: oldTreeSHA256)
    }
}

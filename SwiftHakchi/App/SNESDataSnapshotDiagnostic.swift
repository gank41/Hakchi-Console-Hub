import Foundation

/// Developer recovery mode only. Public installation/sync controls are unchanged.
enum SNESDataSnapshotDiagnostic {
    static func runIfPresent(_ args:[String],
        loadInputs:@Sendable () async throws -> RecoveryBootInputs = { try await PayloadService.shared.pinnedRecoveryInputs() },
        checkHost:@Sendable () async throws -> Void = { try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeIO:@Sendable (SNESPreparationSource) -> any SNESDataSnapshotIO = { NativeSNESDataSnapshotIO(source:$0) },
        progress:@escaping RecoveryProgressSink = { _ in },
        detail:@escaping @Sendable (String) async -> Void = { _ in }) async throws -> String? {
        guard args.first=="--snapshot-snes-data" else { return nil }
        guard args.count==3,args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096 }) else {
            throw RecoveryProbeError.refused("This data backup needs the saved SNES setup and an existing Mac Backups folder. Nothing was installed.")
        }
        try Task.checkCancellation(); await progress(.checkingMaterial)
        let source=try SNESPreparationSource.load(SNESOfflineSource.load(snapshot:URL(fileURLWithPath:args[1])))
        let destination=URL(fileURLWithPath:args[2]), store=try RecoveryBootSnapshotStore(root:destination)
        let plan=try source.dataSnapshotPlan()
        let values=try destination.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey,.volumeAvailableCapacityKey])
        guard let available=values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init),
              available>=Int64(plan.byteCount)+32*1024*1024 else {
            throw RecoveryProbeError.refused("The Mac Backups folder needs more free space for the console data copy. Nothing was sent to the console.")
        }
        let inputs=try await loadInputs(); _=try inputs.prepare()
        try source.revalidate(); try await checkHost(); try Task.checkCancellation(); try source.revalidate()
        let result=try await SNESDataSnapshotService().capture(source:source,inputs:inputs,io:makeIO(source),progress:progress,detail:detail)
        await detail("Saving and checking the console backup on this Mac")
        let directory=try await store.saveSNESDataSnapshot(result)
        let checked=try SNESDataSnapshotPackage.load(directory:directory,expectedHWID:source.source.expectedHWID)
        try Task.checkCancellation(); try source.revalidate()
        return String(decoding:try JSONSerialization.data(withJSONObject:["directory":directory.path,"complete":true,
            "firmwareWritten":false,"firmwareRestoreEligible":false,"dataBytes":checked.byteCount,"dataSHA256":checked.sha256,
            "status":"The console data was copied and verified on this Mac. No firmware, games or saves were changed."],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
    }
}

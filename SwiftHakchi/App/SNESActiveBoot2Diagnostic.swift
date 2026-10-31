import Foundation

enum SNESActiveBoot2Diagnostic {
    static func runIfPresent(_ args:[String],
        loadInputs:@Sendable () async throws->RecoveryBootInputs={try await PayloadService.shared.pinnedRecoveryInputs()},
        checkHost:@Sendable () async throws->Void={try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        makeIO:@Sendable (SNESPreparationSource,SNESBoundedReadHelper)->any SNESActiveBoot2IO={NativeSNESActiveBoot2IO(source:$0,helper:$1)},
        progress:@escaping RecoveryProgressSink={_ in}) async throws->String? {
        guard args.first=="--snapshot-snes-active-boot2" else {return nil}
        guard args.count==4,args.dropFirst().allSatisfy({$0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096}) else {
            throw RecoveryProbeError.refused("This startup backup needs the saved SNES setup, checked read-only helper and an existing Mac Backups folder. Nothing was installed.")
        }
        try Task.checkCancellation();await progress(.checkingMaterial)
        let source=try SNESPreparationSource.load(SNESOfflineSource.load(snapshot:URL(fileURLWithPath:args[1])))
        let helper=try SNESBoundedReadHelper.load(URL(fileURLWithPath:args[2]))
        let destination=URL(fileURLWithPath:args[3]),store=try RecoveryBootSnapshotStore(root:destination)
        let values=try destination.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey,.volumeAvailableCapacityKey])
        guard let available=values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init),available>=7340032+16*1024*1024 else {
            throw RecoveryProbeError.refused("The Mac Backups folder needs about 24 MB free for this small startup copy. Nothing was sent to the console.")
        }
        let inputs=try await loadInputs();_=try inputs.prepare()
        try source.revalidate();try helper.revalidate();try await checkHost()
        try Task.checkCancellation();try source.revalidate();try helper.revalidate()
        let directory:URL
        do {
            let result=try await SNESActiveBoot2SnapshotService().capture(source:source,inputs:inputs,helper:helper,io:makeIO(source,helper),progress:progress)
            directory=try await store.saveSNESActiveBoot2(result)
        } catch let failure as SNESActiveBoot2Failure {
            directory=try await store.saveSNESActiveBoot2Failure(failure)
            throw SNESPreparationDiagnosticSavedError(directory:directory)
        }
        let checked=try SNESActiveBoot2Package.load(directory:directory,source:source)
        try helper.revalidate();try Task.checkCancellation()
        return String(decoding:try JSONSerialization.data(withJSONObject:["directory":directory.path,"complete":true,
            "areaBytes":checked.byteCount,"areaSHA256":checked.sha256,"firmwareWritten":false,"firmwareInstallEligible":false,
            "firmwareRestoreEligible":false,"bootEligible":false,
            "status":"The small startup-area backup was copied and checked on this Mac. No firmware, games or saves were changed. Return to normal boot and check a built-in game."],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
    }
}

import Foundation

enum SNESStartupPreflightDiagnostic {
    static func runIfPresent(_ args:[String],
        loadInputs:@Sendable () async throws -> RecoveryBootInputs={try await PayloadService.shared.pinnedRecoveryInputs()},
        checkHost:@Sendable () async throws -> Void={try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        makeIO:@Sendable (SNESStartupAdapterCandidate) throws -> any SNESStartupPreflightIO,
        progress:@escaping RecoveryProgressSink={_ in}) async throws -> String? {
        guard args.first=="--preflight-snes-startup" else {return nil}
        guard args.count==3,args.dropFirst().allSatisfy({$0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096}) else {
            throw RecoveryProbeError.refused("This check needs the saved SNES startup candidate and an existing Mac Backups folder. Nothing was installed.")
        }
        try Task.checkCancellation()
        let candidate=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:args[1]))
        let store=try RecoveryBootSnapshotStore(root:URL(fileURLWithPath:args[2]))
        let inputs=try await loadInputs();_=try inputs.prepare()
        try candidate.material.revalidate();try candidate.backup.revalidate();try await checkHost();try Task.checkCancellation()
        let io=try makeIO(candidate)
        let result=try await SNESStartupPreflightService().capture(candidate:candidate,inputs:inputs,io:io,progress:progress)
        let directory=try await store.saveSNESStartupPreflight(result)
        return String(decoding:try JSONSerialization.data(withJSONObject:["directory":directory.path,"complete":true,"firmwareWritten":false,
            "firmwareInstallEligible":false,"bootEligible":false,"firmwareRestoreEligible":false,
            "status":"Startup and recovery files were verified in RAM. No firmware, games or saves were changed."],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
    }
}

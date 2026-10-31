import Foundation

enum SNESStartupTrialDiagnostic {
    static func runIfPresent(_ args:[String],
        loadInputs:@Sendable () async throws -> RecoveryBootInputs={try PayloadService.shared.pinnedRecoveryInputs()},
        checkHost:@Sendable () async throws -> Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        makeIO:@Sendable (PreparedSNESStartupTrial) throws -> any SNESStartupTrialIO,
        progress:@escaping RecoveryProgressSink={_ in}) async throws -> String? {
        guard let action=args.first,["--test-snes-startup","--check-snes-startup"].contains(action) else {return nil}
        let count=action=="--test-snes-startup" ? 4:5
        guard args.count==count,args.dropFirst().allSatisfy({$0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096}) else {
            throw RecoveryProbeError.refused("Temporary SNES startup paths are missing or invalid. Nothing was installed.")
        }
        func url(_ i:Int)->URL {URL(fileURLWithPath:args[i])}
        let candidate=try SNESStartupAdapterCandidate.load(directory:url(1)),store=try RecoveryBootSnapshotStore(root:url(count-1))
        _=try SNESStartupPreflightEvidence.load(directory:url(2),candidate:candidate)
        let trial=try PreparedSNESStartupTrial.prepare(candidate:candidate,evidence:url(2),recovery:await loadInputs())
        let started=action=="--check-snes-startup" ? try SNESStartupTrialResult.loadStarted(directory:url(3),trial:trial):nil
        try trial.validateCurrent();try await checkHost();try trial.validateCurrent()
        let io=try makeIO(trial)
        do {
            let result=try await SNESStartupTrialService().capture(trial:trial,started:started,io:io,progress:progress)
            let directory=try await store.saveSNESStartupTrial(result,trial:trial)
            if started==nil {_=try SNESStartupTrialResult.loadStarted(directory:directory,trial:trial)}
            return String(decoding:try JSONSerialization.data(withJSONObject:["directory":directory.path,"complete":true,"firmwareWritten":false,
                "firmwareInstallEligible":false,"firmwareRestoreEligible":false,"userGameplayConfirmed":false,"profileWritesPossible":true,
                "status":"Temporary startup machine checks passed. Check the TV, sound, controller and a built-in game; nothing was installed."],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
        } catch let failure as SNESStartupTrialFailure {
            let directory=try await store.saveSNESStartupTrialFailure(failure,trial:trial)
            throw SNESPreparationDiagnosticSavedError(directory:directory)
        }
    }
}

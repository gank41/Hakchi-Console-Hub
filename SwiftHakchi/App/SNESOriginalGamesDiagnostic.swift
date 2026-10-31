import Foundation
enum SNESOriginalGamesDiagnostic {
    static func runIfPresent(_ args:[String],
        loadInputs:@Sendable () async throws -> RecoveryBootInputs={try PayloadService.shared.pinnedRecoveryInputs()},
        requireOperation:@Sendable (URL)throws -> Void={try SNESFirmwareJournalPolicy.requireOperation($0)},
        checkHost:@Sendable () async throws -> Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        makeIO:@Sendable (PreparedSNESStartupTrial)throws -> any SNESOriginalGamesIO={NativeSNESOriginalGamesIO(trial:$0)}) async throws -> String? {
        guard args.first=="--capture-snes-original-games" else {return nil}
        func path(_ value:String)->Bool {value.hasPrefix("/") && !value.contains("\0") && value.utf8.count<=4096}
        guard args.count==4,path(args[1]),SNESDataSnapshotChunk.isDigest(args[2]),path(args[3]) else {throw SNESOriginalGamesFrame.failure()}
        try Task.checkCancellation()
        let operation=URL(fileURLWithPath:args[1]);try requireOperation(operation)
        let inputs=try await loadInputs();_=try inputs.prepare()
        let journal=try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:args[2],recovery:inputs)
        do {
            let accepted=try await journal.acceptedInstall(),checked=try SNESFirmwareGuard.prepare(accepted.material)
            let store=try RecoveryBootSnapshotStore(root:URL(fileURLWithPath:args[3]))
            try await checkHost();try checked.require(accepted.material)
            let result=try await SNESOriginalGamesCapture().capture(accepted:accepted,guard:checked,io:makeIO(accepted.material.trial))
            // Verify the accepted operation was not edited while its read-only connection ran.
            _=try await journal.acceptedInstall();try checked.require(accepted.material)
            let directory=try await store.saveSNESOriginalGames(result)
            try await journal.close()
            return String(decoding:try JSONSerialization.data(withJSONObject:["directory":directory.path,"operation":operation.path,"reviewSHA256":args[2],
                "complete":true,"firmwareWritten":false,"syncEligible":false,
                "status":"Original game details are saved on this Mac. The console’s games and menu were not changed."],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
        } catch {
            try? await journal.close()
            throw error
        }
    }
}

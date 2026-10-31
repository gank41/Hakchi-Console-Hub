import Foundation

/// Developer transactions require a saved review and explicit action token.
enum SNESFirmwareDiagnostic {
    static func handles(_ action:String?)->Bool {
        guard let action else {return false}
        return ["--prepare-snes-firmware","--preflight-snes-firmware","--write-snes-firmware","--check-snes-installed-startup","--accept-snes-firmware","--prepare-snes-stock-restore","--inspect-snes-firmware"].contains(action)
    }
    static func runIfPresent(_ args:[String],
        loadInputs:@Sendable () async throws->RecoveryBootInputs={try PayloadService.shared.pinnedRecoveryInputs()},
        root:@Sendable () throws->URL={try SNESFirmwareJournalPolicy.ensureRoot()},
        requireOperation:@Sendable (URL)throws->Void={try SNESFirmwareJournalPolicy.requireOperation($0)},
        checkHost:@Sendable () async throws->Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        makeIO:@Sendable (SNESFirmwareMaterial,SNESFirmwareGuard)throws->any SNESFirmwareIO={try NativeSNESFirmwareIO(material:$0,guard:$1)},
        makeStartupIO:@Sendable (PreparedSNESStartupTrial)->any SNESInstalledStartupIO={NativeSNESInstalledStartupIO(trial:$0)},
        makeReadIO:@Sendable (SNESPreparationSource,SNESBoundedReadHelper)->any SNESActiveBoot2IO={NativeSNESActiveBoot2IO(source:$0,helper:$1)},
        progress:@escaping RecoveryProgressSink={_ in},
        detail:@Sendable (String)->Void={FileHandle.standardError.write(Data(($0+"\n").utf8))}) async throws->String? {
        guard let action=args.first,handles(action) else {return nil}
        func validPath(_ s:String)->Bool {s.hasPrefix("/") && !s.contains("\0") && s.utf8.count<=4096}
        let count=action=="--prepare-snes-firmware" ? 2:["--write-snes-firmware","--accept-snes-firmware"].contains(action) ? 4:3
        guard args.count==count,validPath(args[1]),(count==2 || SNESDataSnapshotChunk.isDigest(args[2])),
              action != "--write-snes-firmware" || args[3]=="--confirm-reviewed-write",
              action != "--accept-snes-firmware" || args[3]=="--confirm-menu-and-gameplay" else {
            throw RecoveryProbeError.refused("The saved console update or its action confirmation is missing or invalid. No new update was started.")
        }
        try Task.checkCancellation();await progress(.checkingMaterial)
        if action=="--prepare-snes-firmware" {
            let request=URL(fileURLWithPath:args[1]),directory=try RestoreDirectory(request.deletingLastPathComponent())
            let raw=try directory.read(request.lastPathComponent,maximum:65536),paths=try JSONDecoder().decode(SNESFirmwarePaths.self,from:raw)
            try paths.validate()
            let encoded=try JSONEncoder().encode(paths)
            guard let decoded=try JSONSerialization.jsonObject(with:encoded) as? NSDictionary,
                  let actual=try JSONSerialization.jsonObject(with:raw) as? [String:Any],decoded.isEqual(to:actual) else {throw RestoreDirectory.failure()}
            let recovery=try await loadInputs();_=try recovery.prepare()
            let material=try SNESFirmwareMaterial.install(paths:paths,recovery:recovery),checked=try SNESFirmwareGuard.prepare(material)
            try SNESColdBootPolicy.require(boot1:material.source.boot1,image:material.trial.image)
            let prepared=try SNESFirmwareJournal.prepare(material:material,root:root(),guard:checked)
            return try json(["operation":prepared.operation.path,"reviewSHA256":prepared.reviewSHA256,"phase":"prepared",
                             "firmwareWritten":false,"USBOpened":false,"changedUnits":material.changedUnits.count,
                             "status":"Startup files are checked and saved on this Mac. The next step checks the console without installing anything."])
        }
        let operation=URL(fileURLWithPath:args[1]);try requireOperation(operation)
        let recovery=try await loadInputs();_=try recovery.prepare()
        let journal=try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:args[2],recovery:recovery)
        do {
            let phase=try await journal.phase()
            // Reject the wrong phase before constructing any native connection.
            switch action {
            case "--preflight-snes-firmware":guard phase == .prepared else {throw RestoreDirectory.failure()}
            case "--write-snes-firmware":guard phase == .preflightVerified else {throw RestoreDirectory.failure()}
            case "--check-snes-installed-startup":guard phase == .readbackVerified else {throw RestoreDirectory.failure()}
            case "--accept-snes-firmware":guard [.startupVerified,.readbackVerified].contains(phase) else {throw RestoreDirectory.failure()}
            case "--prepare-snes-stock-restore":guard [.readbackVerified,.startupVerified,.menuAccepted].contains(phase) else {throw RestoreDirectory.failure()}
            case "--inspect-snes-firmware":guard [.writeIntent,.uncertain,.readbackVerified].contains(phase) else {throw RestoreDirectory.failure()}
            default:throw RestoreDirectory.failure()
            }
            let material=try await journal.verifiedMaterial(),checked=try SNESFirmwareGuard.prepare(material)
            if action=="--accept-snes-firmware" {
                guard phase==(material.direction == .install ? .startupVerified:.readbackVerified) else {throw RestoreDirectory.failure()}
                try checked.require(material);try await journal.acceptMenu();try await journal.close()
                return try json(["operation":operation.path,"reviewSHA256":args[2],"phase":"menuAccepted","firmwareWriteRequested":false,
                                 "userGameplayConfirmed":true,"fullFactoryResetPerformed":false,"status":"Console startup and gameplay are confirmed. Your Mac recovery files are kept."])
            }
            if action=="--prepare-snes-stock-restore" {
                let installed=try await journal.restorableInstall();try await journal.close()
                let restore=try SNESFirmwareMaterial.restore(installed:installed),seal=try SNESFirmwareGuard.prepare(restore)
                let prepared=try SNESFirmwareJournal.prepare(material:restore,root:operation.deletingLastPathComponent(),guard:seal)
                return try json(["operation":prepared.operation.path,"reviewSHA256":prepared.reviewSHA256,"phase":"prepared","direction":"restore",
                                 "firmwareWritten":false,"USBOpened":false,"changedUnits":restore.changedUnits.count,
                                 "status":"Original-startup restoration is prepared on this Mac. It preserves games, settings and saves; no firmware was sent."])
            }
            if action=="--check-snes-installed-startup",material.direction != .install {throw RestoreDirectory.failure()}
            try await checkHost();try checked.require(material)
            if action=="--check-snes-installed-startup" {
                let result=try await SNESInstalledStartupCheck().run(journal:journal,guard:checked,io:makeStartupIO(material.trial))
                try await journal.close()
                return try json(["operation":operation.path,"reviewSHA256":args[2],"phase":"startupVerified","firmwareWriteRequested":false,
                                 "userGameplayConfirmed":false,"normalStartup":try JSONSerialization.jsonObject(with:Data(result.export().utf8)),
                                 "status":"The installed startup connection is verified. Test a built-in game, picture, sound and controls before accepting."])
            }
            if action=="--inspect-snes-firmware" {
                let result=try await SNESFirmwareInspection().run(journal:journal,guard:checked,inputs:recovery,io:makeReadIO(material.source,material.reader),progress:progress)
                try await journal.close()
                return try json(["operation":operation.path,"reviewSHA256":args[2],"phase":phase.rawValue,"firmwareWriteRequested":false,
                                 "classification":result.classification.rawValue,"observedSHA256":result.observedSHA256,"challenges":result.challenges.map(\.uuidString),
                                 "context":try JSONSerialization.jsonObject(with:JSONEncoder().encode(SNESDataSnapshotResult.RecoverySessionContextRecord(result.context))),
                                 "status":"The startup area was read twice. No write was retried and the saved operation remains blocked for review."])
            }
            let writing=action=="--write-snes-firmware",io=try makeIO(material,checked)
            _=try await SNESFirmwareTransaction().run(mode:writing ? .write:.preflight,journal:journal,guard:checked,inputs:recovery,io:io,progress:progress)
            guard try await journal.phase()==(writing ? .readbackVerified:.preflightVerified) else {throw RestoreDirectory.failure()}
            try await journal.close()
            return try json(["operation":operation.path,"reviewSHA256":args[2],"phase":writing ? "readbackVerified":"preflightVerified",
                             "firmwareWritten":writing,"USBOpened":true,"fullFactoryResetPerformed":false,
                             "status":writing ? "Console startup was written once and its complete readback is verified. Return to normal startup and check a built-in game.":"Console preparation passed. No firmware was installed. Return to normal startup and check a built-in game."])
        } catch {
            detail(Self.failureDetail(error));try? await journal.close()
            if error is SNESFirmwareTransactionError {throw error}
            throw RecoveryProbeError.refused("The console operation did not finish. Preserve its saved record and diagnostic details for inspection. Do not retry a firmware write automatically.")
        }
    }
    static func failureMessage(arguments:[String],error:any Error)->String {
        if arguments.first=="--write-snes-firmware" {
            return "The SNES update was not verified as complete. Keep power and USB connected. Do not restart or retry; inspect the saved operation first.\n"+failureDetail(error)+"\n"
        }
        return "SNES operation stopped: "+error.localizedDescription+"\n"+failureDetail(error)+"\n"
    }
    static func failureDetail(_ error:any Error)->String {
        let value=(error as? SNESFirmwareTransactionError)?.privateEvidence ?? (error as? SNESFirmwareCommandFailure)?.diagnostic ?? String(describing:error)
        return "Private console-operation details: "+String(decoding:Data(value.utf8).prefix(12000),as:UTF8.self)
    }
    private static func json(_ value:[String:Any])throws->String {
        String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
    }
}

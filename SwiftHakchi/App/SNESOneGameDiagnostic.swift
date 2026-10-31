import Foundation
import SwiftHakchiCore

/// Developer-only first-game preparation and inactive copy; no menu activation or firmware write.
enum SNESOneGameDiagnostic {
    static func runIfPresent(_ args:[String],
        loadInputs:@Sendable () async throws->RecoveryBootInputs={try PayloadService.shared.pinnedRecoveryInputs()},
        requireFirmware:@Sendable (URL)throws->Void={try SNESFirmwareJournalPolicy.requireOperation($0)},
        requireOperation:@Sendable (URL)throws->Void={try SNESOneGameJournalPolicy.requireOperation($0)},
        journalRoot:@Sendable ()throws->URL={try SNESOneGameJournalPolicy.ensureRoot()},
        checkHost:@Sendable () async throws->Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        makeIO:@Sendable (SNESOneGameMaterial)throws->any SNESOneGameStageIO={NativeSNESOneGameStageIO(material:$0)}) async throws->String? {
        let modes=["--prepare-snes-one-game","--preflight-snes-one-game","--copy-snes-one-game","--inspect-snes-one-game"]
        guard let mode=args.first,modes.contains(mode) else {return nil}
        func path(_ s:String)->Bool {s.hasPrefix("/") && !s.contains("\0") && s.utf8.count<=4096}
        let preparing=mode==modes[0],copying=mode==modes[2],inspecting=mode==modes[3]
        let recording=inspecting && args.count==4 && args[3]=="--record-inactive-result"
        guard preparing ? args.count==2 && path(args[1]):
            (args.count==((copying || recording) ? 4:3) && path(args[1]) && SNESDataSnapshotChunk.isDigest(args[2]) && (!copying || args[3]=="--confirm-copy-reviewed-games")) else {throw SNESOneGameMenu.failure()}
        let paths:SNESOneGamePaths,saved:SNESOneGameStageJournal.Saved?
        if preparing {
            let request=URL(fileURLWithPath:args[1]),d=try RestoreDirectory(request.deletingLastPathComponent())
            paths=try JSONDecoder().decode(SNESOneGamePaths.self,from:d.read(request.lastPathComponent,maximum:32768));saved=nil
        } else {
            let operation=URL(fileURLWithPath:args[1]);try requireOperation(operation)
            let s=try SNESOneGameStageJournal.readSaved(operation:operation,reviewSHA256:args[2])
            paths=try JSONDecoder().decode(SNESOneGameMaterial.Plan.self,from:s.materialPlan).paths;saved=s
        }
        try paths.validate()
        let firmwareOperation=URL(fileURLWithPath:paths.firmwareOperation);try requireFirmware(firmwareOperation)
        let inputs=try await loadInputs();_=try inputs.prepare()
        let firmware=try await SNESFirmwareJournal.reopen(operation:firmwareOperation,reviewSHA256:paths.firmwareReviewSHA256,recovery:inputs)
        do {
            let accepted=try await firmware.acceptedInstall()
            if preparing {
                let material=try SNESOneGameMaterial.prepare(paths:paths,accepted:accepted),store=try RecoveryBootSnapshotStore(root:URL(fileURLWithPath:paths.backupsDirectory))
                let artifact=try await store.saveSNESOneGame(material)
                let prepared=try SNESOneGameStageJournal.prepare(material:material,artifact:artifact,root:journalRoot())
                try await firmware.close()
                return try json(["operation":prepared.operation.path,"reviewSHA256":prepared.reviewSHA256,"artifact":artifact.path,
                    "game":material.menu.title,"gameCount":material.menu.gameCount,"requiredFreeBytes":material.requiredFreeBytes,
                    "consoleRoot":material.menu.consoleRoot,"menuTreeSHA256":material.menu.treeSHA256,"copied":false,"menuChanged":false,"firmwareWritten":false,
                    "status":"One added game is prepared on the Mac. The console has not changed."])
            }
            guard let saved else {throw SNESOneGameMenu.failure()}
            let artifact=URL(fileURLWithPath:saved.artifactPath),material=try SNESOneGameMaterial.load(directory:artifact,accepted:accepted)
            guard try material.planData()==saved.materialPlan else {throw SNESOneGameMenu.failure()}
            let journal=try SNESOneGameStageJournal(operation:URL(fileURLWithPath:args[1]),reviewSHA256:args[2],material:material,artifact:artifact)
            do {
                let phase=try await journal.phase()
                guard (inspecting && (!recording || phase == .uncertain)) || (!inspecting && phase == .prepared) else {throw SNESOneGameMenu.failure()}
                try await checkHost();try material.validate()
                let io=try makeIO(material),stage=SNESOneGameStage()
                if inspecting {
                    let result=try await stage.inspect(material:material,io:io)
                    _=try await firmware.acceptedInstall();try material.validate()
                    if recording {try await journal.noteInactiveFailure(result)}
                    let finalPhase=try await journal.phase()
                    guard finalPhase==(recording ? .failedInactive:phase) else {throw SNESOneGameMenu.failure()}
                    try await journal.close();try await firmware.close()
                    return try json(["operation":args[1],"reviewSHA256":args[2],"matchesMenu":result.matchesMenu,"copyLimitReady":result.copyLimitReady,"fileSizeLimit":result.fileSizeLimit,"inspectionBase64":result.raw.base64EncodedString(),
                        "inspectionSHA256":BackupManifest.digest(result.raw),"phase":finalPhase.rawValue,"recordedInactiveFailure":recording,"copied":false,"menuChanged":false,"firmwareWritten":false,
                        "status":recording ? "The incomplete inactive test copy was checked and recorded on the Mac. It was not retried.":"The stopped transfer was inspected without changing its files or retrying the copy."])
                }
                let receipt:SNESOneGameStageReceipt
                if copying {receipt=try await stage.copy(material:material,journal:journal,io:io)}
                else {receipt=try await stage.preflight(material:material,io:io)}
                _=try await firmware.acceptedInstall();try material.validate()
                try await journal.close();try await firmware.close()
                return try json(["operation":args[1],"reviewSHA256":args[2],"copied":copying,"menuChanged":false,"firmwareWritten":false,
                    "game":material.menu.title,"gameCount":material.menu.gameCount,"requiredFreeBytes":material.requiredFreeBytes,"freeBytes":receipt.freeBytes,
                    "receiptBase64":receipt.raw.base64EncodedString(),"receiptSHA256":BackupManifest.digest(receipt.raw),
                    "status":copying ? "The added game was copied and verified. The visible menu has not changed.":"The console is ready for the reviewed game copy. No files were changed."])
            } catch {try? await journal.close();throw error}
        } catch {try? await firmware.close();throw error}
    }
    private static func json(_ value:[String:Any])throws->String {
        String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
    }
}

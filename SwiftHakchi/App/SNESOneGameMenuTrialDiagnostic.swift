import Foundation
import SwiftHakchiCore
enum SNESOneGameMenuTrialDiagnostic {
 static func runIfPresent(_ args:[String],loadInputs:@Sendable () async throws->RecoveryBootInputs={try PayloadService.shared.pinnedRecoveryInputs()},requireOperation:@Sendable (URL)throws->Void={try SNESOneGameJournalPolicy.requireOperation($0)},requireFirmware:@Sendable (URL)throws->Void={try SNESFirmwareJournalPolicy.requireOperation($0)},checkHost:@Sendable () async throws->Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},makeIO:@Sendable (SNESOneGameMaterial)throws->any SNESOneGameMenuTrialIO={NativeSNESOneGameMenuTrialIO(material:$0)}) async throws->String? {
  let modes=["--review-snes-one-game-menu","--test-snes-one-game-menu","--check-snes-one-game-menu","--finish-snes-one-game-menu-test"]
  guard let mode=args.first,modes.contains(mode) else {return nil}
  let starting=mode==modes[1],reviewing=mode==modes[0],original=mode==modes[3]
  guard args.count==(starting ? 4:3),args[1].hasPrefix("/"),!args[1].contains("\0"),args[1].utf8.count<=4096,
        SNESDataSnapshotChunk.isDigest(args[2]),!starting || args[3]=="--confirm-temporary-menu" else {throw SNESOneGameMenu.failure()}
  let operation=URL(fileURLWithPath:args[1]);try requireOperation(operation)
  let saved=try SNESOneGameStageJournal.readSaved(operation:operation,reviewSHA256:args[2]),plan=try JSONDecoder().decode(SNESOneGameMaterial.Plan.self,from:saved.materialPlan)
  try plan.paths.validate();let firmwareOperation=URL(fileURLWithPath:plan.paths.firmwareOperation);try requireFirmware(firmwareOperation)
  let inputs=try await loadInputs();_=try inputs.prepare()
  let firmware=try await SNESFirmwareJournal.reopen(operation:firmwareOperation,reviewSHA256:plan.paths.firmwareReviewSHA256,recovery:inputs)
  do {
   let accepted=try await firmware.acceptedInstall(),artifact=URL(fileURLWithPath:saved.artifactPath),material=try SNESOneGameMaterial.load(directory:artifact,accepted:accepted)
   guard !accepted.material.trial.candidate.hasMenuSupport,try material.planData()==saved.materialPlan else {throw SNESOneGameMenu.failure()}
   let journal=try SNESOneGameStageJournal(operation:operation,reviewSHA256:args[2],material:material,artifact:artifact)
   do {
    let phase=try await journal.phase()
    guard (reviewing || starting) ? [.inactiveVerified,.menuTrialReturned].contains(phase) : (phase == .menuTrialShown || original && [.menuTrialUncertain,.menuTrialIntent].contains(phase)) else {throw SNESOneGameMenu.failure()}
    func json(_ value:[String:Any])throws->String {String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)}
    if reviewing {
     let script=try SNESOneGameMenuTrialCommands.start(menu:material.menu,originals:material.originals.frame,binding:accepted.material.trial.candidate.material.binding,challenge:material.menu.id)
     _=try SNESOneGameStream(script:script,body:Data())
     try await journal.close();try await firmware.close()
     return try json(["operation":operation.path,"reviewSHA256":args[2],"phase":phase.rawValue,"game":material.menu.title,"gameCount":material.menu.gameCount,
      "menuTreeSHA256":material.menu.treeSHA256,"commandSHA256":BackupManifest.digest(Data(script.utf8)),"RAMFolder":SNESOneGameMenuTrialCommands.ramRoot(material.menu),
      "USBOpened":false,"firmwareWritten":false,"persistentSelectorChanged":false,"gameFilesChanged":false,"profileWritesPossible":true,
      "status":"Temporary menu test prepared on the Mac. It will show the copied game until the console is powered off; normal settings or game saves can be written during play."])
    }
    try await checkHost();try material.validate();let io=try makeIO(material),service=SNESOneGameMenuTrialService(),receipt:SNESOneGameMenuTrialReceipt
    if starting {receipt=try await service.start(material:material,journal:journal,io:io)}
    else {receipt=try await service.check(material:material,journal:journal,io:io,original:original)}
    _=try await firmware.acceptedInstall();try material.validate();let final=try await journal.phase()
    try await journal.close();try await firmware.close()
    return try json(["operation":operation.path,"reviewSHA256":args[2],"phase":final.rawValue,"game":material.menu.title,"gameCount":material.menu.gameCount,
     "firmwareWritten":false,"persistentSelectorChanged":false,"gameFilesChanged":false,"profileWritesPossible":true,"userGameplayConfirmed":false,
     "receiptBase64":receipt.raw.base64EncodedString(),"receiptSHA256":BackupManifest.digest(receipt.raw),"mcpPID":receipt.mcpPID,"daemonPID":receipt.daemonPID,
     "status":original ? "The original menu and normal startup connection were checked after the power cycle.":starting ? "The temporary game menu passed its Mac checks. Check the TV, launch the added game and a built-in game, then return to the menu.":"The temporary game menu and Mac connection still pass their checks. The game test still needs your observation."])
   } catch {try? await journal.close();throw error}
  } catch {try? await firmware.close();throw error}
 }
}

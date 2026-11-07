import Foundation
import SwiftHakchiCore

enum SNESMenuSelectionDiagnostic {
 private static let modes=["--prepare-snes-menu-selection","--inspect-snes-menu-selection","--select-snes-menu","--check-snes-selected-menu","--accept-snes-selected-menu"]
 static func handles(_ action:String?)->Bool {action.map{modes.contains($0)} ?? false}
 static func failureMessage(arguments:[String],error:any Error)->String {
  if let unverified=error as? SNESMenuSelectionUnverified {return "ERROR: "+unverified.localizedDescription+"\n"}
  // A failure outside the service can follow a successful publication, too.
  if arguments.first=="--select-snes-menu",arguments.count>=3,arguments[1].hasPrefix("/"),
   !arguments[1].contains("\0"),arguments[1].utf8.count<=4096,SNESDataSnapshotChunk.isDigest(arguments[2]) {
   return "ERROR: "+SNESMenuSelectionUnverified(operation:URL(fileURLWithPath:arguments[1]),reviewSHA256:arguments[2]).localizedDescription+"\n"
  }
  return "ERROR: The menu-selection action did not complete. Check the saved operation before trying again. No save was retried.\n"
 }
 static func runIfPresent(_ args:[String],
  loadInputs:@Sendable () async throws->RecoveryBootInputs={try PayloadService.shared.pinnedRecoveryInputs()},
  root:@Sendable ()throws->URL={try SNESMenuSelectionPolicy.ensureRoot()},
  requireOperation:@Sendable (URL)throws->Void={try SNESMenuSelectionPolicy.requireOperation($0)},
  requireFirmware:@Sendable (URL)throws->Void={try SNESFirmwareJournalPolicy.requireOperation($0)},
  requireGame:@Sendable (URL)throws->Void={try SNESOneGameJournalPolicy.requireOperation($0)},
  checkHost:@Sendable () async throws->Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
  makeIO:@Sendable (SNESMenuSelectionMaterial)throws->any SNESMenuSelectionIO={NativeSNESMenuSelectionIO(material:$0)}) async throws->String? {
  guard let action=args.first,modes.contains(action) else {return nil}
  let preparing=action==modes[0],selecting=action==modes[2],checking=action==modes[3],accepting=action==modes[4]
  func validPath(_ s:String)->Bool {s.hasPrefix("/") && !s.contains("\0") && s.utf8.count<=4096}
  guard args.count==(preparing ? 2:selecting || accepting ? 4:3),validPath(args[1]),preparing || SNESDataSnapshotChunk.isDigest(args[2]),
    !selecting || args[3]=="--confirm-reviewed-menu",!accepting || args[3]=="--confirm-gameplay-and-cold-start" else {throw SNESOneGameMenu.failure()}
  func json(_ value:[String:Any])throws->String {String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)}
  func validateRequest(_ request:SNESMenuSelectionRequest)throws {
   try request.validate();try requireFirmware(URL(fileURLWithPath:request.firmwareOperation));try requireGame(URL(fileURLWithPath:request.gameOperation))
   let saved=try SNESOneGameStageJournal.readSaved(operation:URL(fileURLWithPath:request.gameOperation),reviewSHA256:request.gameReviewSHA256)
   let p=try JSONDecoder().decode(SNESOneGameMaterial.Plan.self,from:saved.materialPlan);try p.paths.validate();try requireFirmware(URL(fileURLWithPath:p.paths.firmwareOperation))
  }
  if preparing {
   let file=URL(fileURLWithPath:args[1]),d=try RestoreDirectory(file.deletingLastPathComponent()),raw=try d.read(file.lastPathComponent,maximum:16384)
   let request=try JSONDecoder().decode(SNESMenuSelectionRequest.self,from:raw)
   guard let canonical=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as? NSDictionary,
    let actual=try JSONSerialization.jsonObject(with:raw) as? [String:Any],canonical.isEqual(to:actual) else {throw SNESOneGameMenu.failure()}
   try validateRequest(request);let inputs=try await loadInputs();_=try inputs.prepare()
   let m=try await SNESMenuSelectionMaterial.prepare(request:request,recovery:inputs)
   let script=try SNESMenuSelectionCommands.publish(menu:m.game.menu,originals:m.game.originals.frame,binding:m.binding,operation:m.id,challenge:m.id)
   _=try SNESOneGameStream(script:script,body:Data())
   let prepared=try SNESMenuSelectionJournal.prepare(material:m,root:root())
   return try json(["operation":prepared.operation.path,"reviewSHA256":prepared.reviewSHA256,"phase":"prepared","game":m.game.menu.title,"gameCount":m.game.menu.gameCount,
    "menuTreeSHA256":m.game.menu.treeSHA256,"selectorSHA256":m.selectorSHA256,"selectorBytes":SNESMenuSelectionCommands.selector(menu:m.game.menu).count,
    "consolePath":SNESOneGameMenu.namespace+"/active-menu","USBOpened":false,"firmwareWritten":false,"gameFilesChanged":false,"restartRequired":true,
    "status":"The game menu is ready for review. Saving this small selection lets the console show the copied game after a normal restart."])
  }
  let operation=URL(fileURLWithPath:args[1]);try requireOperation(operation)
  let p=try SNESMenuSelectionJournal.readPlan(operation:operation,reviewSHA256:args[2]);try validateRequest(p.request)
  let inputs=try await loadInputs();_=try inputs.prepare()
  let m=try await SNESMenuSelectionMaterial.prepare(request:p.request,recovery:inputs,id:p.id)
  let journal=try SNESMenuSelectionJournal(operation:operation,reviewSHA256:args[2],material:m)
  do {
   let phase=try await journal.phase()
   guard !selecting || phase == .prepared,!checking || phase == .selected,!accepting || phase == .startupVerified else {throw SNESOneGameMenu.failure()}
   if accepting {
    try m.validate();try await journal.accept();try await journal.close()
    return try json(["operation":operation.path,"reviewSHA256":args[2],"phase":"accepted","userGameplayConfirmed":true,"firmwareWritten":false,"USBOpened":false,
     "status":"The added game and built-in games are confirmed after normal startup. Your Mac recovery files are kept."])
   }
   try await checkHost();try m.validate();let io=try makeIO(m),service=SNESMenuSelectionService(),r:SNESMenuSelectionReceipt
   if selecting {r=try await service.select(material:m,journal:journal,io:io)}
   else if checking {r=try await service.checkStartup(material:m,journal:journal,io:io)}
   else {r=try await service.inspect(material:m,io:io)}
   try m.validate();let final=try await journal.phase();try await journal.close()
   return try json(["operation":operation.path,"reviewSHA256":args[2],"phase":final.rawValue,"firmwareWritten":false,"gameFilesChanged":false,
    "selectorSelected":r.selected,"displaySelected":r.displaySelected,"userGameplayConfirmed":false,"receiptBase64":r.raw.base64EncodedString(),"receiptSHA256":BackupManifest.digest(r.raw),
    "status":selecting ? "The console’s game menu is set. Restart normally, then check the added game and a built-in game.":checking ? "The console’s game menu and Mac connection are verified after startup. Confirm picture, sound and controls before finishing.":"The console’s saved game-menu setting and current game menu were checked without changing files."])
  } catch {try? await journal.close();throw error}
 }
}

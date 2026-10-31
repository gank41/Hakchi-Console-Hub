import Foundation
import SwiftHakchiCore

/// Accepted-parent RAM preparation only. No firmware write or selector capability.
enum SNESMenuStartupDiagnostic {
 static func runIfPresent(_ args:[String],
  resolveParent:@Sendable (SNESFirmwareJournal) async throws->SNESMenuStartupParent={try await $0.menuStartupParent()},
  loadInputs:@Sendable () async throws->RecoveryBootInputs={try PayloadService.shared.pinnedRecoveryInputs()},
  requireOperation:@Sendable (URL)throws->Void={try SNESFirmwareJournalPolicy.requireOperation($0)},
  checkHost:@Sendable () async throws->Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
  makePreflightIO:@Sendable (SNESStartupAdapterCandidate,SNESMenuStartupParent)throws->any SNESStartupPreflightIO={candidate,parent in try NativeSNESStartupPreflightIO(candidate:candidate,parent:parent)},
  makeTrialIO:@Sendable (PreparedSNESStartupTrial)throws->any SNESStartupTrialIO={NativeSNESStartupTrialIO(trial:$0)},
  progress:@escaping RecoveryProgressSink={_ in}) async throws->String? {
  let modes=["--prepare-snes-menu-startup","--preflight-snes-menu-startup","--test-snes-menu-startup","--check-snes-menu-startup"]
  guard let mode=args.first,let index=modes.firstIndex(of:mode) else {return nil}
  func path(_ text:String)->Bool {text.hasPrefix("/") && !text.contains("\0") && text.utf8.count<=4096}
  guard args.count==index+4,SNESDataSnapshotChunk.isDigest(args[2]),args.enumerated().allSatisfy({$0.offset==0 || $0.offset==2 || path($0.element)}) else {throw SNESRuntimeBinding.failure()}
  func url(_ i:Int)->URL {URL(fileURLWithPath:args[i])}
  try requireOperation(url(1))
  let inputs=try await loadInputs();_=try inputs.prepare()
  let journal=try await SNESFirmwareJournal.reopen(operation:url(1),reviewSHA256:args[2],recovery:inputs)
  let parent:SNESMenuStartupParent
  do {parent=try await resolveParent(journal);try await journal.close()}
  catch {try? await journal.close();throw error}
  let store=try RecoveryBootSnapshotStore(root:url(args.count-1))
  func json(_ value:[String:Any])throws->String {String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)}
  if index==0 {
   try parent.validate();let directory=try await store.saveSNESStartupCandidate(parent.candidate);try parent.validate()
   let saved=try SNESStartupAdapterCandidate.load(directory:directory);try parent.require(saved)
   return try json(["candidate":directory.path,"parentOperation":url(1).path,"parentReviewSHA256":args[2],"imageSHA256":BackupManifest.digest(saved.image),"imageBytes":saved.image.count,
    "USBOpened":false,"firmwareWritten":false,"dataBackupCreated":false,"status":"Menu startup files are prepared on this Mac. Nothing was installed; the original recovery backup is reused."])
  }
  let candidate=try SNESStartupAdapterCandidate.load(directory:url(3));try parent.require(candidate)
  if index==1 {
   try await checkHost();try parent.validate()
   let result=try await SNESStartupPreflightService().capture(candidate:candidate,inputs:inputs,io:makePreflightIO(candidate,parent),progress:progress,parent:parent)
   try parent.validate();let directory=try await store.saveSNESStartupPreflight(result);try parent.validate()
   _=try SNESStartupPreflightEvidence.load(directory:directory,candidate:candidate,parent:parent)
   return try json(["directory":directory.path,"scope":"snes-menu-startup-no-flash-preflight","firmwareWritten":false,"USBOpened":true,"dataBackupCreated":false,
    "status":"The installed startup and new files passed the memory-only preparation check. No firmware or games were changed."])
  }
  let trial=try PreparedSNESStartupTrial.prepare(candidate:candidate,evidence:url(4),recovery:inputs,parent:parent)
  let started=index==3 ? try SNESStartupTrialResult.loadStarted(directory:url(5),trial:trial):nil
  try await checkHost();try trial.validateCurrent()
  do {
   let result=try await SNESStartupTrialService().capture(trial:trial,started:started,io:try makeTrialIO(trial),progress:progress)
   try parent.validate();let directory=try await store.saveSNESStartupTrial(result,trial:trial);try parent.validate()
   return try json(["directory":directory.path,"phase":result.phase,"firmwareWritten":false,"firmwareInstallEligible":false,"userGameplayConfirmed":false,"profileWritesPossible":true,"dataBackupCreated":false,
    "status":index==2 ? "The menu-enabled startup passed its memory-only Mac checks. Check the TV, sound, controller and a built-in game.":"The menu-enabled startup connection passed its post-game checks. No firmware was installed."])
  } catch let failure as SNESStartupTrialFailure {
   let directory=try await store.saveSNESStartupTrialFailure(failure,trial:trial)
   throw SNESPreparationDiagnosticSavedError(directory:directory)
  }
 }
}

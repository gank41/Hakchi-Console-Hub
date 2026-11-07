import Foundation
import CryptoKit
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func menuStartupParentFixture(_ root:URL,accepted:Bool=true) async throws -> (SNESFirmwareJournal,URL) {
 let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"]),source=URL(fileURLWithPath:path),transactions=root.appendingPathComponent("transactions"),operation=transactions.appendingPathComponent(source.lastPathComponent)
 try FileManager.default.createDirectory(at:transactions,withIntermediateDirectories:false)
 try FileManager.default.copyItem(at:source,to:operation)
 if !accepted {let records=try FileManager.default.contentsOfDirectory(at:operation,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("0")}.sorted{$0.lastPathComponent<$1.lastPathComponent};try FileManager.default.removeItem(at:try #require(records.last))}
 let review=BackupManifest.digest(try Data(contentsOf:operation.appendingPathComponent("plan.json"))),pins=try PinnedFELInputs.load()
 return (try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:review,recovery:.init(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)),operation)
}
@Suite(.serialized)
struct SNESMenuStartupPreparationTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_REVIEWED_PARENT"] != nil))
 @MainActor func appCanPrepareMenuUsingNewerBackupAfterReviewedInstall() async throws {
  let source=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_REVIEWED_PARENT"]))
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let operations=root.appendingPathComponent("operations");try FileManager.default.createDirectory(at:operations,withIntermediateDirectories:false)
  let operation=operations.appendingPathComponent(source.lastPathComponent);try FileManager.default.copyItem(at:source,to:operation)
  let raw=try Data(contentsOf:operation.appendingPathComponent("plan.json")),plan=try JSONDecoder().decode(SNESFirmwarePlan.self,from:raw)
  let first=try #require(plan.firstInstall)
  let prior=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:plan.paths.candidate))
  let copy=root.appendingPathComponent("SNES-Current-Data-"+UUID().uuidString)
  try FileManager.default.copyItem(at:prior.backup.directory,to:copy)
  let current=SNESDataSnapshotReceipt(directory:copy,manifestSHA256:BackupManifest.digest(try Data(contentsOf:copy.appendingPathComponent("manifest.json"))))
  let config=AppConfig();config.lastConsoleType = .snesUsa;config.workspacePath=root.path;config.backupDirectoryPath=root.path
  let app=AppState(startDeviceMonitoring:false,config:config,saveConfiguration:{},checkRecoveryHost:{Issue.record("Preparing a menu must not open the console")},firmwareJournalRoot:{operations})
  app.isPreparingSync=true
  let check=SNESReviewedConsoleCheck(operation:operation,planSHA256:BackupManifest.digest(raw),review:.init(directory:URL(fileURLWithPath:first.reviewDirectory),sha256:first.reviewSHA256))
  let reopened=try await app.reopenSNESReviewedInstallation(operation:operation,review:check.review)
  #expect(reopened.phase == .menuAccepted && reopened.check.planSHA256 == check.planSHA256)
  let wrongReview=SNESFirstInstallReviewReceipt(directory:check.review.directory,sha256:String(repeating:"0",count:64))
  await #expect(throws:(any Error).self) {try await app.reopenSNESReviewedInstallation(operation:operation,review:wrongReview)}
  let candidate=try await app.prepareSNESMenuStartup(after:check,currentData:current)
  let loaded=try SNESStartupAdapterCandidate.load(directory:candidate.directory,expectedManifestSHA256:candidate.manifestSHA256)
  #expect(loaded.backup.directory.path==copy.path && loaded.hasMenuSupport)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"] != nil))
 func menuPreparationAcceptsNewerVerifiedBackupFromSameConsole() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (journal,_)=try await menuStartupParentFixture(root)
  let old=try await journal.menuStartupParent()
  let copy=root.appendingPathComponent("SNES-Current-Data-"+UUID().uuidString)
  try FileManager.default.copyItem(at:old.candidate.backup.directory,to:copy)
  let manifestURL=copy.appendingPathComponent("manifest.json")
  var manifest=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
  var files=try #require(manifest["files"] as? [String:String])
  let chunks=files.keys.filter{$0.hasPrefix("data-") && $0.hasSuffix(".bin") && $0 != "data-header.bin"}.sorted()
  let last=try #require(chunks.last);var hash=SHA256()
  for name in chunks {
   let url=copy.appendingPathComponent(name);var bytes=try Data(contentsOf:url)
   if name==last {bytes[bytes.count-1] ^= 1;try bytes.write(to:url);files[name]=BackupManifest.digest(bytes)}
   hash.update(data:bytes)
  }
  manifest["files"]=files;manifest["sha256"]=hash.finalize().map{String(format:"%02x",$0)}.joined()
  let raw=try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]);try raw.write(to:manifestURL)
  let receipt=SNESDataSnapshotReceipt(directory:copy,manifestSHA256:BackupManifest.digest(raw))
  let updated=try await journal.menuStartupParent(currentData:receipt)
  #expect(updated.candidate.image==old.candidate.image)
  #expect(updated.candidate.backup.sha256 != old.candidate.backup.sha256)
  try updated.require(updated.candidate)
  let export=try updated.candidate.checkedExport()
  let manual=root.appendingPathComponent("SNES-Startup-Candidate-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:manual,withIntermediateDirectories:false)
  try export.files["startup.img"]!.write(to:manual.appendingPathComponent("startup.img"))
  try export.manifest.write(to:manual.appendingPathComponent("manifest.json"))
  let manuallyLoaded=try SNESStartupAdapterCandidate.load(directory:manual)
  #expect(manuallyLoaded.image==updated.candidate.image)
  #expect(manuallyLoaded.material.binding==updated.candidate.material.binding)
  #expect(manuallyLoaded.backup.directory.path==updated.candidate.backup.directory.path)
  #expect(manuallyLoaded.backup.sha256==updated.candidate.backup.sha256)
  try updated.require(manuallyLoaded)
  let store=try RecoveryBootSnapshotStore(root:root)
  let saved=try await store.saveSNESStartupCandidateWithReceipt(updated.candidate,verify:{ directory in
   let loaded=try SNESStartupAdapterCandidate.load(directory:directory)
   try updated.require(loaded)
  })
  let loaded=try SNESStartupAdapterCandidate.load(directory:saved.directory,expectedManifestSHA256:saved.manifestSHA256)
  try updated.require(loaded)
  #expect(throws:(any Error).self) {try old.require(updated.candidate)}
  let wrong=SNESDataSnapshotReceipt(directory:copy,manifestSHA256:String(repeating:"0",count:64))
  await #expect(throws:(any Error).self) {try await journal.menuStartupParent(currentData:wrong)}
  var binding=try #require(manifest["binding"] as? [String:Any])
  binding["sourceSnapshot"]="SNES-US-Setup-11111111-1111-1111-1111-111111111111"
  manifest["binding"]=binding
  let forged=try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]);try forged.write(to:manifestURL)
  #expect(throws:(any Error).self) {try updated.require(manuallyLoaded)}
  let wrongSetup=SNESDataSnapshotReceipt(directory:copy,manifestSHA256:BackupManifest.digest(forged))
  await #expect(throws:(any Error).self) {try await journal.menuStartupParent(currentData:wrongSetup)}
  try await journal.close()
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"] != nil))
 func acceptedParentProducesOnlyMatchedMenuCandidateAndDetectsHistoryChange() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (journal,operation)=try await menuStartupParentFixture(root),accepted=try await journal.acceptedInstall(),parent=try await journal.menuStartupParent();try await journal.close()
  let candidate=parent.candidate;try parent.require(candidate)
  #expect(candidate.hasMenuSupport && candidate.image.count<=4194304)
  let original=try LegacyBootImageBuilder.inspect(accepted.material.trial.image),new=try LegacyBootImageBuilder.inspect(candidate.image)
  #expect(original.kernel==new.kernel && original.header[64..<576]==new.header[64..<576])
  #expect(candidate.backup.directory==accepted.material.trial.candidate.backup.directory)
  #expect(parent.activeImage==accepted.material.trial.image && parent.record.operationID==accepted.material.id)
  #expect(throws:(any Error).self) {try parent.require(accepted.material.trial.candidate)}
  let file=operation.appendingPathComponent("plan.json"),handle=try FileHandle(forWritingTo:file);try handle.seekToEnd();try handle.write(contentsOf:Data([32]));try handle.close()
  #expect(throws:(any Error).self) {try parent.validate()}
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"] != nil))
 func unacceptedStartupCannotIssueMenuPreparation() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (journal,_)=try await menuStartupParentFixture(root,accepted:false)
  await #expect(throws:(any Error).self) {try await journal.menuStartupParent()};try await journal.close()
 }
}

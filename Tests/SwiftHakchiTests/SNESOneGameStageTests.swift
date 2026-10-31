import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func oneGameReceiptFixture(_ m:SNESOneGameMaterial,challenge:UUID,preflight:Bool,free:Int=204800000)->Data {
 Data(("\(preflight ? "SWIFTHAKCHI_SNES_GAME_PREFLIGHT_V1":"SWIFTHAKCHI_SNES_GAME_INACTIVE_V1")\nCHALLENGE=\(challenge.uuidString)\nHWID=\(m.accepted.material.trial.expectedHWID)\nID=\(m.menu.id.uuidString)\nTREE=\(m.menu.treeSHA256)\nFILES=\(m.menu.files.count+1)\nBYTES=\(m.menu.byteCount)\nFREE_BYTES=\(free)\nSELECTOR_CHANGED=0\nEND\n").utf8)
}
func oneGameInspectionFixture(_ m:SNESOneGameMaterial,challenge:UUID,complete:Bool=true)->Data {
 var files=m.menu.files;files["menu.manifest"]=m.menu.manifest
 var text="SWIFTHAKCHI_SNES_GAME_INSPECTION_V2\nCHALLENGE=\(challenge.uuidString)\nHWID=\(m.accepted.material.trial.expectedHWID)\nID=\(m.menu.id.uuidString)\nSELECTOR=missing\nTARGET=directory\nENTRIES=\(1+m.menu.gameCount+files.count)\n"
 for name in files.keys.sorted() {if !complete {text+="MISSING \(name)\n";continue};text+="FILE \(name) \(files[name]!.count) \(BackupManifest.digest(files[name]!))\n"}
 return Data((text+"FILE_SIZE_LIMIT=524288:524288\nCOPY_LIMIT_READY=1\nEND\n").utf8)
}
actor OneGameStageFake:SNESOneGameStageIO {
 let material:SNESOneGameMaterial,fault:String,mutation:@Sendable ()throws->Void
 var events:[String]=[],reports=0,copied=false
 init(material:SNESOneGameMaterial,fault:String,mutation:@escaping @Sendable ()throws->Void={}) {self.material=material;self.fault=fault;self.mutation=mutation}
 func inventory()->[RecoveryProbeUSBDevice] {
  events.append("inventory")
  if fault=="inventory" {return [startupTrialUSB,startupTrialUSB]}
  if fault=="fingerprint" {return [startupTrialFEL]}
  if fault=="attachment" && copied {return []}
  return [startupTrialUSB]
 }
 func connect(expected:RecoveryProbeUSBDevice)throws {events.append("connect");if fault=="connect" {throw SNESOneGameMenu.failure()}}
 func report(challenge:UUID)throws->Data {
  events.append("report");reports+=1
  let e=try SNESStartupTrialExpectation.checked(material.accepted.material.trial),id=fault=="second-report" && reports>1 ? UUID():challenge
  return startupTrialReportFixture(challenge:id,hwid:e.hwid,runtime:e.runtimeSHA256,wrapper:e.wrapperSHA256)
 }
 func preflight(_ m:SNESOneGameMaterial,challenge:UUID)throws->Data {
  events.append("preflight");try mutation()
  return oneGameReceiptFixture(m,challenge:challenge,preflight:true,free:fault=="space" ? m.requiredFreeBytes-1:204800000)
 }
 func copy(_ m:SNESOneGameMaterial,permit:SNESOneGameCopyPermit)throws->Data {
  try permit.require(m);events.append("copy");copied=true
  if fault=="partial" {throw SNESOneGameMenu.failure()}
  if fault=="cancel" {throw CancellationError()}
  return oneGameReceiptFixture(m,challenge:fault=="copy-response" ? UUID():permit.challenge,preflight:false)
 }
 func inspect(_ m:SNESOneGameMaterial,challenge:UUID)throws->Data {
  events.append("inspect");return oneGameInspectionFixture(m,challenge:challenge,complete:fault != "partial-inspection")
 }
 func verify(_ m:SNESOneGameMaterial,challenge:UUID)throws->Data {
  events.append("verify")
  return oneGameReceiptFixture(m,challenge:fault=="verify-response" ? UUID():challenge,preflight:false)
 }
 func disconnect(){events.append("close")}
}
@Suite(.serialized)
struct SNESOneGameStageTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func stoppedCopyCanBeInspectedWithoutDispatchingAnotherCopy() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),io=OneGameStageFake(material:m,fault:"none")
  let receipt=try await SNESOneGameStage().inspect(material:m,io:io)
  #expect(receipt.matchesMenu)
  let events=await io.events;#expect(events.filter{$0=="inspect"}.count==1 && !events.contains("copy") && events.filter{$0=="close"}.count==1)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func metadataEditedDuringPreflightCannotAuthorizeCopy() async throws {
  let source=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let game=root.appendingPathComponent("CLV-U-ABCDE"),backups=root.appendingPathComponent("Backups"),journals=root.appendingPathComponent("journals")
  try FileManager.default.copyItem(at:URL(fileURLWithPath:source.paths.gameDirectory),to:game)
  for d in [backups,journals] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let p=source.paths,paths=SNESOneGamePaths(firmwareOperation:p.firmwareOperation,firmwareReviewSHA256:p.firmwareReviewSHA256,catalogDirectory:p.catalogDirectory,gameDirectory:game.path,romFilename:p.romFilename,backupsDirectory:backups.path)
  let m=try SNESOneGameMaterial.prepare(paths:paths,accepted:source.accepted),store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),prepared=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals)
  let journal=try SNESOneGameStageJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,artifact:artifact),metadata=game.appendingPathComponent("CLV-U-ABCDE.desktop"),original=try Data(contentsOf:metadata)
  let io=OneGameStageFake(material:m,fault:"none",mutation:{try Data("Name=Changed\n".utf8).write(to:metadata)})
  await #expect(throws:(any Error).self) {try await SNESOneGameStage().copy(material:m,journal:journal,io:io)}
  let events=await io.events;#expect(!events.contains("copy") && events.filter{$0=="close"}.count==1)
  // Source seals deliberately remain invalid even if the old bytes are written back.
  let record=try Data(contentsOf:prepared.operation.appendingPathComponent("0000.json"))
  #expect(!record.isEmpty && !FileManager.default.fileExists(atPath:prepared.operation.appendingPathComponent("0001.json").path))
  _=original;try await journal.close()
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func readOnlyPreflightCannotDispatchCopy() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),io=OneGameStageFake(material:m,fault:"none")
  let r=try await SNESOneGameStage().preflight(material:m,io:io)
  #expect(r.isPreflight && r.freeBytes==204800000)
  let events=await io.events
  #expect(events.filter{$0=="copy"}.isEmpty && events.filter{$0=="close"}.count==1)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","inventory","fingerprint","connect","space","partial","cancel","attachment","copy-response","verify-response","second-report"])
 func singleCopyRequiresPositiveReadbackAndRetainsInterruptedIntent(_ fault:String) async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups")
  for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),p=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals)
  let journal=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact),io=OneGameStageFake(material:m,fault:fault)
  do {let r=try await SNESOneGameStage().copy(material:m,journal:journal,io:io);#expect(fault=="none" && !r.isPreflight)} catch {#expect(fault != "none","Unexpected: \(error)")}
  let events=await io.events,copies=events.filter{$0=="copy"}.count
  #expect(copies<=1 && events.filter{$0=="close"}.count==1)
  #expect(try await journal.phase()==(fault=="none" ? .inactiveVerified:copies>0 ? .uncertain:.prepared))
  if copies>0 {await #expect(throws:(any Error).self) {try await journal.beginCopy()}}
  try await journal.close()
 }
}

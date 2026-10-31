import Foundation
import Testing
@testable import SwiftHakchi

actor OneGameMenuTrialFake:SNESOneGameMenuTrialIO {
 let material:SNESOneGameMaterial,fault:String
 let mutation:@Sendable (String)throws->Void
 var events:[String]=[],shown=false
 init(_ m:SNESOneGameMaterial,fault:String,mutation:@escaping @Sendable (String)throws->Void={_ in}){material=m;self.fault=fault;self.mutation=mutation}
 func inventory()->[RecoveryProbeUSBDevice] {events.append("inventory");return fault=="attachment" && shown ? []:[startupTrialUSB]}
 func connect(expected:RecoveryProbeUSBDevice)throws {events.append("connect");if fault=="connect" {throw SNESOneGameMenu.failure()}}
 func report(challenge:UUID)throws->Data {
  events.append("report");let e=try SNESStartupTrialExpectation.checked(material.accepted.material.trial)
  return startupTrialReportFixture(challenge:challenge,hwid:e.hwid,runtime:e.runtimeSHA256,wrapper:e.wrapperSHA256)
 }
 func inspect(_ m:SNESOneGameMaterial,challenge:UUID)throws->Data {events.append("inspect");try mutation("inspect");return oneGameInspectionFixture(m,challenge:challenge,complete:fault != "partial")}
 func menuState(_ m:SNESOneGameMaterial,challenge:UUID,original:Bool)->Data {
  events.append("state");return gameMenuTrialReceipt(m,challenge:fault=="state" && shown ? UUID():challenge,original:original,mcp:original ? 101:103)
 }
 func start(_ m:SNESOneGameMaterial,permit:SNESOneGameMenuTrialPermit)throws->Data {
  try permit.require(m);events.append("start");shown=true;try mutation("start")
  if fault=="task-cancel" {withUnsafeCurrentTask{$0?.cancel()};throw CancellationError()};if fault=="cancel" {throw CancellationError()};if fault=="command" {throw SNESOneGameMenu.failure()}
  return gameMenuTrialReceipt(m,challenge:fault=="receipt" ? UUID():permit.challenge,mcp:fault=="old-pid" ? 101:103)
 }
 func trialStartupReport(_ m:SNESOneGameMaterial,challenge:UUID)throws->Data {
  events.append("trial-report");let e=try SNESStartupTrialExpectation.checked(material.accepted.material.trial)
  return Data(String(decoding:startupTrialReportFixture(challenge:challenge,hwid:e.hwid,runtime:e.runtimeSHA256,wrapper:e.wrapperSHA256),as:UTF8.self)
   .replacingOccurrences(of:"MCP_PID=101",with:"MCP_PID=103").replacingOccurrences(of:"MOUNTS_END",with:(fault=="mount" ? "":"tmpfs /usr/share/applications/clover-mcp.desktop tmpfs rw 0 0\n")+"MOUNTS_END").utf8)
 }
 func disconnect(){events.append("close")}
}
@Suite(.serialized)
struct SNESOneGameMenuTrialSessionTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["inspect","start"])
 func changedLocalSourceCannotAuthorizeOrCompleteTrial(_ point:String) async throws {
  let source=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let game=root.appendingPathComponent(source.menu.code),backups=root.appendingPathComponent("Backups"),journals=root.appendingPathComponent("journals")
  try FileManager.default.copyItem(at:URL(fileURLWithPath:source.paths.gameDirectory),to:game)
  for d in [backups,journals] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let p=source.paths,paths=SNESOneGamePaths(firmwareOperation:p.firmwareOperation,firmwareReviewSHA256:p.firmwareReviewSHA256,catalogDirectory:p.catalogDirectory,gameDirectory:game.path,romFilename:p.romFilename,backupsDirectory:backups.path)
  let m=try SNESOneGameMaterial.prepare(paths:paths,accepted:source.accepted),store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),prepared=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals),j=try SNESOneGameStageJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,artifact:artifact)
  _=try await j.beginCopy();let c=UUID();try await j.verified(receipt:SNESOneGameStageReceipt(oneGameReceiptFixture(m,challenge:c,preflight:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:c,preflight:false))
  let metadata=game.appendingPathComponent(m.menu.code+".desktop"),io=OneGameMenuTrialFake(m,fault:"none",mutation:{stage in if stage==point {try Data("Name=Changed\n".utf8).write(to:metadata)}})
  await #expect(throws:(any Error).self) {try await SNESOneGameMenuTrialService().start(material:m,journal:j,io:io)}
  let events=await io.events;#expect(events.filter{$0=="close"}.count==1 && events.filter{$0=="start"}.count==(point=="start" ? 1:0))
  if point=="start" {let record=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:prepared.operation.appendingPathComponent("0003.json"))) as? [String:Any]);#expect(record["phase"] as? String=="menuTrialIntent")}
  else {#expect(!FileManager.default.fileExists(atPath:prepared.operation.appendingPathComponent("0003.json").path))}
  try await j.close()
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","connect","partial","command","cancel","receipt","old-pid","attachment","mount","state","task-cancel"])
 func oneAttemptRequiresVerifiedCopyAndCompleteLiveChecks(_ fault:String) async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups");for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),p=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals),j=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  _=try await j.beginCopy();let c=UUID();try await j.verified(receipt:SNESOneGameStageReceipt(oneGameReceiptFixture(m,challenge:c,preflight:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:c,preflight:false))
  let io=OneGameMenuTrialFake(m,fault:fault),service=SNESOneGameMenuTrialService()
  if fault=="none" {
   let result=try await service.start(material:m,journal:j,io:io);#expect(result.mcpPID==103 && !result.original);#expect(try await j.phase() == .menuTrialShown)
   _=try await service.check(material:m,journal:j,io:OneGameMenuTrialFake(m,fault:"none"),original:false)
   _=try await service.check(material:m,journal:j,io:OneGameMenuTrialFake(m,fault:"none"),original:true)
   #expect(try await j.phase() == .menuTrialReturned)
  } else if fault=="task-cancel" {
   let task=Task {try await service.start(material:m,journal:j,io:io)}
   await #expect(throws:(any Error).self) {try await task.value}
   #expect(try await j.phase() == .menuTrialIntent)
   _=try await service.check(material:m,journal:j,io:OneGameMenuTrialFake(m,fault:"none"),original:true)
  } else {await #expect(throws:(any Error).self) {try await service.start(material:m,journal:j,io:io)}}
  let events=await io.events;#expect(events.filter{$0=="close"}.count==1)
  let before=["connect","partial"].contains(fault);#expect(events.filter{$0=="start"}.count==(before ? 0:1))
  if fault != "none" {#expect(try await j.phase() == (fault=="task-cancel" ? .menuTrialReturned:before ? .inactiveVerified:.menuTrialUncertain))}
  try await j.close()
 }
}

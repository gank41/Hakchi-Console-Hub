import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func gameMenuTrialReceipt(_ m:SNESOneGameMaterial,challenge:UUID,original:Bool=false,mcp:Int=103,daemon:Int=102)->Data {
 Data("SWIFTHAKCHI_SNES_GAME_MENU_TRIAL_V1\nCHALLENGE=\(challenge.uuidString)\nHWID=\(m.accepted.material.trial.expectedHWID)\nID=\(m.menu.id.uuidString)\nTREE=\(m.menu.treeSHA256)\nSTATE=\(original ? "original":"ram-menu")\nMCP_PID=\(mcp)\nDAEMON_PID=\(daemon)\nSELECTOR_CHANGED=0\nEND\n".utf8)
}
struct SNESOneGameMenuTrialPolicyTests {
 @Test func ordinaryReportsRemainStrictAndTemporaryPolicyRequiresOnlyOneRAMConfig()throws {
  let id=UUID(),e=SNESStartupTrialExpectation(hwid:String(repeating:"1",count:32),runtimeSHA256:String(repeating:"2",count:64),wrapperSHA256:String(repeating:"3",count:64)),base=startupTrialReportFixture(challenge:id)
  let changed=Data(String(decoding:base,as:UTF8.self).replacingOccurrences(of:"MOUNTS_END",with:"tmpfs /usr/share/applications/clover-mcp.desktop tmpfs rw 0 0\nMOUNTS_END").utf8)
  #expect(throws:(any Error).self) {try SNESStartupTrialReport(changed,expected:e,challenge:id)}
  _=try SNESStartupTrialReport(changed,expected:e,challenge:id,temporaryMenu:true)
  #expect(throws:(any Error).self) {try SNESStartupTrialReport(base,expected:e,challenge:id,temporaryMenu:true)}
 }
}
@Suite(.serialized)
struct SNESOneGameMenuTrialJournalTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func failedCombinedValidationCannotEmitAValidStartupReport() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),c=UUID(),state=try SNESOneGameMenuTrialCommands.state(menu:m.menu,originals:m.originals.frame,binding:m.accepted.material.trial.candidate.material.binding,challenge:c),base=try SNESStartupTrialCommands.script(trial:m.accepted.material.trial,challenge:c)
  let generated=try SNESOneGameMenuTrialCommands.startupReport(m,challenge:c)
  #expect(generated.components(separatedBy:state).count==2 && generated.components(separatedBy:base).count==2)
  let fixture=generated.replacingOccurrences(of:state,with:"exit 71\n").replacingOccurrences(of:base,with:"printf 'UNSAFE_REPORT\\n'\n")
  let process=Process(),out=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c",fixture];process.standardOutput=out;try process.run();let bytes=out.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
  #expect(process.terminationStatus != 0 && bytes.isEmpty)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func reopenedIntentCanOnlyBeRecoveredByOriginalReturnProof() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups");for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),p=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals),j=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  _=try await j.beginCopy();let c=UUID();try await j.verified(receipt:SNESOneGameStageReceipt(oneGameReceiptFixture(m,challenge:c,preflight:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:c,preflight:false));_=try await j.beginMenuTrial();try await j.close()
  let reopened=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  #expect(try await reopened.phase() == .menuTrialIntent)
  await #expect(throws:(any Error).self) {try await reopened.beginMenuTrial()}
  let returned=try await SNESOneGameMenuTrialService().check(material:m,journal:reopened,io:OneGameMenuTrialFake(m,fault:"none"),original:true)
  #expect(returned.original);#expect(try await reopened.phase() == .menuTrialReturned);try await reopened.close()
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func onlyCompletedCopyCanIssueOneMenuPermitAndReturnNeedsFreshProof() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups");for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),p=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals),j=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  await #expect(throws:(any Error).self) {try await j.beginMenuTrial()}
  _=try await j.beginCopy();let c=UUID();try await j.verified(receipt:SNESOneGameStageReceipt(oneGameReceiptFixture(m,challenge:c,preflight:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:c,preflight:false))
  let permit=try await j.beginMenuTrial();try permit.require(m);#expect(try await j.phase() == .menuTrialIntent)
  await #expect(throws:(any Error).self) {try await j.beginMenuTrial()}
  let n=UUID(),receipt=try SNESOneGameMenuTrialReceipt(gameMenuTrialReceipt(m,challenge:n),id:m.menu.id,tree:m.menu.treeSHA256,binding:m.accepted.material.trial.candidate.material.binding,challenge:n,original:false)
  try await j.menuTrialShown(receipt);#expect(try await j.phase() == .menuTrialShown)
  await #expect(throws:(any Error).self) {try await j.beginMenuTrial()}
  await #expect(throws:(any Error).self) {try await j.menuTrialReturned(receipt)}
  let end=UUID(),returned=try SNESOneGameMenuTrialReceipt(gameMenuTrialReceipt(m,challenge:end,original:true),id:m.menu.id,tree:m.menu.treeSHA256,binding:m.accepted.material.trial.candidate.material.binding,challenge:end,original:true)
  try await j.menuTrialReturned(returned);#expect(try await j.phase() == .menuTrialReturned);try await j.close()
  let reopened=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact);#expect(try await reopened.phase() == .menuTrialReturned)
  let freshPermit=try await reopened.beginMenuTrial();try freshPermit.require(m)
  #expect(freshPermit.challenge != permit.challenge);#expect(try await reopened.phase() == .menuTrialIntent)
  await #expect(throws:(any Error).self) {try await reopened.beginMenuTrial()}
  try await reopened.close()
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func exhaustedHistoryRefusesBeforeIssuingAnotherMenuPermit() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups");for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),p=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals),j=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  _=try await j.beginCopy();let c=UUID();try await j.verified(receipt:SNESOneGameStageReceipt(oneGameReceiptFixture(m,challenge:c,preflight:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:c,preflight:false));try await j.close()
  // Build a valid long history directly in a private fixture, avoiding repeated source hashing.
  var previous=try Data(contentsOf:p.operation.appendingPathComponent("0002.json"))
  for index in 3..<63 {
   let challenge=UUID(),step=(index-3)%3,phase=step==0 ? "menuTrialIntent":step==1 ? "menuTrialShown":"menuTrialReturned"
   var record:[String:Any]=["phase":phase,"planSHA256":p.reviewSHA256,"previousSHA256":BackupManifest.digest(previous),"challenge":challenge.uuidString]
   if step != 0 {record["receipt"]=gameMenuTrialReceipt(m,challenge:challenge,original:step==2).base64EncodedString()}
   previous=try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]);try previous.write(to:p.operation.appendingPathComponent(String(format:"%04d.json",index)))
  }
  let reopened=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  #expect(try await reopened.phase() == .menuTrialReturned)
  await #expect(throws:(any Error).self) {try await reopened.beginMenuTrial()}
  #expect(!FileManager.default.fileExists(atPath:p.operation.appendingPathComponent("0063.json").path))
  #expect(try await reopened.phase() == .menuTrialReturned);try await reopened.close()
 }

}

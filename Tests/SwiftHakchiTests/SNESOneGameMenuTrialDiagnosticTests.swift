import Foundation
import Testing
import os
@testable import SwiftHakchi
@Suite(.serialized)
struct SNESOneGameMenuTrialDiagnosticTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func recoveredOriginalMenuCanFinishPersistedIntentWithoutAnotherAction() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups");for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),p=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals),j=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  _=try await j.beginCopy();let c=UUID();try await j.verified(receipt:SNESOneGameStageReceipt(oneGameReceiptFixture(m,challenge:c,preflight:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:c,preflight:false));_=try await j.beginMenuTrial();try await j.close()
  let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage),io=OneGameMenuTrialFake(m,fault:"none")
  let text=try #require(try await SNESOneGameMenuTrialDiagnostic.runIfPresent(["--finish-snes-one-game-menu-test",p.operation.path,p.reviewSHA256],loadInputs:{inputs},requireOperation:{_ in},requireFirmware:{_ in},checkHost:{},makeIO:{_ in io}))
  let value=try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any]);#expect(value["phase"] as? String=="menuTrialReturned")
  let events=await io.events;#expect(!events.contains("start") && events.filter{$0=="close"}.count==1)
 }
 @Test(arguments:[["--test-snes-one-game-menu"],["--test-snes-one-game-menu","/tmp",String(repeating:"a",count:64)],["--test-snes-one-game-menu","/tmp",String(repeating:"a",count:64),"wrong"],["--review-snes-one-game-menu","relative",String(repeating:"a",count:64)],["--check-snes-one-game-menu","/tmp","bad"]])
 func malformedStopsBeforeInputsAndUSB(_ args:[String]) async throws {
  let calls=OSAllocatedUnfairLock(initialState:0)
  await #expect(throws:(any Error).self) {try await SNESOneGameMenuTrialDiagnostic.runIfPresent(args,loadInputs:{calls.withLock{$0+=1};throw SNESOneGameMenu.failure()},makeIO:{_ in calls.withLock{$0+=1};throw SNESOneGameMenu.failure()})}
  #expect(calls.withLock{$0}==0)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func reviewThenOneTrialAndReadOnlyChecks() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups");for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),p=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals),j=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  _=try await j.beginCopy();let c=UUID();try await j.verified(receipt:SNESOneGameStageReceipt(oneGameReceiptFixture(m,challenge:c,preflight:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:c,preflight:false));try await j.close()
  let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage),calls=OSAllocatedUnfairLock(initialState:0)
  func run(_ mode:String,_ confirmation:Bool=false) async throws->[String:Any] {
   let args=[mode,p.operation.path,p.reviewSHA256]+(confirmation ? ["--confirm-temporary-menu"]:[])
   let text=try #require(try await SNESOneGameMenuTrialDiagnostic.runIfPresent(args,loadInputs:{inputs},requireOperation:{_ in},requireFirmware:{_ in},checkHost:{},makeIO:{value in calls.withLock{$0+=1};return OneGameMenuTrialFake(value,fault:"none")}))
   return try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
  }
  let review=try await run("--review-snes-one-game-menu");#expect(review["USBOpened"] as? Bool==false && calls.withLock{$0}==0)
  #expect((review["commandSHA256"] as? String)?.count==64)
  let shown=try await run("--test-snes-one-game-menu",true);#expect(shown["phase"] as? String=="menuTrialShown")
  let checked=try await run("--check-snes-one-game-menu");#expect(checked["phase"] as? String=="menuTrialShown")
  let returned=try await run("--finish-snes-one-game-menu-test");#expect(returned["phase"] as? String=="menuTrialReturned")
  let rereview=try await run("--review-snes-one-game-menu");#expect(rereview["USBOpened"] as? Bool==false && calls.withLock{$0}==3)
  let repeated=try await run("--test-snes-one-game-menu",true);#expect(repeated["phase"] as? String=="menuTrialShown")
  await #expect(throws:(any Error).self) {try await run("--test-snes-one-game-menu",true)}
  #expect(calls.withLock{$0}==4)
 }
}

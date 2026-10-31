import Foundation
import Testing
import os
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESOneGameDiagnosticTests {
 @Test(arguments:[[],["--copy-snes-one-game"],["--copy-snes-one-game","/tmp",String(repeating:"a",count:64)],["--preflight-snes-one-game","relative",String(repeating:"a",count:64)],["--prepare-snes-one-game","relative"],["--preflight-snes-one-game","/tmp","bad"]])
 func malformedInputNeverLoadsOrOpensUSB(_ args:[String]) async throws {
  let calls=OSAllocatedUnfairLock(initialState:0)
  do {let result=try await SNESOneGameDiagnostic.runIfPresent(args,loadInputs:{calls.withLock{$0+=1};throw SNESOneGameMenu.failure()},makeIO:{_ in calls.withLock{$0+=1};throw SNESOneGameMenu.failure()});#expect(args.isEmpty && result==nil)} catch {#expect(!args.isEmpty)}
  #expect(calls.withLock{$0}==0)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func offlinePreparationThenReadOnlyReviewNeverCopies() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals");try FileManager.default.createDirectory(at:journals,withIntermediateDirectories:false)
  let request=root.appendingPathComponent("request.json");try JSONEncoder().encode(m.paths).write(to:request)
  let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage),io=OneGameStageFake(material:m,fault:"none"),calls=OSAllocatedUnfairLock(initialState:0)
  func run(_ args:[String]) async throws->String? {
   try await SNESOneGameDiagnostic.runIfPresent(args,loadInputs:{inputs},requireFirmware:{_ in},requireOperation:{_ in},journalRoot:{journals},checkHost:{},makeIO:{value in let n=calls.withLock{$0+=1;return $0};return OneGameStageFake(material:value,fault:n>=2 ? "partial-inspection":"none")})
  }
  let raw=try #require(try await run(["--prepare-snes-one-game",request.path])),result=try #require(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
  #expect(calls.withLock{$0}==0)
  let op=try #require(result["operation"] as? String),review=try #require(result["reviewSHA256"] as? String)
  let preflight=try #require(try await run(["--preflight-snes-one-game",op,review])),value=try #require(JSONSerialization.jsonObject(with:Data(preflight.utf8)) as? [String:Any])
  #expect(value["copied"] as? Bool==false && value["freeBytes"] as? Int==204800000)
  #expect(calls.withLock{$0}==1)
  let saved=try SNESOneGameStageJournal.readSaved(operation:URL(fileURLWithPath:op),reviewSHA256:review),artifact=URL(fileURLWithPath:saved.artifactPath),material=try SNESOneGameMaterial.load(directory:artifact,accepted:m.accepted)
  let journal=try SNESOneGameStageJournal(operation:URL(fileURLWithPath:op),reviewSHA256:review,material:material,artifact:artifact)
  _=try await journal.beginCopy();try await journal.uncertain();try await journal.close()
  let stopped=try #require(try await run(["--inspect-snes-one-game",op,review])),inspection=try #require(JSONSerialization.jsonObject(with:Data(stopped.utf8)) as? [String:Any])
  #expect(inspection["matchesMenu"] as? Bool==false && inspection["copied"] as? Bool==false)
  #expect(calls.withLock{$0}==2)
  let recorded=try #require(try await run(["--inspect-snes-one-game",op,review,"--record-inactive-result"])),closed=try #require(JSONSerialization.jsonObject(with:Data(recorded.utf8)) as? [String:Any])
  #expect(closed["recordedInactiveFailure"] as? Bool==true && closed["phase"] as? String=="failedInactive")
  await #expect(throws:(any Error).self) {try await run(["--copy-snes-one-game",op,review,"--confirm-copy-reviewed-games"])}
  #expect(calls.withLock{$0}==3)
  let reopened=try SNESOneGameStageJournal(operation:URL(fileURLWithPath:op),reviewSHA256:review,material:material,artifact:artifact)
  #expect(try await reopened.phase() == .failedInactive);try await reopened.close()
  _=io
 }
}

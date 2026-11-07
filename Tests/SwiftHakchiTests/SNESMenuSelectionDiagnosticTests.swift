import Foundation
import Testing
import os
@testable import SwiftHakchi

struct SNESMenuSelectionDiagnosticTests {
 @Test func selectionFailuresNeverUseGenericFirmwareRecoveryAdvice() {
  let op="/tmp/SNESMenuSelection-"+UUID().uuidString,review=String(repeating:"a",count:64)
  let text=SNESMenuSelectionDiagnostic.failureMessage(arguments:["--select-snes-menu",op,review,"--confirm-reviewed-menu"],error:CancellationError())
  #expect(SNESMenuSelectionDiagnostic.handles("--select-snes-menu"))
  #expect(!SNESMenuSelectionDiagnostic.handles("--write-stock-boot2"))
  #expect(text.contains("game menu may already be updated") && text.contains(op) && text.contains(review))
  #expect(text.contains("Do not repeat") && text.contains("read-only"))
  #expect(!text.contains("RAM") && !text.contains("firmware") && !text.contains("FEL"))
 }
 @Test(arguments:[["--prepare-snes-menu-selection"],["--prepare-snes-menu-selection","relative"],["--prepare-snes-menu-selection","/tmp/request","extra"],["--select-snes-menu","/tmp/operation",String(repeating:"a",count:64),"wrong-confirmation"]])
 func malformedCannotLoadInputsOrOpenUSB(_ args:[String]) async throws {
  let calls=OSAllocatedUnfairLock(initialState:0)
  await #expect(throws:(any Error).self){try await SNESMenuSelectionDiagnostic.runIfPresent(args,loadInputs:{calls.withLock{$0+=1};throw SNESOneGameMenu.failure()})}
  #expect(calls.withLock{$0}==0)
 }
}
// Both source-backed flows open the same saved firmware roots. Serialize them
// in one suite; the real nonblocking operation lease must still reject overlap.
extension SNESMenuSelectionTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SELECTION_FIRMWARE"] != nil))
 func offlineReviewThenOneSelectionAndColdCheck() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let request=root.appendingPathComponent("request.json"),operations=root.appendingPathComponent("operations")
  try FileManager.default.createDirectory(at:operations,withIntermediateDirectories:false)
  try JSONEncoder().encode(menuSelectionRequest()).write(to:request)
  let input=try menuFirmwareInputs(),factoryCalls=OSAllocatedUnfairLock(initialState:0)
  let result=try #require(try await SNESMenuSelectionDiagnostic.runIfPresent(["--prepare-snes-menu-selection",request.path],loadInputs:{input},root:{operations},requireOperation:{_ in},makeIO:{_ in factoryCalls.withLock{$0+=1};throw SNESOneGameMenu.failure()}))
  let r=try #require(JSONSerialization.jsonObject(with:Data(result.utf8)) as? [String:Any])
  #expect(r["USBOpened"] as? Bool==false && r["firmwareWritten"] as? Bool==false && factoryCalls.withLock{$0}==0)
  let op=URL(fileURLWithPath:try #require(r["operation"] as? String)),review=try #require(r["reviewSHA256"] as? String)
  let p=try SNESMenuSelectionJournal.readPlan(operation:op,reviewSHA256:review)
  let m=try await SNESMenuSelectionMaterial.prepare(request:p.request,recovery:input,id:p.id),io=MenuSelectionFake(m,fault:"none")
  let selected=try await SNESMenuSelectionDiagnostic.runIfPresent(["--select-snes-menu",op.path,review,"--confirm-reviewed-menu"],loadInputs:{input},requireOperation:{_ in},checkHost:{},makeIO:{_ in io})
  #expect(selected?.contains("\"phase\" : \"selected\"")==true)
  await io.powerCycle()
  let checked=try await SNESMenuSelectionDiagnostic.runIfPresent(["--check-snes-selected-menu",op.path,review],loadInputs:{input},requireOperation:{_ in},checkHost:{},makeIO:{_ in io})
  #expect(checked?.contains("startupVerified")==true)
  let accepted=try await SNESMenuSelectionDiagnostic.runIfPresent(["--accept-snes-selected-menu",op.path,review,"--confirm-gameplay-and-cold-start"],loadInputs:{input},requireOperation:{_ in},makeIO:{_ in factoryCalls.withLock{$0+=1};throw SNESOneGameMenu.failure()})
  #expect(accepted?.contains("\"userGameplayConfirmed\" : true")==true && factoryCalls.withLock{$0}==0)
 }
}

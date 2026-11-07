import Foundation
import Testing
import os
import SwiftHakchiCore
@testable import SwiftHakchi

actor MenuStartupTrialFake:SNESStartupTrialIO {
 let expected:SNESStartupTrialExpectation,device:RecoveryProbeUSBDevice
 var booted:Bool,events:[String]=[]
 init(trial:PreparedSNESStartupTrial,booted:Bool)throws {
  expected=try .checked(trial);self.booted=booted
  device = .init(vendorID:0x1f3a,productID:0xefe8,deviceVersion:expected.deviceVersion,deviceClass:0,locationID:42,product:SNESStartupTrialUSBPolicy.product,registryEntryID:2)
 }
 func inventory()->[RecoveryProbeUSBDevice] {[booted ? device:startupTrialFEL]}
 func boot(expected:RecoveryProbeUSBDevice,validateInputs:@escaping @Sendable () throws -> Void) throws {try validateInputs();events.append("boot");booted=true;try validateInputs()}
 func connect(expected:RecoveryProbeUSBDevice) {#expect(expected==device);events.append("connect")}
 func report(challenge:UUID)->Data {
  Data(String(decoding:startupTrialReportFixture(challenge:challenge,hwid:expected.hwid,runtime:expected.runtimeSHA256,wrapper:expected.wrapperSHA256),as:UTF8.self).replacingOccurrences(of:"MOUNTS_END",with:"tmpfs /etc/init.d/S81clover-mcp tmpfs rw 0 0\nMOUNTS_END").utf8)
 }
 func disconnect(){events.append("close")}
}
@Suite(.serialized)
struct SNESMenuStartupDiagnosticTests {
 @Test(arguments:[["--prepare-snes-menu-startup"],["--prepare-snes-menu-startup","/tmp","bad","/tmp"],["--preflight-snes-menu-startup","relative",String(repeating:"a",count:64),"/tmp","/tmp"],["--test-snes-menu-startup","/tmp",String(repeating:"a",count:64)],["--check-snes-menu-startup","/tmp","bad"]])
 func malformedRequestsStopBeforeInputsAndUSB(_ args:[String]) async throws {
  let calls=OSAllocatedUnfairLock(initialState:0)
  await #expect(throws:(any Error).self) {try await SNESMenuStartupDiagnostic.runIfPresent(args,loadInputs:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()})}
  #expect(calls.withLock{$0}==0)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"] != nil))
 func offlinePreparationAndParentAwarePreflightUseSeparateCapabilities() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (journal,operation)=try await menuStartupParentFixture(root);try await journal.close()
  let backups=root.appendingPathComponent("Backups");try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:false)
  let review=BackupManifest.digest(try Data(contentsOf:operation.appendingPathComponent("plan.json"))),pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage),calls=OSAllocatedUnfairLock(initialState:0),trials=OSAllocatedUnfairLock(initialState:[MenuStartupTrialFake]())
  func run(_ args:[String]) async throws->[String:Any] {
   let text=try #require(try await SNESMenuStartupDiagnostic.runIfPresent(args,loadInputs:{inputs},requireOperation:{_ in},checkHost:{},makePreflightIO:{c,parent in calls.withLock{$0+=1};return try MenuStartupPreflightFake(parent:parent,fault:"none")},makeTrialIO:{trial in
    let count=calls.withLock{$0+=1;return $0},fake=try MenuStartupTrialFake(trial:trial,booted:count==3);trials.withLock{$0.append(fake)};return fake
   }))
   return try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
  }
  let prepared=try await run(["--prepare-snes-menu-startup",operation.path,review,backups.path]);#expect(prepared["USBOpened"] as? Bool==false && calls.withLock{$0}==0)
  let candidate=try #require(prepared["candidate"] as? String)
  let checked=try await run(["--preflight-snes-menu-startup",operation.path,review,candidate,backups.path]);#expect(checked["firmwareWritten"] as? Bool==false && calls.withLock{$0}==1)
  #expect(checked["scope"] as? String=="snes-menu-startup-no-flash-preflight")
  let preflight=try #require(checked["directory"] as? String)
  let started=try await run(["--test-snes-menu-startup",operation.path,review,candidate,preflight,backups.path]);#expect(started["phase"] as? String=="started")
  let directory=try #require(started["directory"] as? String)
  let played=try await run(["--check-snes-menu-startup",operation.path,review,candidate,preflight,directory,backups.path]);#expect(played["phase"] as? String=="after-gameplay" && played["firmwareWritten"] as? Bool==false)
  let fakes=trials.withLock{$0};#expect(fakes.count==2)
  #expect(await fakes[0].events.filter{$0=="boot"}.count==1)
  #expect(await fakes[1].events.contains("boot")==false)
  for fake in fakes {#expect(await fake.events.filter{$0=="close"}.count==1)}
 }
}

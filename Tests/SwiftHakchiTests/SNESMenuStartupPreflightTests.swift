import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor MenuStartupPreflightFake:SNESStartupPreflightIO {
 let base:SNESStartupPreflightFakeIO,parent:SNESMenuStartupParent,fault:String
 let mutation:@Sendable ()throws->Void
 var reads=0
 init(parent:SNESMenuStartupParent,fault:String,mutation:@escaping @Sendable ()throws->Void={})throws {self.parent=parent;self.fault=fault;self.mutation=mutation;base=try .init(candidate:parent.candidate,fault:"none")}
 func inventory()async throws->[RecoveryProbeUSBDevice] {try await base.inventory()}
 func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice)async throws {try await base.boot(inputs,expected:expected)}
 func connect(expected:RecoveryProbeUSBDevice)async throws {try await base.connect(expected:expected)}
 func observe()async throws->String {try await base.observe()}
 func readBoot2(_ slot:RecoveryBootSlot)async throws->RecoveryBoot2Read {
  reads+=1
  let wrong=(fault=="wrong-first" && reads==1)||(fault=="wrong-second" && reads==2)
  return .image(wrong ? Data([1]):parent.activeImage)
 }
 func readBoot1()async throws->Data {try await base.readBoot1()}
 func readPartitions()async throws->Data {try await base.readPartitions()}
 func readDataSuperblock()async throws->Data {try await base.readDataSuperblock()}
 func dataHash(challenge:UUID)async throws->Data {if fault=="changed-parent" {try mutation()};return await base.dataHash(challenge:challenge)}
 func stageStartup(_ image:Data,stock:Data,id:UUID)async throws {try await base.stageStartup(image,stock:stock,id:id)}
 func disconnect()async {await base.disconnect()}
}
actor MenuStartupParentFixtureCache {
 static let shared=MenuStartupParentFixtureCache()
 private var saved:SNESMenuStartupParent?
 func value() async throws->SNESMenuStartupParent {
  if let saved {return saved}
  let root=try testDirectory(),(journal,_)=try await menuStartupParentFixture(root),parent=try await journal.menuStartupParent();try await journal.close();saved=parent;return parent
 }
}
@Suite(.serialized)
struct SNESMenuStartupPreflightTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"] != nil),arguments:["none","wrong-first","wrong-second","changed-parent","stock-only","before-boot"])
 func parentAwarePreflightRequiresExactCurrentImageAndSeparatesEvidence(_ fault:String) async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let parent:SNESMenuStartupParent
  if ["changed-parent","before-boot"].contains(fault) {let (journal,_)=try await menuStartupParentFixture(root);parent=try await journal.menuStartupParent();try await journal.close()}
  else {parent=try await MenuStartupParentFixtureCache.shared.value()}
  let operation=parent.directory
  let plan=operation.appendingPathComponent("plan.json"),io=try MenuStartupPreflightFake(parent:parent,fault:fault,mutation:{let f=try FileHandle(forWritingTo:plan);try f.seekToEnd();try f.write(contentsOf:Data([32]));try f.close()}),pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
  if fault=="none" {
   #expect(throws:(any Error).self) {try NativeSNESStartupPreflightIO(candidate:parent.candidate)}
   _=try NativeSNESStartupPreflightIO(candidate:parent.candidate,parent:parent)
   let result=try await SNESStartupPreflightService(wait:{}).capture(candidate:parent.candidate,inputs:inputs,io:io,parent:parent)
   let backups=root.appendingPathComponent("Backups");try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:false)
   let folder=try await RecoveryBootSnapshotStore(root:backups).saveSNESStartupPreflight(result)
   #expect(throws:(any Error).self) {try SNESStartupPreflightEvidence.load(directory:folder,candidate:parent.candidate)}
   let trial=try PreparedSNESStartupTrial.prepare(candidate:parent.candidate,evidence:folder,recovery:inputs,parent:parent);try trial.validateCurrent()
   #expect(trial.candidate.hasMenuSupport && trial.image==parent.candidate.image)
   let manifest=folder.appendingPathComponent("manifest.json"),original=try Data(contentsOf:manifest)
   var downgraded=try #require(JSONSerialization.jsonObject(with:original) as? [String:Any]);downgraded["schemaVersion"]=1;downgraded["scope"]="snes-startup-no-flash-preflight";downgraded.removeValue(forKey:"parent");try JSONSerialization.data(withJSONObject:downgraded).write(to:manifest)
   #expect(throws:(any Error).self) {try SNESStartupPreflightEvidence.load(directory:folder,candidate:parent.candidate)}
   try original.write(to:manifest)
   var record=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any]);#expect(record["schemaVersion"] as? Int==2)
   var p=try #require(record["parent"] as? [String:Any]);p["reviewSHA256"]=String(repeating:"0",count:64);record["parent"]=p;try JSONSerialization.data(withJSONObject:record).write(to:manifest)
   #expect(throws:(any Error).self) {try trial.validateCurrent()}
  } else {
   await #expect(throws:(any Error).self) {try await SNESStartupPreflightService(wait:{}).capture(candidate:parent.candidate,inputs:inputs,io:io,progress:{phase in if fault=="before-boot" && phase == .uploadingRecovery {try? io.mutation()}},parent:fault=="stock-only" ? nil:parent)}
  }
  if fault=="before-boot" {#expect(await io.base.base.events.contains("boot")==false)}
  #expect(await io.base.stages==(fault=="none" ? 1:0))
  #expect(await io.base.base.events.filter{$0=="disconnect"}.count==(fault=="stock-only" ? 0:1))
 }
}

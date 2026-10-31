import Foundation
import Testing
@testable import SwiftHakchi

func menuSelectionRequest()throws->SNESMenuSelectionRequest {
 let e=ProcessInfo.processInfo.environment
 return try .init(firmwareOperation:#require(e["SWIFTHAKCHI_SNES_SELECTION_FIRMWARE"]),firmwareReviewSHA256:#require(e["SWIFTHAKCHI_SNES_SELECTION_FIRMWARE_REVIEW"]),
  gameOperation:#require(e["SWIFTHAKCHI_SNES_SELECTION_GAME"]),gameReviewSHA256:#require(e["SWIFTHAKCHI_SNES_SELECTION_GAME_REVIEW"]))
}
actor MenuSelectionFixtureCache {
 static let shared=MenuSelectionFixtureCache()
 private var cached:SNESMenuSelectionMaterial?
 func value() async throws->SNESMenuSelectionMaterial {
  if let cached{return cached}
  let m=try await SNESMenuSelectionMaterial.prepare(request:menuSelectionRequest(),recovery:menuFirmwareInputs())
  cached=m;return m
 }
}
func selectionReceipt(_ m:SNESMenuSelectionMaterial,_ challenge:UUID,selected:Bool,display:Bool)->Data {
 Data(("SWIFTHAKCHI_SNES_MENU_SELECTION_V1\nCHALLENGE="+challenge.uuidString+"\nHWID="+m.binding.expectedHWID+"\nOPERATION="+m.id.uuidString+"\nID="+m.game.menu.id.uuidString+"\nTREE="+m.game.menu.treeSHA256+"\nSELECTOR="+(selected ? m.selectorSHA256:"missing")+"\nDISPLAY="+(display ? "selected":"original")+"\nEND\n").utf8)
}
actor MenuSelectionFake:SNESMenuSelectionIO {
 let m:SNESMenuSelectionMaterial,fault:String
 let mutation:@Sendable (String)throws->Void
 var publications=0,closes=0,selected=false,cold=false
 init(_ m:SNESMenuSelectionMaterial,fault:String,mutation:@escaping @Sendable (String)throws->Void={_ in}){self.m=m;self.fault=fault;self.mutation=mutation}
 func inventory()->[RecoveryProbeUSBDevice] {
  if fault=="attachment" || fault=="post-attachment" && selected {return []}
  return [RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:0x6a05,deviceClass:0,locationID:42,product:"Swift Hakchi SNES Startup",registryEntryID:2)]
 }
 func connect(expected:RecoveryProbeUSBDevice){}
 func report(challenge:UUID)throws->Data {
  let e=try SNESStartupTrialExpectation.checked(m.installed.material.trial)
  return Data(String(decoding:startupTrialReportFixture(challenge:challenge,hwid:e.hwid,runtime:e.runtimeSHA256,wrapper:e.wrapperSHA256),as:UTF8.self)
   .replacingOccurrences(of:"MOUNTS_END",with:"tmpfs /etc/init.d/S81clover-mcp tmpfs rw 0 0\n"+(cold ? "tmpfs /usr/share/applications/clover-mcp.desktop tmpfs rw 0 0\n":"")+"MOUNTS_END").utf8)
 }
 func inspect(challenge:UUID)throws->Data {try mutation("inspect");return selectionReceipt(m,fault=="receipt" || fault=="bad-after" && selected ? UUID():challenge,selected:selected || fault=="existing",display:cold)}
 func publish(permit:SNESMenuSelectionPermit)throws->Data {
  try permit.require(m);publications+=1;selected=true
  try mutation("publish")
  if fault=="lost" {throw SNESOneGameMenu.failure()}
  if fault=="cancel" {throw CancellationError()}
  return selectionReceipt(m,permit.challenge,selected:true,display:false)
 }
 func disconnect(){closes+=1;if fault=="cancel-on-close" {withUnsafeCurrentTask{$0?.cancel()}}}
 func powerCycle(){cold=true;selected=true}
}
@Suite(.serialized)
struct SNESMenuSelectionTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SELECTION_FIRMWARE"] != nil),arguments:["none","attachment","existing","receipt","lost","cancel","post-attachment","bad-after"])
 func durableSinglePublicationAndColdStartupVerification(_ fault:String) async throws {
  let m=try await MenuSelectionFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let prepared=try SNESMenuSelectionJournal.prepare(material:m,root:root),j=try SNESMenuSelectionJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m)
  let io=MenuSelectionFake(m,fault:fault),service=SNESMenuSelectionService()
  if fault=="none" {
   _=try await service.select(material:m,journal:j,io:io)
   #expect(try await j.phase() == .selected)
   await #expect(throws:(any Error).self){try await service.select(material:m,journal:j,io:io)}
   await #expect(throws:(any Error).self){try await service.checkStartup(material:m,journal:j,io:io)}
   #expect(try await j.phase() == .selected)
   await io.powerCycle();_=try await service.checkStartup(material:m,journal:j,io:io)
   #expect(try await j.phase() == .startupVerified);try await j.accept();#expect(try await j.phase() == .accepted)
  } else {
   do { _=try await service.select(material:m,journal:j,io:io);Issue.record("Expected selection failure") }
   catch {
    if ["lost","cancel","post-attachment","bad-after"].contains(fault) {
     let message=SNESMenuSelectionDiagnostic.failureMessage(arguments:["--select-snes-menu",prepared.operation.path,m.reviewSHA256,"--confirm-reviewed-menu"],error:error)
     #expect(error is SNESMenuSelectionUnverified)
     #expect(message.contains(prepared.operation.path))
     #expect(message.contains("may already be saved"))
     #expect(message.contains(m.id.uuidString) && message.contains(m.reviewSHA256))
     #expect(message.contains("read-only") && message.contains("Do not repeat"))
    }
   }
   #expect(try await j.phase() == (["lost","cancel","post-attachment","bad-after"].contains(fault) ? .uncertain:.prepared))
  }
  let count=await io.publications;#expect(count==(["none","lost","cancel","post-attachment","bad-after"].contains(fault) ? 1:0))
  #expect(await io.closes == (fault=="none" ? 4:1))
  try await j.close()
 }
}

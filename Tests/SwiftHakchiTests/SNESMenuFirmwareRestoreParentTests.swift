import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESMenuFirmwareRestoreParentTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PLAYED"] != nil),arguments:[false,true])
 func changedImmediateUpgradeParentStopsTheNextIO(_ afterIntent:Bool) async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (old,op)=try await menuStartupParentFixture(root),accepted=try await old.acceptedInstall(),parent=try await old.menuStartupParent();try await old.close()
  let inputs=try menuFirmwareInputs(),m=try SNESFirmwareMaterial.upgrade(parent:parent,paths:menuFirmwarePaths(accepted.material),recovery:inputs),g=try SNESFirmwareGuard.prepare(m),transactions=op.deletingLastPathComponent()
  let p=try SNESFirmwareJournal.prepare(material:m,root:transactions,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
  try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified();try await j.startupVerified();try await j.acceptMenu()
  let restore=try SNESFirmwareMaterial.restore(accepted:await j.acceptedInstall());try await j.close()
  let rg=try SNESFirmwareGuard.prepare(restore),rp=try SNESFirmwareJournal.prepare(material:restore,root:transactions,guard:rg)
  let rj=try await SNESFirmwareJournal.reopen(operation:rp.operation,reviewSHA256:rp.reviewSHA256,recovery:inputs)
  let current=try await rj.verifiedMaterial(),checked=try SNESFirmwareGuard.prepare(current)
  try await rj.preflightVerified()
  let io=SNESFirmwareFakeIO(material:current,fault:"none"),point:RecoveryStage=afterIntent ? .restoringStartup:.readingCurrentKernel
  await #expect(throws:(any Error).self){
   try await SNESFirmwareTransaction(wait:{}).run(mode:.write,journal:rj,guard:checked,inputs:inputs,io:io,progress:{phase in
    if phase==point {try? Data([1]).write(to:p.operation.appendingPathComponent("0005.json"))}
   })
  }
  #expect(await io.writes==0)
  if !afterIntent {#expect(await io.kernelReads==0)}
  #expect(await io.base.events.filter{$0=="disconnect"}.count==1)
  // The interrupted record is retained; reopening it cannot grant another write.
  await #expect(throws:(any Error).self){try await rj.beginWrite()}
  try await rj.close()
 }
}

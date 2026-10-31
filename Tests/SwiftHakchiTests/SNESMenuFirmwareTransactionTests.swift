import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESMenuFirmwareTransactionTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PLAYED"] != nil),arguments:["none","preimage","write","parent-change"])
 func reconstructsUpgradeAndOriginalRestoreWithoutRetry(_ fault:String) async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (parentJournal,parentOp)=try await menuStartupParentFixture(root),accepted=try await parentJournal.acceptedInstall(),parent=try await parentJournal.menuStartupParent();try await parentJournal.close()
  let inputs=try menuFirmwareInputs(),paths=try menuFirmwarePaths(accepted.material)
  let m=try SNESFirmwareMaterial.upgrade(parent:parent,paths:paths,recovery:inputs),g=try SNESFirmwareGuard.prepare(m),transactions=parentOp.deletingLastPathComponent()
  func trace(_ s:String) {FileHandle.standardError.write(Data(("Upgrade test: "+s+"\n").utf8))}
  trace("preparing")
  let p=try SNESFirmwareJournal.prepare(material:m,root:transactions,guard:g)
  trace("reopening")
  let j=try await SNESFirmwareJournal.reopen(operation:p.operation,reviewSHA256:p.reviewSHA256,recovery:inputs)
  #expect(try await j.verifiedMaterial().preimage==accepted.material.target)
  trace("preflight")
  let pre=SNESFirmwareFakeIO(material:m,fault:"none")
  _=try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:j,guard:g,inputs:inputs,io:pre)
  #expect(await pre.writes==0)
  #expect(try await j.phase() == .preflightVerified)
  trace("writing")
  let io=SNESFirmwareFakeIO(material:m,fault:fault)
  do {
   _=try await SNESFirmwareTransaction(wait:{}).run(mode:.write,journal:j,guard:g,inputs:inputs,io:io,progress:{phase in
    if fault=="parent-change",phase == .stagingStartup {try? Data([1]).write(to:parentOp.appendingPathComponent("0005.json"))}
   })
   #expect(fault=="none")
  } catch {#expect(fault != "none")}
  #expect(await io.writes==(["none","write"].contains(fault) ? 1:0))
  #expect(await io.base.events.filter{$0=="disconnect"}.count==1)
  if fault=="parent-change" {try await j.close();return}
  #expect(try await j.phase()==(fault=="none" ? .readbackVerified:fault=="write" ? .uncertain:.stoppedBeforeWrite))
  if fault != "none" {await #expect(throws:(any Error).self){try await j.beginWrite()};try await j.close();return}
  #expect(await io.active==m.target)
  try await j.startupVerified();try await j.acceptMenu()
  trace("preparing restore")
  let restore=try SNESFirmwareMaterial.restore(accepted:await j.acceptedInstall());try await j.close()
  #expect(restore.preimage==m.target && restore.target==accepted.material.original.active)
  #expect(restore.target != m.preimage)
  let rg=try SNESFirmwareGuard.prepare(restore),rp=try SNESFirmwareJournal.prepare(material:restore,root:transactions,guard:rg)
  trace("reopening restore")
  let rj=try await SNESFirmwareJournal.reopen(operation:rp.operation,reviewSHA256:rp.reviewSHA256,recovery:inputs)
  try await rj.preflightVerified()
  let rio=SNESFirmwareFakeIO(material:restore,fault:"none")
  _=try await SNESFirmwareTransaction(wait:{}).run(mode:.write,journal:rj,guard:rg,inputs:inputs,io:rio)
  #expect(await rio.writes==1)
  #expect(await rio.active==accepted.material.original.active)
  try await rj.acceptMenu();try await rj.close()
 }
}

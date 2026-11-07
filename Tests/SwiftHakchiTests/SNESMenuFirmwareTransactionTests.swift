import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

/// Deliberately lacks the capability to compare a live backup.
private actor SNESFirmwareWithoutDataHash: SNESFirmwareIO {
 let base:SNESFirmwareFakeIO
 init(_ base:SNESFirmwareFakeIO){self.base=base}
 func inventory() async throws->[RecoveryProbeUSBDevice] {try await base.inventory()}
 func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await base.boot(inputs,expected:expected)}
 func connect(expected:RecoveryProbeUSBDevice) async throws {try await base.connect(expected:expected)}
 func observe() async throws->String {await base.observe()}
 func readBoot2(_ slot:RecoveryBootSlot) async throws->RecoveryBoot2Read {try await base.readBoot2(slot)}
 func readBoot1() async throws->Data {try await base.readBoot1()}
 func readPartitions() async throws->Data {try await base.readPartitions()}
 func readDataSuperblock() async throws->Data {try await base.readDataSuperblock()}
 func geometry(challenge:UUID) async throws->Data {await base.geometry(challenge:challenge)}
 func readActive(challenge:UUID) async throws->Data {await base.readActive(challenge:challenge)}
 func stage() async throws {try await base.stage()}
 func verifyStaged() async throws {try await base.verifyStaged()}
 func replace(_ permit:SNESFirmwareWritePermit) async throws {try await base.replace(permit)}
 func disconnect() async {await base.disconnect()}
}

@Suite(.serialized)
struct SNESMenuFirmwareTransactionTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PLAYED"] != nil),arguments:["changed-data","no-hash","none"])
 func upgradeChecksCurrentBackupInTheWriteSession(_ fault:String) async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (parentJournal,parentOp)=try await menuStartupParentFixture(root),accepted=try await parentJournal.acceptedInstall(),parent=try await parentJournal.menuStartupParent();try await parentJournal.close()
  let inputs=try menuFirmwareInputs(),paths=try menuFirmwarePaths(accepted.material)
  let material=try SNESFirmwareMaterial.upgrade(parent:parent,paths:paths,recovery:inputs),checked=try SNESFirmwareGuard.prepare(material)
  let prepared=try SNESFirmwareJournal.prepare(material:material,root:parentOp.deletingLastPathComponent(),guard:checked)
  let journal=try await SNESFirmwareJournal.reopen(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,recovery:inputs)
  try await journal.preflightVerified()
  let fake=SNESFirmwareFakeIO(material:material,fault:fault)
  let io:any SNESFirmwareIO = fault == "no-hash" ? SNESFirmwareWithoutDataHash(fake) : fake
  if fault != "none" {
   await #expect(throws:(any Error).self) {
    try await SNESFirmwareTransaction(wait:{}).run(mode:.write,journal:journal,guard:checked,inputs:inputs,io:io)
   }
  } else {
   _=try await SNESFirmwareTransaction(wait:{}).run(mode:.write,journal:journal,guard:checked,inputs:inputs,io:io)
  }
  #expect(await fake.dataHashes == (fault == "no-hash" ? 0 : 1))
  #expect(await fake.writes == (fault == "none" ? 1 : 0))
  #expect(try await journal.phase() == (fault == "none" ? .readbackVerified : .stoppedBeforeWrite))
  try await journal.close()
 }
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

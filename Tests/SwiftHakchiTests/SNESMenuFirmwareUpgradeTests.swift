import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func menuFirmwarePaths(_ parent:SNESFirmwareMaterial)throws->SNESFirmwarePaths {
 let e=ProcessInfo.processInfo.environment
 return try .init(candidate:#require(e["SWIFTHAKCHI_SNES_MENU_CANDIDATE"]),preflight:#require(e["SWIFTHAKCHI_SNES_MENU_PREFLIGHT"]),started:#require(e["SWIFTHAKCHI_SNES_MENU_STARTED"]),played:#require(e["SWIFTHAKCHI_SNES_MENU_PLAYED"]),original:parent.paths.original,reader:parent.paths.reader,writer:parent.paths.writer)
}
func menuFirmwareInputs()throws->RecoveryBootInputs {
 let p=try PinnedFELInputs.load();return .init(fes1:p.fes1,uboot:p.uboot,bootImage:p.bootImage)
}
@Suite(.serialized)
struct SNESMenuFirmwareUpgradeTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PLAYED"] != nil))
 func upgradeRequiresCompletedMatchingTrialAndRetainsOriginalRecovery() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (j,op)=try await menuStartupParentFixture(root),old=try await j.acceptedInstall(),parent=try await j.menuStartupParent();try await j.close()
  let paths=try menuFirmwarePaths(old.material),inputs=try menuFirmwareInputs()
  let m=try SNESFirmwareMaterial.upgrade(parent:parent,paths:paths,recovery:inputs)
  #expect(m.preimage==old.material.target && m.original.active==old.material.original.active)
  #expect(m.currentImage==old.material.trial.image && m.targetImage==parent.candidate.image)
  #expect(m.target.prefix(3831808)==parent.candidate.image)
  #expect(m.target[3831808..<3932160].allSatisfy{$0==255})
  #expect(m.target[3932160...]==old.material.target[3932160...])
  #expect(m.parentOperationID==old.material.id && m.parentReviewSHA256==old.reviewSHA256)
  let plan=try JSONDecoder().decode(SNESFirmwarePlan.self,from:m.planData())
  #expect(plan.schemaVersion==2 && plan.originalRangeSHA256==BackupManifest.digest(old.material.original.active))
  let noGame=SNESFirmwarePaths(candidate:paths.candidate,preflight:paths.preflight,started:paths.started,played:paths.started,original:paths.original,reader:paths.reader,writer:paths.writer)
  #expect(throws:(any Error).self){try SNESFirmwareMaterial.upgrade(parent:parent,paths:noGame,recovery:inputs)}
  #expect(throws:(any Error).self){try SNESFirmwareMaterial.install(paths:paths,recovery:inputs)}
  let wrong=SNESFirmwarePaths(candidate:old.material.paths.candidate,preflight:paths.preflight,started:paths.started,played:paths.played,original:paths.original,reader:paths.reader,writer:paths.writer)
  #expect(throws:(any Error).self){try SNESFirmwareMaterial.upgrade(parent:parent,paths:wrong,recovery:inputs)}
  let foreign=SNESFirmwarePaths(candidate:paths.candidate,preflight:paths.preflight,started:paths.started,played:paths.played,original:paths.original+"-other",reader:paths.reader,writer:paths.writer)
  #expect(throws:(any Error).self){try SNESFirmwareMaterial.upgrade(parent:parent,paths:foreign,recovery:inputs)}
  let g=try SNESFirmwareGuard.prepare(m)
  let file=op.appendingPathComponent("0005.json"),h=try FileHandle(forWritingTo:file);try h.seekToEnd();try h.write(contentsOf:Data([32]));try h.close()
  #expect(throws:(any Error).self){try g.validate()}
 }
}

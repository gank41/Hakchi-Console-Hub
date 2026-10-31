import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESMenuStartupCandidateTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func menuEnabledRecipeKeepsOriginalKernelAndHistoricalCandidateUnchanged() async throws {
  let m=try await SNESFirmwareFixtureCache.shared.value(),base=m.trial.candidate,old=base.image
  let menu=try SNESStartupAdapterCandidate.withMenuSupport(base),image=try LegacyBootImageBuilder.inspect(menu.image),original=try LegacyBootImageBuilder.inspect(menu.material.support.setup.stock)
  #expect(image.kernel==original.kernel && menu.image.count<=4*1024*1024)
  try SNESColdBootPolicy.require(boot1:menu.material.support.source.preparation.source.boot1,image:menu.image)
  for entry in original.archive.entries where entry.name != "sbin/init" {var expected=entry;if entry.name=="." {expected.fields[4]+=1};#expect(image.archive.entries.first(where:{$0.name==entry.name})==expected)}
  let files=Dictionary(uniqueKeysWithValues:image.archive.entries.map{($0.name,$0.data)})
  for name in ["menu-wrapper","menu-selector","menu-configure","original-menu-init"] {#expect(files["swifthakchi/"+name]?.isEmpty==false)}
  #expect(files["swifthakchi/mcp-template"]==nil && files["swifthakchi/libc.so.6"]==nil)
  let originalInit=try #require(menu.material.support.source.preparation.startup.records.first(where:{$0.path=="etc/init.d/S81clover-mcp"})?.data)
  #expect(files["swifthakchi/original-menu-init"]==originalInit)
  #expect(base.image==old)
  let exported=try menu.checkedExport(),manifest=try #require(JSONSerialization.jsonObject(with:exported.manifest) as? [String:Any])
  #expect(manifest["schemaVersion"] as? Int==4 && manifest["firmwareInstallEligible"] as? Bool==false)
  let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
  let store=try RecoveryBootSnapshotStore(root:root),path=try await store.saveSNESStartupCandidate(menu),reopened=try SNESStartupAdapterCandidate.load(directory:path)
  #expect(reopened.image==menu.image)
  if let p=ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_CANDIDATE_EXPORT"] {
   let folder=URL(fileURLWithPath:p)
   for name in ["prepare","service","usb-wrapper","menu-selector","menu-configure","menu-wrapper","original-menu-init"] {try #require(files["swifthakchi/"+name]).write(to:folder.appendingPathComponent(name))}
   try menu.image.write(to:folder.appendingPathComponent("startup.img"))
  }
 }
}

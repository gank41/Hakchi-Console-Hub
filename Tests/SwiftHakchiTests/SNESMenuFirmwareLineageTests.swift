import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESMenuFirmwareLineageTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"] != nil),arguments:["cycle","missing","unaccepted","downgrade"])
 func refusesBrokenLineageBeforeReconstructingSources(_ fault:String) async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let source=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"]))
  let parent=root.appendingPathComponent(source.lastPathComponent);try FileManager.default.copyItem(at:source,to:parent)
  let original=try Data(contentsOf:parent.appendingPathComponent("plan.json")),review=BackupManifest.digest(original)
  var plan=try #require(JSONSerialization.jsonObject(with:original) as? [String:Any])
  let id=UUID(),op=root.appendingPathComponent("SNESFirmware-"+id.uuidString);try FileManager.default.createDirectory(at:op,withIntermediateDirectories:false)
  plan["id"]=id.uuidString;plan["schemaVersion"]=fault=="downgrade" ? 1:2
  plan["parentOperationID"]=fault=="cycle" ? id.uuidString:fault=="missing" ? UUID().uuidString:plan["id"]
  if fault=="unaccepted" {plan["parentOperationID"]=String(source.lastPathComponent.dropFirst(13));try FileManager.default.removeItem(at:parent.appendingPathComponent("0005.json"))}
  plan["parentReviewSHA256"]=review;plan["originalRangeSHA256"]=plan["preimageSHA256"]
  let raw=try JSONSerialization.data(withJSONObject:plan,options:[.sortedKeys]),digest=BackupManifest.digest(raw)
  try raw.write(to:op.appendingPathComponent("plan.json"));try FileManager.default.copyItem(at:parent.appendingPathComponent("input.bin"),to:op.appendingPathComponent("input.bin"))
  let record:[String:Any]=["phase":"prepared","planSHA256":digest]
  try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]).write(to:op.appendingPathComponent("0000.json"))
  let inputs=try menuFirmwareInputs()
  await #expect(throws:(any Error).self){try await SNESFirmwareJournal.reopen(operation:op,reviewSHA256:digest,recovery:inputs)}
 }
}

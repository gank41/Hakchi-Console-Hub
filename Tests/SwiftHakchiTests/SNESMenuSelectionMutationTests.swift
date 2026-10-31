import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

extension SNESMenuSelectionTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SELECTION_FIRMWARE"] != nil))
 func cancelledReadOnlyCloseHappensOnce() async throws {
  let m=try await MenuSelectionFixtureCache.shared.value(),io=MenuSelectionFake(m,fault:"cancel-on-close")
  let task=Task {try await SNESMenuSelectionService().inspect(material:m,io:io)}
  await #expect(throws:CancellationError.self){try await task.value}
  #expect(await io.closes==1)
  #expect(await io.publications==0)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SELECTION_FIRMWARE"] != nil),arguments:["inspect","publish"])
 func changedInstallationHistoryStopsFurtherIO(_ point:String) async throws {
  let request=try menuSelectionRequest(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let firmwareRoot=root.appendingPathComponent("firmware"),journals=root.appendingPathComponent("selection")
  for d in [firmwareRoot,journals] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let actual=URL(fileURLWithPath:request.firmwareOperation)
  let plan=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:actual.appendingPathComponent("plan.json"))) as? [String:Any])
  let parentID=try #require(plan["parentOperationID"] as? String),parent=actual.deletingLastPathComponent().appendingPathComponent("SNESFirmware-"+parentID)
  // Clone journals only. Original game/firmware sources remain read-only.
  for d in [actual,parent] {try FileManager.default.copyItem(at:d,to:firmwareRoot.appendingPathComponent(d.lastPathComponent))}
  let copy=firmwareRoot.appendingPathComponent(actual.lastPathComponent)
  let local=SNESMenuSelectionRequest(firmwareOperation:copy.path,firmwareReviewSHA256:request.firmwareReviewSHA256,gameOperation:request.gameOperation,gameReviewSHA256:request.gameReviewSHA256)
  let m=try await SNESMenuSelectionMaterial.prepare(request:local,recovery:menuFirmwareInputs())
  let p=try SNESMenuSelectionJournal.prepare(material:m,root:journals),j=try SNESMenuSelectionJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m)
  let file=copy.appendingPathComponent("0005.json"),io=MenuSelectionFake(m,fault:"none",mutation:{stage in
   if stage==point {let h=try FileHandle(forWritingTo:file);try h.seekToEnd();try h.write(contentsOf:Data([32]));try h.close()}
  })
  do {_=try await SNESMenuSelectionService().select(material:m,journal:j,io:io);Issue.record("Expected changed-source failure")}
  catch {if point=="publish" {
   let text=SNESMenuSelectionDiagnostic.failureMessage(arguments:["--select-snes-menu",p.operation.path,m.reviewSHA256,"--confirm-reviewed-menu"],error:error)
   #expect(error is SNESMenuSelectionUnverified);#expect(text.contains("may already be saved"));#expect(text.contains(p.operation.path));#expect(text.contains(m.reviewSHA256))
  }}
  #expect(await io.publications==(point=="publish" ? 1:0));#expect(await io.closes==1)
  let name=point=="publish" ? "0001.json":"0000.json"
  let row=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:p.operation.appendingPathComponent(name))) as? [String:Any])
  #expect(row["phase"] as? String==(point=="publish" ? "intent":"prepared"))
  try await j.close()
 }
}

extension SNESMenuSelectionTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SELECTION_FIRMWARE"] != nil))
 func recapturedSameConsoleCannotBypassUnfinishedSelection() async throws {
  let m=try await MenuSelectionFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let oldID=UUID(),op=root.appendingPathComponent("SNESMenuSelection-"+oldID.uuidString)
  try FileManager.default.createDirectory(at:op,withIntermediateDirectories:false)
  var plan=try #require(JSONSerialization.jsonObject(with:m.planData()) as? [String:Any])
  var binding=try #require(plan["binding"] as? [String:Any])
  binding["sourceSnapshot"]="SNES-US-Setup-"+UUID().uuidString
  binding["setupManifestSHA256"]=String(repeating:"e",count:64)
  plan["id"]=oldID.uuidString;plan["binding"]=binding
  let typed=try JSONDecoder().decode(SNESMenuSelectionMaterial.Plan.self,from:JSONSerialization.data(withJSONObject:plan))
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  let raw=try encoder.encode(typed),review=BackupManifest.digest(raw)
  try raw.write(to:op.appendingPathComponent("plan.json"))
  struct Row:Encodable {let phase:String,planSHA256:String,previousSHA256:String?,challenge:UUID?,receipt:Data?}
  let first=try encoder.encode(Row(phase:"prepared",planSHA256:review,previousSHA256:nil,challenge:nil,receipt:nil))
  try first.write(to:op.appendingPathComponent("0000.json"))
  try encoder.encode(Row(phase:"intent",planSHA256:review,previousSHA256:BackupManifest.digest(first),challenge:UUID(),receipt:nil)).write(to:op.appendingPathComponent("0001.json"))
  #expect(throws:(any Error).self){try SNESMenuSelectionJournal.prepare(material:m,root:root)}
 }
}

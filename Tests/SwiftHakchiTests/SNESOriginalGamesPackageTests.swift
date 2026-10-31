import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor OriginalCatalogPackageFake:SNESOriginalGamesIO {
 let base:OriginalGamesFake,launcher:Data
 init(expected:SNESStartupTrialExpectation,launcher:Data) {base=OriginalGamesFake(expected:expected,fault:"none");self.launcher=launcher}
 func inventory() async throws->[RecoveryProbeUSBDevice] {await base.inventory()}
 func connect(expected:RecoveryProbeUSBDevice) async throws {try await base.connect(expected:expected)}
 func report(challenge:UUID) async throws->Data {try await base.report(challenge:challenge)}
 func disconnect() async {await base.disconnect()}
 func originalGames(challenge:UUID) async throws->Data {
  var raw=try await base.originalGames(challenge:challenge)
  let old=Data("#!/bin/sh\nexec /usr/bin/emulator \"$@\"\n".utf8)
  func record(_ d:Data)->Data {Data("WRAPPER \(d.count) \(BackupManifest.digest(d))\n".utf8)+d+Data([10])}
  let range=try #require(raw.range(of:record(old)));raw.replaceSubrange(range,with:record(launcher));return raw
 }
}
@Suite(.serialized)
struct SNESOriginalGamesPackageTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func onlyCompleteMatchingInertCatalogReopensAndEditsInvalidateIt() async throws {
  let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
  defer {try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups")
  try FileManager.default.createDirectory(at:journals,withIntermediateDirectories:false);try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:false)
  let p=try SNESFirmwareJournal.prepare(material:m,root:journals,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
  try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified();try await j.startupVerified();try await j.acceptMenu()
  let accepted=try await j.acceptedInstall(),launcher=try #require(m.trial.candidate.material.support.frame.records.first(where:{$0.path=="usr/bin/clover-canoe-shvc"})?.data)
  let io=OriginalCatalogPackageFake(expected:try .checked(m.trial),launcher:launcher),result=try await SNESOriginalGamesCapture().capture(accepted:accepted,guard:g,io:io),store=try RecoveryBootSnapshotStore(root:backups)
  let saved=try await store.saveSNESOriginalGames(result),package=try SNESOriginalGamesPackage.load(directory:saved,accepted:accepted)
  #expect(package.frame.entries.count==2 && package.frame.launcher==launcher);try package.revalidate()
  let originalManifest=try Data(contentsOf:saved.appendingPathComponent("manifest.json"))
  for fault in ["complete","review","binding","image","target","challenge","digest","extra-flag","extra-file","link"] {
   let copy=backups.appendingPathComponent("SNES-Original-Games-"+UUID().uuidString);try FileManager.default.copyItem(at:saved,to:copy)
   let file=copy.appendingPathComponent("manifest.json");var row=try #require(JSONSerialization.jsonObject(with:originalManifest) as? [String:Any])
   switch fault {
    case "complete":row["complete"]=false
    case "review":row["reviewSHA256"]=String(repeating:"f",count:64)
    case "binding":var b=try #require(row["binding"] as? [String:Any]);b["expectedHWID"]=String(repeating:"f",count:32);row["binding"]=b
    case "image":row["imageSHA256"]=String(repeating:"f",count:64)
    case "target":row["targetSHA256"]=String(repeating:"f",count:64)
    case "challenge":row["challenges"]=[row["catalogChallenge"],row["catalogChallenge"]]
    case "digest":try Data([0]).write(to:copy.appendingPathComponent("catalog.frame"))
    case "extra-flag":row["bootEligible"]=true
    case "extra-file":try Data([0]).write(to:copy.appendingPathComponent("unreviewed"))
    default:let c=copy.appendingPathComponent("catalog.frame");try FileManager.default.removeItem(at:c);try FileManager.default.createSymbolicLink(at:c,withDestinationURL:saved.appendingPathComponent("catalog.frame"))
   }
   try JSONSerialization.data(withJSONObject:row).write(to:file)
   #expect(throws:(any Error).self) {try SNESOriginalGamesPackage.load(directory:copy,accepted:accepted)}
  }
  var changed=originalManifest;changed.append(32);try changed.write(to:saved.appendingPathComponent("manifest.json"))
  #expect(throws:(any Error).self) {try package.revalidate()}
  try await j.close()
 }
}

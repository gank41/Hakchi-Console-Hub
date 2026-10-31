import Foundation
import Testing
@testable import SwiftHakchi

actor OneGameMaterialFixtureCache {
 static let shared=OneGameMaterialFixtureCache()
 private var material:SNESOneGameMaterial?
 func value() async throws->SNESOneGameMaterial {
  if let material {return material}
  let root=try testDirectory(),(accepted,paths)=try await oneGameMaterialFixture(root)
  let m=try SNESOneGameMaterial.prepare(paths:paths,accepted:accepted);material=m;return m
 }
}
@Suite(.serialized)
struct SNESOneGameStageJournalTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func onlyFreshInactivePartialObservationCanReleaseTheFailedCopyGuard() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups")
  for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m),prepared=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals)
  let j=try SNESOneGameStageJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,artifact:artifact)
  let originalPermit=try await j.beginCopy();try await j.uncertain()
  let challenge=UUID(),receipt=try SNESOneGameInspectionReceipt(oneGameInspectionFixture(m,challenge:challenge,complete:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:challenge)
  #expect(!receipt.matchesMenu && receipt.selectorMissing && receipt.copyLimitReady)
  let complete=try SNESOneGameInspectionReceipt(oneGameInspectionFixture(m,challenge:challenge),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:challenge)
  await #expect(throws:(any Error).self) {try await j.noteInactiveFailure(complete)}
  for (old,new) in [("SELECTOR=missing","SELECTOR="+String(repeating:"a",count:64)),("COPY_LIMIT_READY=1","COPY_LIMIT_READY=0")] {
   let raw=Data(String(decoding:receipt.raw,as:UTF8.self).replacingOccurrences(of:old,with:new).utf8),invalid=try SNESOneGameInspectionReceipt(raw,menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:challenge)
   await #expect(throws:(any Error).self) {try await j.noteInactiveFailure(invalid)}
  }
  let replay=try SNESOneGameInspectionReceipt(oneGameInspectionFixture(m,challenge:originalPermit.challenge,complete:false),menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:originalPermit.challenge)
  await #expect(throws:(any Error).self) {try await j.noteInactiveFailure(replay)}
  #expect(try await j.phase() == .uncertain)
  try await j.noteInactiveFailure(receipt);#expect(try await j.phase() == .failedInactive)
  await #expect(throws:(any Error).self) {try await j.beginCopy()}
  try await j.close()
  let reopened=try SNESOneGameStageJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,artifact:artifact)
  #expect(try await reopened.phase() == .failedInactive);try await reopened.close()
  let fresh=try SNESOneGameMaterial.prepare(paths:m.paths,accepted:m.accepted),freshArtifact=try await store.saveSNESOneGame(fresh)
  _=try SNESOneGameStageJournal.prepare(material:fresh,artifact:freshArtifact,root:journals)
  let record=prepared.operation.appendingPathComponent("0003.json")
  var object=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:record)) as? [String:Any]);object["receipt"]=Data([0]).base64EncodedString()
  try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:record)
  #expect(throws:(any Error).self) {try SNESOneGameStageJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,artifact:artifact)}
  let another=try SNESOneGameMaterial.prepare(paths:m.paths,accepted:m.accepted),anotherArtifact=try await store.saveSNESOneGame(another)
  #expect(throws:(any Error).self) {try SNESOneGameStageJournal.prepare(material:another,artifact:anotherArtifact,root:journals)}
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func durableIntentIssuesOnlyOnePermitAndSurvivesReopen() async throws {
  let m=try await OneGameMaterialFixtureCache.shared.value(),root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
  let journals=root.appendingPathComponent("journals"),backups=root.appendingPathComponent("Backups")
  for d in [journals,backups] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
  let store=try RecoveryBootSnapshotStore(root:backups),artifact=try await store.saveSNESOneGame(m)
  _=try SNESOneGameMaterial.load(directory:artifact,accepted:m.accepted)
  let p=try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals)
  let journal=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  #expect(try await journal.phase() == .prepared)
  let permit=try await journal.beginCopy();try permit.require(m)
  await #expect(throws:(any Error).self) {try await journal.beginCopy()}
  #expect(try await journal.phase() == .copyIntent)
  try await journal.uncertain();try await journal.close()
  let reopened=try SNESOneGameStageJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,artifact:artifact)
  #expect(try await reopened.phase() == .uncertain)
  await #expect(throws:(any Error).self) {try await reopened.beginCopy()}
  try await reopened.close()
  #expect(throws:(any Error).self) {try SNESOneGameStageJournal.prepare(material:m,artifact:artifact,root:journals)}
 }
}

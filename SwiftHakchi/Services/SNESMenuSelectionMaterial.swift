import Foundation
import SwiftHakchiCore

struct SNESMenuSelectionRequest:Codable,Sendable {
 let firmwareOperation:String,firmwareReviewSHA256:String,gameOperation:String,gameReviewSHA256:String
 func validate()throws {
  guard [firmwareOperation,gameOperation].allSatisfy({$0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096}),
   [firmwareReviewSHA256,gameReviewSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest) else {throw SNESOneGameMenu.failure()}
 }
}

/// Separate authority from the old inactive copy and from firmware installation.
struct SNESMenuSelectionMaterial:Sendable {
 struct Plan:Codable {
  let schemaVersion:Int,scope:String,id:UUID,request:SNESMenuSelectionRequest,binding:SNESRuntimeBinding
  let menuID:UUID,treeSHA256:String,selectorSHA256:String,selectorBytes:Int,gameTitle:String,gameCount:Int,gameMaterialSHA256:String
 }
 let id:UUID,request:SNESMenuSelectionRequest,installed:SNESFirmwareAcceptedInstall,game:SNESOneGameMaterial
 let binding:SNESRuntimeBinding,selectorSHA256:String,reviewSHA256:String
 private let seals:[SNESFirmwareSourceSeal],installedGuard:SNESFirmwareGuard,encoded:Data
 private init(id:UUID,request:SNESMenuSelectionRequest,installed:SNESFirmwareAcceptedInstall,game:SNESOneGameMaterial,seals:[SNESFirmwareSourceSeal])throws {
  self.id=id;self.request=request;self.installed=installed;self.game=game;self.seals=seals
  binding=installed.material.trial.candidate.material.binding
  installedGuard=try SNESFirmwareGuard.prepare(installed.material)
  let selector=SNESMenuSelectionCommands.selector(menu:game.menu);selectorSHA256=BackupManifest.digest(selector)
  let p=Plan(schemaVersion:1,scope:"snes-persistent-one-game-menu",id:id,request:request,binding:binding,
   menuID:game.menu.id,treeSHA256:game.menu.treeSHA256,selectorSHA256:selectorSHA256,selectorBytes:selector.count,
   gameTitle:game.menu.title,gameCount:game.menu.gameCount,gameMaterialSHA256:game.reviewSHA256)
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoded=try encoder.encode(p);reviewSHA256=BackupManifest.digest(encoded)
  try validate()
 }
 static func prepare(request:SNESMenuSelectionRequest,recovery:RecoveryBootInputs,id:UUID=UUID()) async throws->Self {
  try request.validate()
  let firmware=URL(fileURLWithPath:request.firmwareOperation),operation=URL(fileURLWithPath:request.gameOperation)
  let early=try SNESFirmwareSourceSeal.capture(directories:[firmware,operation],files:[])
  func accepted(_ url:URL,_ review:String) async throws->SNESFirmwareAcceptedInstall {
   let j=try await SNESFirmwareJournal.reopen(operation:url,reviewSHA256:review,recovery:recovery)
   do {let value=try await j.acceptedInstall();try await j.close();return value} catch {try? await j.close();throw error}
  }
  let installed=try await accepted(firmware,request.firmwareReviewSHA256)
  guard installed.directory.path==firmware.standardizedFileURL.path,installed.material.trial.candidate.hasMenuSupport,
    installed.material.direction == .install,let oldID=installed.material.parentOperationID else {throw SNESOneGameMenu.failure()}
  let saved=try SNESOneGameStageJournal.readSaved(operation:operation,reviewSHA256:request.gameReviewSHA256)
  let frozen=try JSONDecoder().decode(SNESOneGameMaterial.Plan.self,from:saved.materialPlan);try frozen.paths.validate()
  let oldURL=URL(fileURLWithPath:frozen.paths.firmwareOperation),artifact=URL(fileURLWithPath:saved.artifactPath)
  let later=try SNESFirmwareSourceSeal.capture(directories:[oldURL,artifact],files:[])
  let old=try await accepted(oldURL,frozen.paths.firmwareReviewSHA256)
  guard old.material.id==oldID,old.reviewSHA256==installed.material.parentReviewSHA256,
    !old.material.trial.candidate.hasMenuSupport,old.material.trial.candidate.material.binding==installed.material.trial.candidate.material.binding else {throw SNESOneGameMenu.failure()}
  let game=try SNESOneGameMaterial.load(directory:artifact,accepted:old)
  guard try game.planData()==saved.materialPlan,game.menu.id==saved.id else {throw SNESOneGameMenu.failure()}
  let j=try SNESOneGameStageJournal(operation:operation,reviewSHA256:request.gameReviewSHA256,material:game,artifact:artifact)
  do {guard try await j.phase() == .menuTrialReturned else {throw SNESOneGameMenu.failure()};try await j.close()} catch {try? await j.close();throw error}
  try early.validate();try later.validate()
  return try Self(id:id,request:request,installed:installed,game:game,seals:[early,later])
 }
 func validate()throws {
  try Task.checkCancellation();try installed.history.validate();try game.accepted.history.validate()
  for seal in seals {try seal.validate()};try installedGuard.require(installed.material);try game.validate()
 }
 func planData()->Data {encoded}
 func receipt(_ raw:Data,challenge:UUID)throws->SNESMenuSelectionReceipt {
  try validate();return try .init(raw,menu:game.menu,binding:binding,operation:id,challenge:challenge)
 }
}
